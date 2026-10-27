defmodule Blackgate.LicenseTest do
  @moduledoc """
  License enforcement and manual sync.

  The decision logic (which routes a limit stops, what a sync does to the cache) is what is locked down here; the
  process-level stop itself belongs to Blackgate.stop_route/1 and is replaced by a recorder.
  """
  use ExUnit.Case, async: false
  alias Blackgate.{Db, License, LicenseEnforcer}

  setup do
    :meck.new(Req, [:passthrough])
    :meck.expect(Req, :post!, fn _, _ -> raise "offline" end)

    original_records = :khepri.get_many!("license/**")
    original_routes = :khepri.get_many!("routes/**")
    original_state = :sys.get_state(License)

    on_exit(fn ->
      :khepri.delete_many("routes/**")
      Enum.each(original_routes, fn {key, value} -> :khepri.put(key, value) end)
      :khepri.delete_many("license/**")
      Enum.each(original_records, fn {key, value} -> :khepri.put(key, value) end)
      :sys.replace_state(License, fn _ -> original_state end)
      send(License, :checkpoint)
      :meck.unload()
    end)

    :khepri.delete_many("routes/**")
    :ok
  end

  # Puts the process in the exact state a validated license produces, without a network round trip. The manual
  # sync bookkeeping is cleared as well, so tests do not inherit another test's cooldown or in-flight request.
  defp install(cache) do
    :sys.replace_state(
      License,
      &Map.merge(&1, %{
        cache: cache,
        waiters: [],
        checking: false,
        last_manual_sync_at: nil,
        generation: make_ref()
      })
    )

    send(License, :checkpoint)
    :sys.get_state(License)
  end

  defp licensed(capacity, deadline) do
    now = License.utc_now()

    %{
      status: :licensed,
      client: "RANS",
      plan: "pro",
      max_routes: capacity,
      deadline: deadline,
      key: "test-key",
      ever_licensed: true,
      verified_at: now,
      verification: "server_validated",
      offline_deadline: now + 30 * 86_400
    }
  end

  test "the trial caps saved routes at two" do
    install(%{
      status: :trial,
      max_routes: 2,
      deadline: License.utc_now() + 86_400,
      ever_licensed: false
    })

    assert {:ok, _} = Db.create_route(%{"name" => "one"})
    assert {:ok, _} = Db.create_route(%{"name" => "two"})

    assert {:error, {:route_creation_not_allowed, reason}} = Db.create_route(%{"name" => "three"})
    assert reason =~ "Trial route limit"
    assert {:ok, saved} = Db.get_all_routes()
    assert length(saved) == 2
  end

  # The bug this fixes: deactivation used to drop the appliance back into a fresh trial, so a withdrawn license
  # kept 2 routes alive and the operator saw a working gateway that was not licensed at all.
  test "deactivation blocks operation and never re-enters the trial" do
    install(licensed(8, License.utc_now() + 86_400))
    assert :ok = License.deactivate()

    license = License.get_license()
    assert license.status == :unlicensed
    assert license.expired
    assert license.max_routes == 0
    refute license.can_sync
    assert {:error, {:license, _reason}} = License.can_start_route?(nil)
  end

  test "evaluate reports expiry and offline grace as blocked states" do
    now = License.utc_now()
    assert %{expired: false} = License.evaluate(licensed(4, now + 60), now)
    assert %{expired: true, reason: reason} = License.evaluate(licensed(4, now - 1), now)
    assert reason =~ "expired"

    expired_grace = %{licensed(4, nil) | offline_deadline: now - 1}
    assert %{expired: true, reason: reason} = License.evaluate(expired_grace, now)
    assert reason =~ "Offline grace"
  end

  test "a route already running is allowed to restart at the capacity limit" do
    install(licensed(1, License.utc_now() + 86_400))

    :meck.new(Blackgate.ProcessMonitor, [:passthrough])

    :meck.expect(Blackgate.ProcessMonitor, :list_pipeline_processes, fn ->
      [%{route_id: "route-a"}]
    end)

    :meck.new(Db, [:passthrough])
    :meck.expect(Db, :get_route, fn "route-a", _include_dest? -> {:ok, %{"id" => "route-a"}} end)

    assert [%{"id" => "route-a"}] = Blackgate.running_routes()
    assert {:ok, :allowed} = License.can_start_route?("route-a")
    assert {:error, {:license, reason}} = License.can_start_route?("route-b")
    assert reason =~ "Route limit reached (1)"
  end

  test "enforcement stops only the routes beyond the limit, in route id order" do
    install(licensed(2, License.utc_now() + 86_400))

    :meck.new(Blackgate.ProcessMonitor, [:passthrough])

    :meck.expect(Blackgate.ProcessMonitor, :list_pipeline_processes, fn ->
      Enum.map(["c", "a", "d", "b"], &%{route_id: &1})
    end)

    :meck.new(Db, [:passthrough])
    :meck.expect(Db, :get_route, fn id, _include_dest? -> {:ok, %{"id" => id, "name" => id}} end)

    :meck.new(Blackgate, [:passthrough])
    parent = self()

    :meck.expect(Blackgate, :stop_route, fn id ->
      send(parent, {:stopped, id})
      :ok
    end)

    LicenseEnforcer.enforce()

    assert_receive {:stopped, "c"}
    assert_receive {:stopped, "d"}
    refute_received {:stopped, "a"}
    refute_received {:stopped, "b"}
  end

  # An expired license admits nothing, so the same reconciler is what cuts the live streams - no operator
  # interaction and no network: this is the offline half of enforcement.
  test "an expired license stops every running route" do
    install(licensed(4, License.utc_now() - 1))

    :meck.new(Blackgate.ProcessMonitor, [:passthrough])

    :meck.expect(Blackgate.ProcessMonitor, :list_pipeline_processes, fn ->
      [%{route_id: "x"}, %{route_id: "y"}]
    end)

    :meck.new(Db, [:passthrough])
    :meck.expect(Db, :get_route, fn id, _include_dest? -> {:ok, %{"id" => id, "name" => id}} end)

    :meck.new(Blackgate, [:passthrough])
    parent = self()

    :meck.expect(Blackgate, :stop_route, fn id ->
      send(parent, {:stopped, id})
      :ok
    end)

    LicenseEnforcer.enforce()

    assert_receive {:stopped, "x"}
    assert_receive {:stopped, "y"}
  end

  test "manual sync applies a refreshed entitlement immediately" do
    install(%{licensed(2, License.utc_now() + 86_400) | verification: "legacy_migration"})

    :meck.expect(Req, :post!, fn _, _ ->
      %{
        status: 200,
        body: %{
          "valid" => true,
          "license" => %{
            "client_name" => "RANS",
            "plan_tier" => "enterprise",
            "max_routes" => 16,
            "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
            "expires_at" => DateTime.utc_now() |> DateTime.add(365, :day) |> DateTime.to_iso8601()
          }
        }
      }
    end)

    assert {:ok, synced} = License.sync_now()
    assert synced.plan == "enterprise"
    assert synced.max_routes == 16
    assert synced.verification == "server_validated"
    assert synced.last_verified_at
  end

  test "concurrent syncs share one request and the completed sync rate limits the next" do
    install(licensed(2, License.utc_now() + 86_400))
    parent = self()
    {:ok, requests} = Agent.start_link(fn -> 0 end)

    :meck.expect(Req, :post!, fn _, _ ->
      Agent.update(requests, &(&1 + 1))
      send(parent, {:verification_started, self()})
      receive do: (:continue -> :ok)
      %{status: 200, body: %{"valid" => true, "license" => payload(4)}}
    end)

    callers = Enum.map(1..3, fn _ -> Task.async(&License.sync_now/0) end)
    assert_receive {:verification_started, verifier}, 1_000
    wait_until(fn -> length(Map.get(:sys.get_state(License), :waiters, [])) == 3 end)
    send(verifier, :continue)
    assert Enum.all?(callers, &match?({:ok, _}, Task.await(&1, 5_000)))
    assert Agent.get(requests, & &1) == 1

    assert {:error, :rate_limited, retry_after} = License.sync_now()
    assert retry_after in 1..30
    assert Agent.get(requests, & &1) == 1
  end

  test "a failed sync preserves the cached entitlement" do
    install(licensed(2, License.utc_now() + 86_400))
    before = License.get_license()

    :meck.expect(Req, :post!, fn _, _ -> raise "offline-secret-sentinel" end)

    assert {:error, :unreachable, "Cannot reach license server"} = License.sync_now()
    after_sync = License.get_license()
    assert after_sync.plan == before.plan
    assert after_sync.max_routes == before.max_routes
    assert after_sync.expires_at == before.expires_at
    assert after_sync.offline_deadline == before.offline_deadline
    assert after_sync.last_verified_at == before.last_verified_at
  end

  test "sync without an activated license is refused without calling the server" do
    install(%{
      status: :trial,
      max_routes: 2,
      deadline: License.utc_now() + 86_400,
      ever_licensed: false
    })

    assert {:error, :not_activated, reason} = License.sync_now()
    assert reason =~ "No activated license"
  end

  defp payload(capacity) do
    %{
      "client_name" => "RANS",
      "plan_tier" => "pro",
      "max_routes" => capacity,
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "expires_at" => nil
    }
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_until(fun, attempts - 1)
        )
  end

  defp wait_until(_fun, 0), do: flunk("condition did not become true")
end
