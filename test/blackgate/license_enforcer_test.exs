defmodule Blackgate.LicenseEnforcerTest do
  @moduledoc """
  The pass that stops what the licence no longer covers.

  The admission gate can only judge a licence when a route is STARTED. These cases are about what happens to
  engines that were already running when the licence changed under them: an expired key, a trial that ran out, or
  a plan that covers fewer routes than are up.

  The running set comes from the seam in `Blackgate.engine_process_route_ids/0` (`:persistent_term`), and the
  licence from the ETS entry `License.get_license/0` reads. Both are set and restored here. The enforcer's own
  10-second tick is suspended for the length of each test, so a tick cannot stop a route this file is asserting
  about - what is asserted is the pass the caller asked for.

  The pass's effect on a route is judged on a real tree: `stop_route/1` follows the registry entry and stops the
  process it finds, so a registered `Supervisor` stands in for a route tree and its liveness afterwards is the
  answer. The record's `status` is written by the RouteHandler as it terminates, which needs a real engine and is
  covered by the live gateway.

  Each test uses route ids of its own: the event log is one node-wide ring buffer, so an assertion about events
  has to be scoped to the ids the test asked about.
  """

  # `async: false`: the licence is one ETS entry for the whole node and this file rewrites it.
  use ExUnit.Case, async: false

  alias Blackgate.{EventLog, LicenseEnforcer}

  @table :blackgate_license

  setup do
    previous = :ets.lookup(@table, :license)

    # The enforcer's own tick would otherwise stop routes this file is in the middle of asserting about.
    :sys.suspend(LicenseEnforcer)

    on_exit(fn ->
      :sys.resume(LicenseEnforcer)
      :persistent_term.erase({Blackgate, :running_route_ids})

      case previous do
        [{:license, data}] -> :ets.insert(@table, {:license, data})
        [] -> :ets.delete(@table, :license)
      end
    end)

    :ok
  end

  defp put_license(data), do: :ets.insert(@table, {:license, data})

  defp licensed(max_routes),
    do: put_license(%{status: :licensed, expired: false, max_routes: max_routes})

  defp trial, do: put_license(%{status: :trial, expired: false, days_remaining: 20})
  defp expired, do: put_license(%{status: :licensed, expired: true, max_routes: 10})

  defp running(ids), do: :persistent_term.put({Blackgate, :running_route_ids}, ids)

  # A route that is really running, as far as `stop_route/1` is concerned: it looks the route up in the registry
  # and stops the process it finds there.
  defp start_fake_route(id) do
    {:ok, tree} =
      Supervisor.start_link([], strategy: :one_for_one, name: {:via, :syn, {:routes, id}})

    tree
  end

  defp events_for(ids) do
    EventLog.get_events(limit: 50)
    |> Enum.filter(&(&1.type == "license_route_stopped" and &1.metadata[:route_id] in ids))
  end

  test "stops the routes above the capacity, by id, and leaves the rest running" do
    licensed(2)

    # The rule is "sorted by id, the first `capacity` are kept", so the fixtures are named to sort that way: the
    # ids that come later alphabetically are the ones the licence no longer covers.
    kept = [start_fake_route("keep-1"), start_fake_route("keep-2")]
    dropped = [start_fake_route("z-drop-1"), start_fake_route("z-drop-2")]

    running(["z-drop-2", "keep-2", "z-drop-1", "keep-1"])

    assert {:ok, ["z-drop-1", "z-drop-2"]} = LicenseEnforcer.enforce()

    assert Enum.all?(kept, &Process.alive?/1)
    assert Enum.all?(dropped, &(not Process.alive?(&1)))

    # One event per stopped route, naming the route and the licence it fell outside of.
    events = events_for(["z-drop-1", "z-drop-2"])
    assert Enum.map(events, & &1.metadata[:route_id]) |> Enum.sort() == ["z-drop-1", "z-drop-2"]

    event = hd(events)
    assert event.severity == :warning
    assert event.message =~ "the licence covers 2 routes"
    assert event.metadata[:running_routes] == 4
    assert event.metadata[:capacity] == 2
  end

  test "a licence that covers everything stops nothing" do
    licensed(10)

    trees = [start_fake_route("covered-1"), start_fake_route("covered-2")]
    running(["covered-1", "covered-2"])

    assert {:ok, []} = LicenseEnforcer.enforce()
    assert Enum.all?(trees, &Process.alive?/1)
    assert events_for(["covered-1", "covered-2"]) == []
  end

  test "the same route set is chosen every pass, so the same streams are not cut on a loop" do
    licensed(1)
    running(["stable-b", "stable-a", "stable-c"])

    assert {:ok, ["stable-b", "stable-c"]} = LicenseEnforcer.enforce()
    assert {:ok, ["stable-b", "stable-c"]} = LicenseEnforcer.enforce()
  end

  test "an expired licence takes every running route down" do
    expired()

    trees = [start_fake_route("gone-1"), start_fake_route("gone-2")]
    running(["gone-1", "gone-2"])

    assert {:ok, ["gone-1", "gone-2"]} = LicenseEnforcer.enforce()
    refute Enum.any?(trees, &Process.alive?/1)
    assert hd(events_for(["gone-1", "gone-2"])).message =~ "the licence has expired"
  end

  test "a trial is enforced at the trial capacity, not at the plan's" do
    trial()
    running(["trial-1", "trial-2", "trial-3"])

    assert {:ok, ["trial-3"]} = LicenseEnforcer.enforce()
    assert hd(events_for(["trial-3"])).message =~ "the trial covers 2 routes"
  end

  test "an unreadable licence state stops nothing and does not crash the pass" do
    licensed(10)
    running(["hidden-1", "hidden-2"])

    # Stands in for a table that is not up yet, or one that went away: reading it raises rather than answering.
    :ets.rename(@table, :blackgate_license_hidden)

    try do
      assert :unreadable = LicenseEnforcer.enforce()
      assert events_for(["hidden-1", "hidden-2"]) == []
    after
      :ets.rename(:blackgate_license_hidden, @table)
    end
  end

  test "a licence change is enforced straight away instead of on the next tick" do
    # This is the call `License` makes when a key is activated, deactivated, or re-verified by the heartbeat. The
    # enforcer is suspended in this test, so the event below can only come from the cast being processed.
    licensed(1)
    running(["soon-1", "soon-2"])
    :sys.resume(LicenseEnforcer)

    assert :ok = LicenseEnforcer.enforce_soon()

    assert Enum.any?(1..50, fn _ ->
             Process.sleep(20)
             events_for(["soon-1", "soon-2"]) != []
           end)
  end
end
