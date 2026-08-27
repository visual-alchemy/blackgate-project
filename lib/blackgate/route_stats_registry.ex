defmodule Blackgate.RouteStatsRegistry do
  @moduledoc """
  ETS-based registry to store the latest stats for each running route.
  Stats are updated by UnixSockHandler and read by the API.
  """

  use GenServer
  @table_name :route_stats

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    :ets.new(@table_name, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Store stats for a route. Called by UnixSockHandler.
  Also broadcasts the update via PubSub so WebSocket clients receive it immediately.
  """
  def put_stats(route_id, stats) when is_binary(route_id) and is_map(stats) do
    updated_at = System.system_time(:millisecond)

    {stats, warning_count, prev_health} =
      case :ets.lookup(@table_name, route_id) do
        [{^route_id, prev_stats, prev_updated_at}] ->
          prev_sdi_stats = prev_stats["sdi_video_stats"] || []
          curr_sdi_stats = stats["sdi_video_stats"] || []

          updated_sdi_stats =
            Enum.map(curr_sdi_stats, fn curr_item ->
              dev = curr_item["device_number"]
              prev_item = Enum.find(prev_sdi_stats, &(&1["device_number"] == dev))

              if prev_item && prev_updated_at < updated_at do
                delta_drops = max(0, curr_item["dropped_frames"] - prev_item["dropped_frames"])

                delta_dups =
                  max(0, curr_item["duplicated_frames"] - prev_item["duplicated_frames"])

                delta_time_sec = (updated_at - prev_updated_at) / 1000.0

                {drops_per_sec, dups_per_sec} =
                  if delta_time_sec > 0.1 do
                    {delta_drops / delta_time_sec, delta_dups / delta_time_sec}
                  else
                    {0.0, 0.0}
                  end

                curr_item
                |> Map.put("drops_per_sec", Float.round(drops_per_sec, 2))
                |> Map.put("duplicates_per_sec", Float.round(dups_per_sec, 2))
              else
                curr_item
                |> Map.put("drops_per_sec", 0.0)
                |> Map.put("duplicates_per_sec", 0.0)
              end
            end)

          warning_count = prev_stats["warning_count"] || 0
          prev_health = prev_stats["health"] || "disconnected"

          stats =
            stats
            |> Map.put("sdi_video_stats", updated_sdi_stats)
            # Reset to 0 for next window
            |> Map.put("warning_count", 0)
            |> Map.put("last_warning_element", prev_stats["last_warning_element"])
            |> Map.put("last_warning_message", prev_stats["last_warning_message"])
            |> Map.put("last_warning_time", prev_stats["last_warning_time"])
            |> Map.put("last_warning_log_time", prev_stats["last_warning_log_time"])

          {stats, warning_count, prev_health}

        _ ->
          curr_sdi_stats = stats["sdi_video_stats"] || []

          updated_sdi_stats =
            Enum.map(curr_sdi_stats, fn curr_item ->
              curr_item
              |> Map.put("drops_per_sec", 0.0)
              |> Map.put("duplicates_per_sec", 0.0)
            end)

          stats =
            stats
            |> Map.put("sdi_video_stats", updated_sdi_stats)
            |> Map.put("warning_count", 0)

          {stats, 0, "disconnected"}
      end

    sink_stats = get_all_sink_stats(route_id)

    eval_stats =
      stats
      |> Map.put("warning_count", warning_count)
      |> Map.put("sink_stats", sink_stats)

    health = Blackgate.RouteHealth.evaluate(eval_stats)

    # Persist health in stats
    stats_with_health = Map.put(stats, "health", health)
    :ets.insert(@table_name, {route_id, stats_with_health, updated_at})

    # Log health transitions
    if health != prev_health do
      log_health_change(route_id, prev_health, health)
    end

    Phoenix.PubSub.broadcast(
      Blackgate.PubSub,
      "route:stats:#{route_id}",
      {:stats_update, %{stats: eval_stats, health: health, updated_at: updated_at}}
    )

    :ok
  end

  @doc """
  Store pipeline warning telemetry event.
  """
  def put_warning(route_id, element, message) when is_binary(route_id) do
    now = System.system_time(:millisecond)

    case :ets.lookup(@table_name, route_id) do
      [{^route_id, stats, updated_at}] ->
        curr_warnings = stats["warning_count"] || 0
        last_log_time = stats["last_warning_log_time"] || 0

        # Rate limit logging to EventLog to once per 10 seconds
        should_log = now - last_log_time > 10_000

        if should_log do
          Blackgate.EventLog.log(
            :warning,
            "source_video_corrupted",
            "Video corruption detected: #{message} (element: #{element})",
            %{route_id: route_id}
          )
        end

        updated_stats =
          stats
          |> Map.put("warning_count", curr_warnings + 1)
          |> Map.put("last_warning_element", element)
          |> Map.put("last_warning_message", message)
          |> Map.put("last_warning_time", now)
          |> Map.put("last_warning_log_time", if(should_log, do: now, else: last_log_time))

        :ets.insert(@table_name, {route_id, updated_stats, updated_at})

        # Broadcast the warning update immediately
        health = Blackgate.RouteHealth.evaluate(updated_stats)

        Phoenix.PubSub.broadcast(
          Blackgate.PubSub,
          "route:stats:#{route_id}",
          {:stats_update, %{stats: updated_stats, health: health, updated_at: updated_at}}
        )

      _ ->
        stats = %{
          "warning_count" => 1,
          "last_warning_element" => element,
          "last_warning_message" => message,
          "last_warning_time" => now,
          "last_warning_log_time" => now
        }

        :ets.insert(@table_name, {route_id, stats, now})

        Blackgate.EventLog.log(
          :warning,
          "source_video_corrupted",
          "Video corruption detected: #{message} (element: #{element})",
          %{route_id: route_id}
        )
    end

    :ok
  end

  @doc """
  Get stats for a route. Returns nil if not found.
  """
  def get_stats(route_id) when is_binary(route_id) do
    case :ets.lookup(@table_name, route_id) do
      [{^route_id, stats, timestamp}] ->
        %{stats: stats, updated_at: timestamp}

      [] ->
        nil
    end
  end

  @doc """
  Store secondary-source stats for a dual-ingest route.
  Keyed under {:secondary, route_id} so it never collides with the primary
  stats slot. Broadcasts a {:stats_update, %{secondary_source_stats: stats}}
  tuple on the route stats PubSub topic so the React client can render
  secondary telemetry independently from the primary.
  """
  def put_secondary_stats(route_id, stats) when is_binary(route_id) and is_map(stats) do
    updated_at = System.system_time(:millisecond)
    :ets.insert(@table_name, {{:secondary, route_id}, stats, updated_at})

    Phoenix.PubSub.broadcast(
      Blackgate.PubSub,
      "route:stats:#{route_id}",
      {:stats_update, %{secondary_source_stats: stats, updated_at: updated_at}}
    )

    :ok
  end

  @doc """
  Get secondary-source stats for a route. Returns the raw stats map or nil.
  Unlike get_stats/1, this returns the bare map (no wrapping) because
  secondary stats skip the SDI-drop / health-evaluation pipeline.
  """
  def get_secondary_stats(route_id) when is_binary(route_id) do
    case :ets.lookup(@table_name, {:secondary, route_id}) do
      [{{:secondary, ^route_id}, stats, _timestamp}] -> stats
      [] -> nil
    end
  end

  @doc """
  Delete stats for a route. Called when route stops.
  """
  def delete_stats(route_id) when is_binary(route_id) do
    :ets.delete(@table_name, route_id)
    :ok
  end

  @doc """
  Clear all stats. Useful for cleanup.
  """
  def clear_all do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Store stats for a destination/sink. Called by UnixSockHandler.
  Key format: {route_id, :sink, sink_index}
  """
  def put_sink_stats(route_id, sink_index, stats) when is_binary(route_id) and is_map(stats) do
    key = {route_id, :sink, sink_index}
    :ets.insert(@table_name, {key, stats, System.system_time(:millisecond)})
    :ok
  end

  @doc """
  Get stats for a specific sink. Returns nil if not found.
  """
  def get_sink_stats(route_id, sink_index) when is_binary(route_id) do
    key = {route_id, :sink, sink_index}

    case :ets.lookup(@table_name, key) do
      [{^key, stats, timestamp}] ->
        %{stats: stats, updated_at: timestamp}

      [] ->
        nil
    end
  end

  @doc """
  Get stats for all sinks of a route.
  """
  def get_all_sink_stats(route_id) when is_binary(route_id) do
    # Match all keys of format {route_id, :sink, _}
    pattern = {{route_id, :sink, :_}, :_, :_}

    :ets.match_object(@table_name, pattern)
    |> Enum.map(fn {{^route_id, :sink, sink_index}, stats, timestamp} ->
      %{sink_index: sink_index, stats: stats, updated_at: timestamp}
    end)
    |> Enum.sort_by(& &1.sink_index)
  end

  defp log_health_change(route_id, prev, current) do
    level =
      case current do
        "healthy" -> :info
        "disconnected" -> :info
        "blackgate_config_issue" -> :critical
        "critical" -> :critical
        _ -> :warning
      end

    type = "health_changed"

    message =
      case current do
        "healthy" ->
          "Route health recovered to healthy"

        "disconnected" ->
          "Route stream disconnected"

        "source_corrupted" ->
          "Source stream video corruption detected (packet delivery clean)"

        "blackgate_config_issue" ->
          "Appliance buffer overflow / socket limit detected (local packet loss)"

        "network_loss_egress" ->
          "Egress transmission packet loss detected on output client connections"

        "warning" ->
          "Route health degraded to warning"

        "critical" ->
          "Route health degraded to critical"

        _ ->
          "Route health changed to #{current}"
      end

    Blackgate.EventLog.log(level, type, message, %{
      route_id: route_id,
      previous_health: prev,
      current_health: current
    })
  end
end
