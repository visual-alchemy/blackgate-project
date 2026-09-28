defmodule Blackgate.LicenseTestClock do
  def utc_now, do: Agent.get(__MODULE__, & &1)
end

defmodule Blackgate.LicenseEnforcementTest do
  use ExUnit.Case, async: false
  alias Blackgate.{License, Db}
  @path ["license", "enforcement_v1"]

  setup do
    unless Process.whereis(Blackgate.Cache),
      do: start_supervised!({Cachex, name: Blackgate.Cache})

    :ok = Supervisor.terminate_child(Blackgate.Supervisor, Blackgate.LicenseEnforcer)
    original = :sys.get_state(License)
    original_ets = :ets.lookup(:blackgate_license, :license)
    original_records = :khepri.get_many!("license/**")

    {:ok, clock} =
      Agent.start_link(fn -> DateTime.utc_now() end, name: Blackgate.LicenseTestClock)

    Application.put_env(:blackgate, :license_clock, Blackgate.LicenseTestClock)
    :meck.new(Req, [:passthrough])
    :meck.expect(Req, :post!, fn _, _ -> raise "offline" end)
    :meck.new(Blackgate.RoutesSupervisor, [:passthrough])
    # Exercise real DynamicSupervisors and route registry without SDI hardware.
    :meck.expect(Blackgate.RoutesSupervisor, :start_link, fn %{id: id} ->
      Supervisor.start_link(
        [
          %{id: {:route_handler, id}, start: {Agent, :start_link, [fn -> :stream end]}}
        ],
        strategy: :one_for_one,
        name: {:via, :syn, {:routes, id}}
      )
    end)

    on_exit(fn ->
      Enum.each(Blackgate.running_routes(), &Blackgate.stop_route(&1.id))
      :khepri.delete_many("routes/**")
      :khepri.delete_many("license/**")
      Enum.each(original_records, fn {key, value} -> :khepri.put(key, value) end)
      Application.delete_env(:blackgate, :license_clock)
      if Process.alive?(clock), do: Agent.stop(clock)

      :sys.replace_state(License, fn _ ->
        :ets.insert(:blackgate_license, original_ets)
        original
      end)

      :meck.unload()
      Supervisor.restart_child(Blackgate.Supervisor, Blackgate.LicenseEnforcer)
    end)

    activate(4)
    :ok
  end

  defp activate(capacity, expiry \\ nil) do
    :meck.expect(Req, :post!, fn _, _ ->
      %{
        status: 200,
        body: %{
          "valid" => true,
          "license" => %{
            "client_name" => "RANS",
            "plan_tier" => "trial",
            "max_routes" => capacity,
            "created_at" => DateTime.to_iso8601(Blackgate.LicenseTestClock.utc_now()),
            "expires_at" => expiry
          }
        }
      }
    end)

    assert {:ok, _} = License.activate("test-license")
  end

  defp route(id) do
    assert {:ok, _} = Db.create_route(%{"name" => id, "status" => "stopped"}, id)
    id
  end

  defp install(cache) do
    :sys.replace_state(License, &Map.put(&1, :cache, cache))
    send(License, :checkpoint)
    :sys.get_state(License)
  end

  defp license_payload(capacity, expiry \\ nil) do
    %{
      "client_name" => "RANS",
      "plan_tier" => "pro",
      "max_routes" => capacity,
      "created_at" => DateTime.to_iso8601(Blackgate.LicenseTestClock.utc_now()),
      "expires_at" => expiry
    }
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition did not become true")

  test "concurrent starts reserve capacity; status edits cannot free slots" do
    ids = Enum.map(1..12, &route("limit-#{&1}"))

    results =
      Task.async_stream(ids, &Blackgate.start_route/1, max_concurrency: 12) |> Enum.to_list()

    assert Enum.count(results, &match?({:ok, {:ok, _}}, &1)) == 4
    assert length(Blackgate.running_routes()) == 4
    [running | _] = Blackgate.running_routes()
    assert {:ok, existing_pid} = Blackgate.get_route(running.id)
    assert {:ok, ^existing_pid} = Blackgate.start_route(running.id)
    assert {:ok, _} = Db.update_route(running.id, %{"status" => "stopped"})
    assert {:ok, :restarted} = Blackgate.restart_route(running.id)

    stopped =
      Enum.find(ids, fn id -> not Enum.any?(Blackgate.running_routes(), &(&1.id == id)) end)

    assert {:error, _} = Blackgate.restart_route(stopped)
    assert length(Blackgate.running_routes()) == 4
  end

  test "expiry blocks start, restart and bulk start; cutoff stops four and keeps records" do
    deadline = Blackgate.LicenseTestClock.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
    activate(4, deadline)
    ids = Enum.map(1..4, &route("expire-#{&1}"))
    Enum.each(ids, fn id -> assert {:ok, _} = Blackgate.start_route(id) end)
    Agent.update(Blackgate.LicenseTestClock, &DateTime.add(&1, 60))
    assert License.get_license().expired
    assert {:error, _} = Blackgate.start_route(hd(ids))
    assert {:error, _} = Blackgate.restart_route(hd(ids))
    assert catch_exit(Blackgate.RouteHandler.init(%{id: hd(ids)})) == :normal

    assert catch_exit(
             Blackgate.RouteHandler.handle_event({:timeout, :reconnect}, :retry, :reconnecting, %{
               id: hd(ids)
             })
           ) == :normal

    conn = Phoenix.ConnTest.build_conn()

    conn =
      BlackgateWeb.RouteController.bulk_action(conn, %{"action" => "start", "route_ids" => ids})

    assert Enum.all?(Jason.decode!(conn.resp_body)["data"], &Map.has_key?(&1, "error"))
    Blackgate.LicenseEnforcer.enforce()
    assert Blackgate.running_routes() == []
    assert {:ok, saved} = Db.get_all_routes()
    assert length(saved) == 4
    assert Enum.all?(saved, &(&1["status"] == "stopped"))
    activate(4)
    assert {:ok, _} = Blackgate.start_route(hd(ids))
  end

  test "offline deadline and revocation survive license process restart" do
    before = License.get_license().offline_deadline
    :meck.expect(Req, :post!, fn _, _ -> raise "offline" end)
    Supervisor.terminate_child(Blackgate.Supervisor, License)
    assert {:ok, _} = Supervisor.restart_child(Blackgate.Supervisor, License)
    assert License.get_license().offline_deadline == before
    Agent.update(Blackgate.LicenseTestClock, &DateTime.add(&1, 31 * 86_400))
    assert License.get_license().expired
    assert License.get_license().reason =~ "Offline grace"
    activate(4)
    state = :sys.get_state(License)
    send(License, {:verified, state.generation, {:error, :revoked, "Revoked by issuer"}})
    :sys.get_state(License)
    assert License.get_license().status == :revoked
    :meck.expect(Req, :post!, fn _, _ -> raise "offline" end)
    Supervisor.terminate_child(Blackgate.Supervisor, License)
    assert {:ok, _} = Supervisor.restart_child(Blackgate.Supervisor, License)
    assert License.get_license().expired
    assert License.get_license().status == :revoked
    License.deactivate()
    assert License.get_license().status == :unlicensed
  end

  test "built-in trial expires without reboot and concurrent creation stays at two" do
    now = License.utc_now()
    install(%{status: :trial, deadline: now + 60, max_routes: 2, ever_licensed: false})

    results =
      Task.async_stream(1..8, fn n -> Db.create_route(%{"name" => "Trial"}, "trial-#{n}") end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.count(results, &match?({:ok, {:ok, _}}, &1)) == 2
    Agent.update(Blackgate.LicenseTestClock, &DateTime.add(&1, 60))
    assert License.get_license().expired
    assert {:error, _} = Db.create_route(%{"name" => "Late"})
  end

  test "backup cannot replace license, trial history or accounts" do
    original = :khepri.get!(@path)
    :ok = :khepri.put(["users", "sentinel"], %{"role" => "admin"})

    input = %{
      ["routes", "restored"] => %{"id" => "wrong", "name" => "Restored", "status" => "started"},
      @path => %{status: :licensed, max_routes: 9999},
      ["license", "first_boot"] => "2099-01-01T00:00:00Z",
      ["users", "sentinel"] => %{"role" => "operator"}
    }

    assert :ok = Db.restore_backup(:erlang.term_to_binary(input))
    assert :khepri.get!(@path) == original
    assert :khepri.get!(["users", "sentinel"]) == %{"role" => "admin"}
    assert {:ok, %{"id" => "restored", "status" => "stopped"}} = Db.get_route("restored")
    assert {:ok, backup} = Db.backup()
    exported = :erlang.binary_to_term(backup, [:safe])
    refute Map.has_key?(exported, @path)
    refute Map.has_key?(exported, ["users", "sentinel"])
    :khepri.delete(["users", "sentinel"])
  end

  test "clock rollback cannot lower persisted time floor" do
    Agent.update(Blackgate.LicenseTestClock, &DateTime.add(&1, 86_400))
    send(License, :checkpoint)
    floor = :sys.get_state(License).cache.last_seen_at
    Agent.update(Blackgate.LicenseTestClock, &DateTime.add(&1, -2 * 86_400))
    Supervisor.terminate_child(Blackgate.Supervisor, License)
    assert {:ok, _} = Supervisor.restart_child(Blackgate.Supervisor, License)
    assert :sys.get_state(License).cache.last_seen_at >= floor
  end

  test "periodic worker stops streams at expiry without network validation" do
    expiry = Blackgate.LicenseTestClock.utc_now() |> DateTime.add(10) |> DateTime.to_iso8601()
    activate(4, expiry)
    id = route("timer-route")
    {:ok, pid} = Blackgate.start_route(id)
    ref = Process.monitor(pid)
    Agent.update(Blackgate.LicenseTestClock, &DateTime.add(&1, 10))
    {:ok, _} = Supervisor.restart_child(Blackgate.Supervisor, Blackgate.LicenseEnforcer)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5000
    assert Blackgate.running_routes() == []
    Supervisor.terminate_child(Blackgate.Supervisor, Blackgate.LicenseEnforcer)
  end

  test "capacity downgrade stops excess routes deterministically" do
    ids = Enum.map(1..4, &route("downgrade-#{&1}"))
    Enum.each(ids, &Blackgate.start_route/1)
    activate(2)
    Blackgate.LicenseEnforcer.enforce()
    assert Enum.map(Blackgate.running_routes(), & &1.id) == Enum.take(ids, 2)
    assert {:ok, saved} = Db.get_all_routes()
    assert length(saved) == 4
  end

  test "migration grace persists once and retains original expiry" do
    :meck.expect(Req, :post!, fn _, _ -> raise "offline" end)
    expiry = Blackgate.LicenseTestClock.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    :khepri.put(["license", "data"], %{
      "license_key" => "old-key",
      "max_routes" => 4,
      "expires_at" => expiry,
      "client_name" => "RANS"
    })

    Supervisor.terminate_child(Blackgate.Supervisor, License)
    :khepri.delete(@path)
    {:ok, _} = Supervisor.restart_child(Blackgate.Supervisor, License)
    license = License.get_license()
    assert license.verification == "legacy_migration"
    {:ok, expiry_dt, _} = DateTime.from_iso8601(expiry)
    assert license.expires_at == expiry_dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    Supervisor.terminate_child(Blackgate.Supervisor, License)
    {:ok, _} = Supervisor.restart_child(Blackgate.Supervisor, License)
    assert License.get_license().offline_deadline == license.offline_deadline
    Agent.update(Blackgate.LicenseTestClock, &DateTime.add(&1, 3600))
    assert License.get_license().expired
  end

  test "restore rejects unauthenticated and operator requests" do
    opts = BlackgateWeb.Router.init([])

    assert Plug.Test.conn(:post, "/api/restore", "bad")
           |> BlackgateWeb.Router.call(opts)
           |> Map.get(:status) == 403

    :khepri.put(["users", "audit-operator"], %{
      "id" => "audit-operator",
      "username" => "audit",
      "role" => "operator",
      "enabled" => true
    })

    Cachex.put(Blackgate.Cache, "auth_session:audit-token", %{"id" => "audit-operator"})

    conn =
      Plug.Test.conn(:post, "/api/restore", "bad")
      |> Plug.Conn.put_req_header("authorization", "Bearer audit-token")
      |> BlackgateWeb.Router.call(opts)

    assert conn.status == 403
    assert conn.resp_body =~ "Admin role required"
    :khepri.delete(["users", "audit-operator"])
    Cachex.del(Blackgate.Cache, "auth_session:audit-token")
  end

  test "manual sync applies an extended entitlement immediately" do
    expiry =
      Blackgate.LicenseTestClock.utc_now() |> DateTime.add(90 * 86_400) |> DateTime.to_iso8601()

    :meck.expect(Req, :post!, fn _, _ ->
      %{status: 200, body: %{"valid" => true, "license" => license_payload(8, expiry)}}
    end)

    assert {:ok, synced} = License.sync_now()
    assert synced.plan == "pro"
    assert synced.max_routes == 8
    assert {:ok, synced_expiry, _} = DateTime.from_iso8601(synced.expires_at)
    assert {:ok, expected_expiry, _} = DateTime.from_iso8601(expiry)
    assert DateTime.to_unix(synced_expiry) == DateTime.to_unix(expected_expiry)
    assert synced.can_sync
    assert synced.last_verified_at
  end

  test "concurrent manual sync callers share one request and cooldown rate limits repeats" do
    parent = self()
    {:ok, requests} = Agent.start_link(fn -> 0 end)

    :meck.expect(Req, :post!, fn _, _ ->
      Agent.update(requests, &(&1 + 1))
      send(parent, {:verification_started, self()})
      receive do: (:continue -> :ok)
      %{status: 200, body: %{"valid" => true, "license" => license_payload(4)}}
    end)

    callers = Enum.map(1..3, fn _ -> Task.async(&License.sync_now/0) end)
    assert_receive {:verification_started, verifier}, 1_000
    wait_until(fn -> length(Map.get(:sys.get_state(License), :waiters, [])) == 3 end)
    send(verifier, :continue)
    assert Enum.all?(callers, &match?({:ok, _}, Task.await(&1)))
    assert Agent.get(requests, & &1) == 1
    assert {:error, :rate_limited, retry_after} = License.sync_now()
    assert retry_after in 1..30
    assert Agent.get(requests, & &1) == 1
  end

  test "manual sync preserves cached entitlement when server is unreachable" do
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

  test "sync endpoint requires Admin and never returns the license key" do
    :meck.expect(Req, :post!, fn _, _ ->
      %{status: 200, body: %{"valid" => true, "license" => license_payload(4)}}
    end)

    for {id, role, token} <- [
          {"sync-operator", "operator", "sync-operator-token"},
          {"sync-admin", "admin", "sync-admin-token"}
        ] do
      :ok =
        :khepri.put(["users", id], %{
          "id" => id,
          "username" => id,
          "role" => role,
          "enabled" => true
        })

      {:ok, true} = Cachex.put(Blackgate.Cache, "auth_session:#{token}", %{"id" => id})
    end

    opts = BlackgateWeb.Router.init([])

    assert Plug.Test.conn(:post, "/api/license/sync")
           |> BlackgateWeb.Router.call(opts)
           |> Map.get(:status) == 403

    assert Plug.Test.conn(:post, "/api/license/sync")
           |> Plug.Conn.put_req_header("authorization", "Bearer sync-operator-token")
           |> BlackgateWeb.Router.call(opts)
           |> Map.get(:status) == 403

    conn =
      Plug.Test.conn(:post, "/api/license/sync")
      |> Plug.Conn.put_req_header("authorization", "Bearer sync-admin-token")
      |> BlackgateWeb.Router.call(opts)

    assert conn.status == 200
    refute conn.resp_body =~ "test-license"
    refute conn.resp_body =~ "license_key"
    assert Jason.decode!(conn.resp_body)["data"]["max_routes"] == 4

    rate_limited =
      Plug.Test.conn(:post, "/api/license/sync")
      |> Plug.Conn.put_req_header("authorization", "Bearer sync-admin-token")
      |> BlackgateWeb.Router.call(opts)

    assert rate_limited.status == 429
    assert Plug.Conn.get_resp_header(rate_limited, "retry-after") != []
    assert Jason.decode!(rate_limited.resp_body)["retry_after_seconds"] in 1..30

    Enum.each(["sync-operator", "sync-admin"], &:khepri.delete(["users", &1]))

    Enum.each(["sync-operator-token", "sync-admin-token"], fn token ->
      Cachex.del(Blackgate.Cache, "auth_session:#{token}")
    end)
  end
end
