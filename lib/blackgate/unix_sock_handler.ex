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

  def handle_event(
        :info,
        {:tcp, _port, "{" <> _ = message},
        _,
        %{route_record: %{"exportStats" => true}} = data
      ) do
    # Handle potentially concatenated source + sink stats messages
    {source_json, sink_json} = split_stats_message(message)
    
    # Process source stats
    if source_json do
      case Jason.decode(source_json) do
        {:ok, stats} ->
          RouteStatsRegistry.put_stats(data.route_id, stats)
          try do
            stats_to_metrics(stats, data)
          rescue
            error ->
              Logger.error("Error processing stats: #{inspect(error)}")
          end
        _ -> :ok
      end
    end
    
    # Process sink stats if present
    if sink_json do
      case Jason.decode(sink_json) do
        {:ok, stats} ->
          sink_index = stats["sink-index"] || 0
          RouteStatsRegistry.put_sink_stats(data.route_id, sink_index, stats)
        _ -> :ok
      end
    end

    :keep_state_and_data
  end

  def handle_event(:info, {:tcp, _port, "{" <> _ = message}, _, %{route_id: route_id} = _data)
      when is_binary(route_id) do
    # Handle potentially concatenated source + sink stats messages
    {source_json, sink_json} = split_stats_message(message)
    
    # Store source stats
    if source_json do
      case Jason.decode(source_json) do
        {:ok, stats} -> RouteStatsRegistry.put_stats(route_id, stats)
        _ -> :ok
      end
    end
    
    # Store sink stats
    if sink_json do
      case Jason.decode(sink_json) do
        {:ok, stats} ->
          sink_index = stats["sink-index"] || 0
          RouteStatsRegistry.put_sink_stats(route_id, sink_index, stats)
        _ -> :ok
      end
    end
    
    :keep_state_and_data
  end

  def handle_event(:info, {:tcp, _port, "{" <> _}, _, _) do
    # ignore stats when no route_id
    :keep_state_and_data
  end

  def handle_event(:info, {:tcp, _port, "stats_sink:" <> json}, _state, %{route_id: route_id} = _data)
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
      cond do
        is_list(stats[key]) ->
          Enum.each(stats[key], fn item ->
            stats_to_metrics(item, data)
          end)

        is_map(stats[key]) ->
          stats_to_metrics(stats[key], data)

        true ->
          tags = %{
            type: "source",
            route_id: data.route_id,
            route_name: data.route_record["name"],
            source_stream_id: data.source_stream_id
          }

          Metrics.event(norm_names(key), stats[key], tags)
      end
    end)
  end

  def norm_names(name) do
    name
    |> String.replace("-", "_")
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
