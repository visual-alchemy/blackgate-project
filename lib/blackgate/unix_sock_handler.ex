defmodule Blackgate.UnixSockHandler do
  @moduledoc """
  One engine connection on the node's stats socket (Unix domain socket).

  The engine writes newline-terminated records: `route_id:<id>`, then source stats JSON and/or
  `stats_sink:<json>` per output, repeatedly. TCP is a byte stream with no record boundaries, so this
  handler buffers per connection and only ever parses COMPLETE records.

  It used to match `{:tcp, port, "..."}` clause-by-clause against the raw chunk, which silently
  required every chunk to begin exactly on a record boundary. A chunk starting inside a JSON payload
  matched no clause, fell into the catch-all and its stats were dropped without a trace - which is
  what made a route's `health` flap between `healthy` and `disconnected` - while that same catch-all
  printed the entire route record as an error, flooding the log with hundreds of lines a minute and
  burying the operator-facing events next to them.
  """

  require Logger

  @behaviour :ranch_protocol
  @behaviour :gen_statem

  alias Blackgate.Helpers
  alias Blackgate.Metrics
  alias Blackgate.Db
  alias Blackgate.RouteStatsRegistry
  @impl true
  def start_link(ref, transport, opts) do
    Logger.debug(
      "Starting UnixSockHandler with ref: #{inspect(ref)}, transport: #{inspect(transport)}, opts: #{inspect(opts)}"
    )

    pid = :proc_lib.spawn_link(__MODULE__, :init, [ref, transport, opts])
    {:ok, pid}
  end

  @impl true
  def callback_mode, do: [:handle_event_function]

  @impl true
  def init(_), do: :ignore

  def init(ref, trans, _opts) do
    Process.flag(:trap_exit, true)
    Helpers.set_max_heap_size(90)

    {:ok, sock} = :ranch.handshake(ref)

    :ok =
      trans.setopts(sock,
        # mode: :binary,
        # packet: :raw,
        # recbuf: 8192,
        # sndbuf: 8192,
        # # backlog: 2048,
        # send_timeout: 120,
        # keepalive: true,
        # nodelay: true,
        # nopush: true,
        active: true
      )

    data = %{
      sock: sock,
      trans: trans,
      source_stream_id: nil,
      route_id: nil,
      route_record: nil,
      buffer: ""
    }

    :gen_statem.enter_loop(__MODULE__, [hibernate_after: 5_000], :exchange, data)
  end

  @impl true
  def handle_event(:info, {:tcp, _port, chunk}, _state, data) do
    {lines, rest} = split_lines(Map.get(data, :buffer, "") <> chunk)

    data =
      lines
      |> Enum.reduce(Map.put(data, :buffer, rest), fn line, acc -> handle_line(line, acc) end)

    {:keep_state, data}
  end

  def handle_event(:info, {:tcp_closed, _port}, _state, _data) do
    Logger.debug("UnixSockHandler: socket closed by client")
    {:stop, :normal}
  end

  # trap_exit is on, so the transport exit arrives as a plain message; without this clause it hit
  # the catch-all below and every engine that went away logged an "Undefined msg" error as it left.
  def handle_event(:info, {:EXIT, _port, reason}, _state, _data) do
    Logger.debug("UnixSockHandler: exiting with reason #{inspect(reason)}")
    {:stop, :normal}
  end

  def handle_event(type, content, state, data) do
    # Bounded on purpose: pretty-printing the whole route record here turned a single unexpected
    # message into hundreds of log lines and buried the events the operator actually reads.
    Logger.warning(
      "SocketHandler: unexpected event type=#{inspect(type)} content=#{inspect(content, limit: 4, printable_limit: 200)}"
    )

    Logger.debug("SocketHandler: state=#{inspect(state)} data=#{inspect(data, limit: 6)}")

    :keep_state_and_data
  end

  ## Records — handled one COMPLETE newline-terminated record at a time

  @doc false
  def handle_line("route_id:" <> route_id, data) do
    route_id = String.trim(route_id)

    route_record =
      case Db.get_route(route_id, true) do
        {:ok, record} ->
          record

        other ->
          Logger.error("Error getting route record: #{inspect(other)}")
          nil
      end

    Logger.debug("UnixSockHandler: route_id=#{route_id}")

    %{data | route_id: route_id, route_record: route_record}
  end

  def handle_line(line, data) when line in ["", "\r", "\n"], do: data

  # Prefix and payload are written as ONE record by the engine, so per-line buffering can no longer
  # orphan the "stats_sink:" prefix from its JSON at a chunk boundary.
  def handle_line("stats_sink:" <> json, data) do
    if is_binary(data.route_id) do
      case Jason.decode(String.trim(json)) do
        {:ok, stats} ->
          RouteStatsRegistry.put_sink_stats(data.route_id, stats["sink-index"] || 0, stats)

        _ ->
          :ok
      end
    end

    data
  end

  def handle_line("stats_source_stream_id:" <> stream_id, data) do
    %{data | source_stream_id: String.trim(stream_id)}
  end

  def handle_line("{" <> _ = line, data) do
    # A record may still carry both parts when the engine flushes source and sink together.
    {source_json, sink_json} = split_stats_message(String.trim(line))

    if source_json do
      case Jason.decode(source_json) do
        {:ok, %{"type" => "warning"} = warning} ->
          RouteStatsRegistry.put_warning(
            warning["route_id"],
            warning["element"],
            warning["message"]
          )

        {:ok, stats} ->
          case stats["source"] do
            "secondary" ->
              RouteStatsRegistry.put_secondary_stats(data.route_id, stats)

            _ ->
              RouteStatsRegistry.put_stats(data.route_id, Map.delete(stats, "source"))

              try do
                stats_to_metrics(stats, data)
              rescue
                error ->
                  Logger.error("Error processing stats: #{inspect(error)}")
              end
          end

        _ ->
          :ok
      end
    end

    if sink_json do
      case Jason.decode(sink_json) do
        {:ok, stats} ->
          RouteStatsRegistry.put_sink_stats(data.route_id, stats["sink-index"] || 0, stats)

        _ ->
          :ok
      end
    end

    data
  end

  def handle_line(line, data) do
    Logger.warning("UnixSockHandler: unrecognised record #{inspect(line, printable_limit: 200)}")
    data
  end

  @doc """
  Split a byte buffer into complete records plus the trailing partial one.

  Public because its boundary cases ARE the bug that used to drop stats: a JSON payload cut in the
  middle, a terminator arriving in the same chunk as the next payload, several records in one chunk.
  """
  def split_lines(buffer) do
    case String.split(buffer, "\n") do
      [partial] -> {[], partial}
      parts -> {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  @impl true
  def terminate(reason, _state, _data) do
    Logger.debug("SocketHandler: socket closed with reason #{inspect(reason)}")
    :ok
  end

  def stats_to_metrics(stats, data) do
    stats
    |> Map.keys()
    |> Enum.map(fn key ->
      value = stats[key]

      cond do
        is_list(value) ->
          # Lists hold nested stats maps (callers, sink_stats) but
          # also plain values such as audio-pids (a list of PIDs), so only recurse
          # into maps — recursing into an integer raised BadMapError once per report.
          Enum.each(value, fn item ->
            if is_map(item) do
              stats_to_metrics(item, data)
            else
              emit_metric(key, item, data)
            end
          end)

        is_map(value) ->
          stats_to_metrics(value, data)

        true ->
          emit_metric(key, value, data)
      end
    end)
  end

  defp emit_metric(key, value, data) do
    tags = %{
      type: "source",
      route_id: data.route_id,
      route_name: data.route_record["name"],
      source_stream_id: data.source_stream_id
    }

    Metrics.event(norm_names(key), value, tags)
  end

  def norm_names(name) do
    name
    |> String.replace(~r/[^[:alnum:]_]/u, "_")
    |> String.downcase()
  end

  ## Internal functions

  # Split a potentially concatenated message containing both source and sink stats
  # Format: "{source_json}stats_sink:{sink_json}"
  defp split_stats_message(message) do
    case String.split(message, "stats_sink:", parts: 2) do
      [source_json, sink_json] ->
        # Both source and sink stats in one message
        {String.trim(source_json), String.trim(sink_json)}

      [source_json] ->
        # Only source stats
        {String.trim(source_json), nil}
    end
  end
end
