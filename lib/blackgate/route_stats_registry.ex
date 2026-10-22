defmodule Blackgate.RouteStatsRegistry do
  @moduledoc """
  ETS-based registry to store the latest stats for each running route.
  Stats are updated by UnixSockHandler and read by the API.
  """

  use GenServer
  @table_name :route_stats

  # Engines report once per second. If nothing arrives for this long the route is not
  # streaming, and the last row must not be served as live data: a dead route used to
  # keep showing its final "healthy, 12 Mbps" numbers forever, which made a stopped
  # route look alive in the dashboard and in debugging.
  @stale_after_ms 5_000

  # Rolling history used to judge loss over ~10 s instead of a single 1 s report window.
  # The thresholds themselves live in Blackgate.RouteHealth and are reused from there, so
  # only the window length and the history cap are needed here.
  @loss_window_ms 10_000
  @loss_history_limit 30

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

  `now` is a test seam for the rolling loss window: the sustained figure only means
  something once reports span a few seconds, which a test cannot wait for.
  """
  def put_stats(route_id, stats, now \\ nil) when is_binary(route_id) and is_map(stats) do
    updated_at = now || System.system_time(:millisecond)

    {stats, warning_count, prev_health} =
      case :ets.lookup(@table_name, route_id) do
        [{^route_id, prev_stats, prev_updated_at}] ->
          # Source loss over this report window. The cumulative counters keep the
          # connection-startup burst in the ratio for the whole life of the
          # connection, so a route with ~0.5% steady-state loss kept reporting
          # "warning" long after it had settled; the health check uses this window.
          loss_window_pct =
            if prev_updated_at < updated_at do
              d_rx =
                max(0, (stats["packets-received"] || 0) - (prev_stats["packets-received"] || 0))

              d_lost =
                max(
                  0,
                  (stats["packets-received-lost"] || 0) -
                    (prev_stats["packets-received-lost"] || 0)
                )

              if d_rx + d_lost > 0, do: Float.round(d_lost / (d_rx + d_lost) * 100, 3)
            end

          warning_count = prev_stats["warning_count"] || 0
          prev_health = prev_stats["health"] || "disconnected"

          stats =
            stats
            |> Map.put("loss-window-pct", loss_window_pct)
            # Reset to 0 for next window
            |> Map.put("warning_count", 0)
            |> Map.put("last_warning_element", prev_stats["last_warning_element"])
            |> Map.put("last_warning_message", prev_stats["last_warning_message"])
            |> Map.put("last_warning_time", prev_stats["last_warning_time"])
            |> Map.put("last_warning_log_time", prev_stats["last_warning_log_time"])

          {stats, warning_count, prev_health}

        _ ->
          stats =
            stats
            |> Map.put("warning_count", 0)

          {stats, 0, "disconnected"}
      end

    sink_stats = get_all_sink_stats(route_id)

    # Sustained loss over ~10 s plus the consecutive-report streak that gates `warning`
    # (see Blackgate.RouteHealth). Both are published in the stats map so the dashboard and
    # the event log can show what the verdict was based on.
    {loss_10s, streak, burst_log?} = update_loss_window(route_id, updated_at, stats)

    stats =
      stats
      |> Map.put("loss-window-10s-pct", loss_10s)
      |> Map.put("loss-streak", streak)

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
      log_health_change(route_id, prev_health, health, eval_stats)
    end

    # A one-second burst that SRT already recovered is information, not degradation.
    if burst_log? and health == "healthy" do
      log_loss_burst(route_id, eval_stats)
    end

    Phoenix.PubSub.broadcast(
      Blackgate.PubSub,
      "route:stats:#{route_id}",
      {:stats_update, %{stats: eval_stats, health: health, updated_at: updated_at}}
    )

    :ok
  end

  # Rolling ~10 s loss window and the streak of reports at or above the warning threshold.
  # Kept under its own ETS key ({:loss_window, route_id}) so it never leaks into the stats
  # map served to the UI, and so a route's history is dropped with the route.
  defp update_loss_window(route_id, now, stats) do
    rx = stats["packets-received"] || 0
    lost = stats["packets-received-lost"] || 0

    state =
      case :ets.lookup(@table_name, {:loss_window, route_id}) do
        [{_, state, _}] -> state
        _ -> %{samples: [], streak: 0, last_burst_log_at: 0}
      end

    samples =
      (state.samples ++ [{now, rx, lost}])
      |> Enum.filter(fn {ts, _rx, _lost} -> now - ts <= @loss_window_ms end)
      |> Enum.take(-@loss_history_limit)

    loss_10s =
      case samples do
        [{_, rx0, lost0} | _] ->
          d_rx = max(0, rx - rx0)
          d_lost = max(0, lost - lost0)

          if d_rx + d_lost > 0 do
            Float.round(d_lost / (d_rx + d_lost) * 100, 3)
          end

        _ ->
          nil
      end

    probe = Map.put(stats, "loss-window-10s-pct", loss_10s)

    # Hysteresis: count the reports in a row whose figures are past the threshold (loss or
    # RTT — whatever tripped it), so one bad second cannot degrade a route.
    streak = if Blackgate.RouteHealth.degraded?(probe), do: state.streak + 1, else: 0

    # Rate limit burst events the same way pipeline warnings are limited: a burst can span
    # a couple of reports and must not flood the ring.
    burst_log? =
      Blackgate.RouteHealth.transient_burst?(probe) and now - state.last_burst_log_at > 10_000

    :ets.insert(
      @table_name,
      {{:loss_window, route_id},
       %{
         samples: samples,
         streak: streak,
         last_burst_log_at: if(burst_log?, do: now, else: state.last_burst_log_at)
       }, now}
    )

    {loss_10s, streak, burst_log?}
  end

  @doc """
  Store pipeline warning telemetry event.
  """
  def put_warning(route_id, element, message) when is_binary(route_id) do
    now = System.system_time(:millisecond)
    name = route_name(route_id)

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
            "Video corruption detected on #{name}: #{message} (element: #{element})",
            %{route_id: route_id, route_name: name}
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
          "Video corruption detected on #{name}: #{message} (element: #{element})",
          %{route_id: route_id, route_name: name}
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
        stale? = System.system_time(:millisecond) - timestamp > @stale_after_ms

        stats =
          if stale? do
            stats
            |> Map.put("health", "disconnected")
            |> Map.put("stale", true)
          else
            stats
          end

        %{stats: stats, updated_at: timestamp, stale: stale?}

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
  secondary stats skip the per-sink drop / health-evaluation pipeline.
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
    # The rolling loss history lives beside the stats row; drop it with the route so a
    # restarted route does not inherit a stale 10 s window or streak.
    :ets.delete(@table_name, {:loss_window, route_id})
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

  defp log_health_change(route_id, prev, current, stats) do
    level =
      case current do
        "healthy" -> :info
        "disconnected" -> :info
        "blackgate_config_issue" -> :critical
        "critical" -> :critical
        _ -> :warning
      end

    type = "health_changed"

    # Name the route in the message, not only in metadata: with several routes running,
    # "Route health degraded to warning" leaves the operator guessing which one, and the
    # Events page only shows the route when the event carries route_name.
    name = route_name(route_id)

    base_message =
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

    Blackgate.EventLog.log(
      level,
      type,
      "#{base_message} on #{name} — #{health_evidence(stats)}",
      %{
        route_id: route_id,
        route_name: name,
        previous_health: prev,
        current_health: current,
        # The numbers that produced this verdict, so the event explains itself instead of
        # sending the operator to the dashboard to guess which metric tripped it. Health is
        # judged on the ~10 s loss window; the 1 s window is kept for diagnosis.
        loss_window_10s_pct: stats["loss-window-10s-pct"],
        loss_window_pct: stats["loss-window-pct"],
        loss_streak: stats["loss-streak"],
        cumulative_loss_pct: cumulative_loss_pct(stats),
        rtt_ms: stats["rtt-ms"],
        receive_rate_mbps: stats["receive-rate-mbps"],
        warning_count: stats["warning_count"]
      }
    )
  end

  # A one-second loss burst that SRT already retransmitted: real measurement, healthy route.
  defp log_loss_burst(route_id, stats) do
    name = route_name(route_id)

    Blackgate.EventLog.log(
      :info,
      "loss_burst",
      "Transient loss burst on #{name}: #{stats["loss-window-pct"]}% lost in the last 1 s window " <>
        "while the 10 s average is #{stats["loss-window-10s-pct"]}% and cumulative loss is " <>
        "#{cumulative_loss_pct(stats)}%.",
      %{
        route_id: route_id,
        route_name: name,
        loss_window_pct: stats["loss-window-pct"],
        loss_window_10s_pct: stats["loss-window-10s-pct"],
        cumulative_loss_pct: cumulative_loss_pct(stats),
        rtt_ms: stats["rtt-ms"],
        receive_rate_mbps: stats["receive-rate-mbps"]
      }
    )
  end

  # Human-readable basis for a health verdict, appended to every health event.
  defp health_evidence(stats) do
    streak = stats["loss-streak"] || 0

    [
      is_number(stats["loss-window-10s-pct"]) && "10 s loss #{stats["loss-window-10s-pct"]}%",
      is_number(stats["loss-window-pct"]) && "last 1 s window #{stats["loss-window-pct"]}%",
      "cumulative loss #{cumulative_loss_pct(stats)}%",
      is_number(stats["rtt-ms"]) && "RTT #{stats["rtt-ms"]} ms",
      streak > 1 && "above threshold for #{streak} consecutive reports"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
  end

  defp cumulative_loss_pct(stats) do
    received = stats["packets-received"] || 0
    lost = stats["packets-received-lost"] || 0

    if received + lost == 0 do
      0.0
    else
      Float.round(lost / (received + lost) * 100, 3)
    end
  end

  # The route record's display name, falling back to the id so an event is never lost
  # just because the route was deleted or renamed mid-flight. Khepri reads are in-process.
  defp route_name(route_id) do
    case Blackgate.Db.get_route(route_id) do
      {:ok, %{"name" => name}} when is_binary(name) and name != "" -> name
      _ -> route_id
    end
  end
end
