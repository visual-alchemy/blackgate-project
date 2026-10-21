defmodule Blackgate.RouteStatsRegistryTest do
  # Touches the shared :route_stats ETS table, so it must not run concurrently with
  # the other registry tests.
  use ExUnit.Case, async: false

  alias Blackgate.RouteStatsRegistry

  defp unique_route_id, do: "registry-test-#{System.unique_integer([:positive])}"

  test "get_stats/1 returns live data untouched" do
    route_id = unique_route_id()

    :ets.insert(
      :route_stats,
      {route_id, %{"health" => "healthy", "receive-rate-mbps" => 12.0},
       System.system_time(:millisecond)}
    )

    assert %{stats: stats, stale: false} = RouteStatsRegistry.get_stats(route_id)
    assert stats["health"] == "healthy"
    refute Map.has_key?(stats, "stale")

    RouteStatsRegistry.delete_stats(route_id)
  end

  test "get_stats/1 marks data stale once updates stop arriving" do
    route_id = unique_route_id()
    stale_at = System.system_time(:millisecond) - 60_000

    # This is what a dead route leaves behind: the last report, still saying healthy.
    # Serving it as live data made a stopped route look alive in the dashboard.
    :ets.insert(
      :route_stats,
      {route_id, %{"health" => "healthy", "receive-rate-mbps" => 12.0}, stale_at}
    )

    assert %{stats: stats, updated_at: ^stale_at, stale: true} =
             RouteStatsRegistry.get_stats(route_id)

    assert stats["health"] == "disconnected"
    assert stats["stale"] == true

    RouteStatsRegistry.delete_stats(route_id)
  end

  test "get_stats/1 returns nil for a route with no data" do
    assert RouteStatsRegistry.get_stats(unique_route_id()) == nil
  end

  test "health-change events name the route in both the message and the metadata" do
    # The Events page renders `metadata.route_name` beside the message, and an operator
    # running several routes cannot act on "Route health degraded to warning" alone.
    name = "NameCheck-#{System.unique_integer([:positive])}"
    {:ok, route} = Blackgate.Db.create_route(%{"name" => name})
    route_id = route["id"]

    # First report for this route: cumulative loss far past the critical threshold, so
    # put_stats evaluates a health transition and logs it.
    RouteStatsRegistry.put_stats(route_id, %{
      "receive-rate-mbps" => 10.0,
      "packets-received" => 100,
      "packets-received-lost" => 50
    })

    events = Blackgate.EventLog.get_events(limit: 10)

    # The event carries the numbers that tripped it, so it explains itself.
    assert Enum.any?(events, fn event ->
             event.type == "health_changed" and
               event.metadata[:route_name] == name and
               String.contains?(event.message, "on #{name}") and
               event.metadata[:cumulative_loss_pct] > 30.0 and
               Map.has_key?(event.metadata, :loss_window_pct) and
               Map.has_key?(event.metadata, :rtt_ms)
           end)

    RouteStatsRegistry.delete_stats(route_id)
    Blackgate.Db.delete_route(route_id)
  end

  test "a single lossy second is logged as a burst, not as degraded health" do
    # Measured on the box: 1 s windows of 2-7 % loss with cumulative loss of 0.17 % and SRT
    # retransmitting everything. Judging health on that window logged ~20 warnings per hour
    # per route on streams that never actually degraded.
    name = "BurstCheck-#{System.unique_integer([:positive])}"
    {:ok, route} = Blackgate.Db.create_route(%{"name" => name})
    route_id = route["id"]
    t0 = System.system_time(:millisecond) - 10_000

    RouteStatsRegistry.put_stats(route_id, base_stats(0, 0), t0)
    # A clean ten seconds ...
    RouteStatsRegistry.put_stats(route_id, base_stats(10_000, 5), t0 + 5_000)
    # ... then one second losing 25 of 1000 packets (2.4 %).
    RouteStatsRegistry.put_stats(route_id, base_stats(11_000, 30), t0 + 10_000)

    events = Blackgate.EventLog.get_events(limit: 20)

    assert Enum.any?(events, fn event ->
             event.type == "loss_burst" and
               event.severity == :info and
               event.metadata[:route_name] == name and
               String.contains?(event.message, "Transient loss burst on #{name}") and
               event.metadata[:loss_window_pct] > 2.0 and
               event.metadata[:loss_window_10s_pct] < 2.0
           end)

    # No degradation: the sustained figure stayed at 0.27 %.
    refute Enum.any?(events, fn event ->
             event.type == "health_changed" and event.severity == :warning and
               event.metadata[:route_name] == name
           end)

    assert %{stats: stats} = RouteStatsRegistry.get_stats(route_id)
    assert stats["health"] == "healthy"
    assert stats["loss-window-10s-pct"] < 2.0

    RouteStatsRegistry.delete_stats(route_id)
    Blackgate.Db.delete_route(route_id)
  end

  test "sustained loss degrades health only after three consecutive reports" do
    name = "StreakCheck-#{System.unique_integer([:positive])}"
    {:ok, route} = Blackgate.Db.create_route(%{"name" => name})
    route_id = route["id"]
    t0 = System.system_time(:millisecond) - 60_000

    RouteStatsRegistry.put_stats(route_id, base_stats(0, 0), t0)

    # Three consecutive reports at ~2.4 % loss: the first two must not degrade the route.
    RouteStatsRegistry.put_stats(route_id, base_stats(1000, 25), t0 + 1_000)
    RouteStatsRegistry.put_stats(route_id, base_stats(2000, 50), t0 + 2_000)

    refute Enum.any?(Blackgate.EventLog.get_events(limit: 20), fn event ->
             event.severity == :warning and event.metadata[:route_name] == name
           end)

    RouteStatsRegistry.put_stats(route_id, base_stats(3000, 75), t0 + 3_000)

    assert Enum.any?(Blackgate.EventLog.get_events(limit: 20), fn event ->
             event.type == "health_changed" and event.severity == :warning and
               event.metadata[:route_name] == name and
               event.metadata[:loss_streak] >= 3 and
               String.contains?(event.message, "Route health degraded to warning on #{name}") and
               String.contains?(event.message, "10 s loss")
           end)

    RouteStatsRegistry.delete_stats(route_id)
    Blackgate.Db.delete_route(route_id)
  end

  test "delete_stats/1 drops the rolling loss history with the route" do
    route_id = unique_route_id()

    RouteStatsRegistry.put_stats(route_id, base_stats(0, 0), 1_000)
    assert :ets.lookup(:route_stats, {:loss_window, route_id}) != []

    RouteStatsRegistry.delete_stats(route_id)
    assert :ets.lookup(:route_stats, {:loss_window, route_id}) == []
  end

  defp base_stats(received, lost) do
    %{
      "receive-rate-mbps" => 10.0,
      "packets-received" => received,
      "packets-received-lost" => lost,
      "rtt-ms" => 0.3
    }
  end
end
