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
end
