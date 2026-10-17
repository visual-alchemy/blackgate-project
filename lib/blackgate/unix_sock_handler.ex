defmodule Blackgate.UnixSockHandler do
  @moduledoc false

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
      route_record: nil
    }

    :gen_statem.enter_loop(__MODULE__, [hibernate_after: 5_000], :exchange, data)
  end

  @impl true
  def handle_event(:info, {:tcp, _port, "route_id:" <> route_id}, _state, data) do
    route_id = String.trim(route_id)
    Logger.info("route_id: #{route_id}")

    route_record =
      case Db.get_route(route_id, true) do
        {:ok, record} ->
          Logger.info("route_record: #{inspect(record, pretty: true)}")
          record

        other ->
          Logger.error("Error getting route record: #{inspect(other)}")
          nil
      end

    {:keep_state, %{data | route_id: route_id, route_record: route_record}}
  end

  def handle_event(:info, {:tcp, _port, "\n"}, _state, _data), do: :keep_state_and_data
  def handle_event(:info, {:tcp, _port, ""}, _state, _data), do: :keep_state_and_data

  # Each sink record is written as prefix + JSON + newline (the C engine does the
  # same), so a socket chunk can end right after the "stats_sink:" prefix.
  # Remember it and route the next chunk to the sink slot; otherwise the orphaned
  # JSON is parsed as SOURCE stats, which corrupted the source slot (health
  # flapped to "disconnected" and the stall watchdog read the byte counter as 0).
  def handle_event(:info, {:tcp, _port, "stats_sink:"}, _state, data) do
    {:keep_state, Map.put(data, :pending_sink, true)}
  end

  def handle_event(:info, {:tcp, _port, "{" <> _ = message}, _state, data)
      when is_map_key(data, :pending_sink) do
    if is_binary(data.route_id) do
      case Jason.decode(message) do
        {:ok, stats} ->
          Blackgate.RouteStatsRegistry.put_sink_stats(
            data.route_id,
            stats["sink-index"] || 0,
            stats
          )

        _ ->
          :ok
      end
    end

    {:keep_state, Map.delete(data, :pending_sink)}
  end

  # The engine writes each message newline-terminated, but its writer can flush
  # the previous message's terminator in the same TCP chunk as the next payload,
  # so a chunk arrives as "\nstats_sink:{...}" or "\n{...}". Without this the
  # leading newline matches no clause and the payload falls into the catch-all
  # below, silently dropping the stats (observed: 54 dropped sink-stat messages).
  def handle_event(:info, {:tcp, port, "\n" <> rest}, state, data) when rest != "" do
    handle_event(:info, {:tcp, port, rest}, state, data)
  end

  def handle_event(
        :info,
        {:tcp, _port, "{" <> _ = message},
        _,
        data
      ) do
    # Handle potentially concatenated source + sink stats messages
    {source_json, sink_json} = split_stats_message(message)

    # Process source stats
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

    # Process sink stats if present
    if sink_json do
      case Jason.decode(sink_json) do
        {:ok, stats} ->
          sink_index = stats["sink-index"] || 0
          RouteStatsRegistry.put_sink_stats(data.route_id, sink_index, stats)

        _ ->
          :ok
      end
    end

    :keep_state_and_data
  end

  def handle_event(
        :info,
        {:tcp, _port, "stats_sink:" <> json},
        _state,
        %{route_id: route_id} = _data
      )
      when is_binary(route_id) do
    case Jason.decode(json) do
      {:ok, stats} ->
        sink_index = stats["sink-index"] || 0
        RouteStatsRegistry.put_sink_stats(route_id, sink_index, stats)

      _ ->
        :ok
    end

    :keep_state_and_data
  end

  def handle_event(:info, {:tcp, _port, "stats_sink:" <> _}, _, _) do
    # ignore sink stats when no route_id
    :keep_state_and_data
  end

  def handle_event(:info, {:tcp, _port, "stats_source_stream_id:" <> stream_id}, _state, data) do
    Logger.info("stats_source_stream_id: #{stream_id}")
    {:keep_state, %{data | source_stream_id: stream_id}}
  end

  def handle_event(:info, {:tcp_closed, _port}, _state, _data) do
    Logger.debug("UnixSockHandler: socket closed by client")
    {:stop, :normal}
  end

  def handle_event(type, content, state, data) do
    msg = [
      {"type", type},
      {"content", content},
      {"state", state},
      {"data", data}
    ]

    Logger.error("SocketHandler: Undefined msg: #{inspect(msg, pretty: true)}")

    :keep_state_and_data
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
          # Lists hold nested stats maps (callers, sink_stats, sdi_video_stats) but
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
