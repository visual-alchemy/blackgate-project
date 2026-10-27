defmodule BlackgateWeb.LicenseAdmissionTest do
  @moduledoc """
  The licence gate, and the path that used to walk around it.

  The gate was judged in the Start action and nowhere else, so the routes STARTED THROUGH IT were the only ones it
  ever saw: `Blackgate.start_route/1` itself never asked, and the bulk action calls that function directly. On a
  trial licence (2 routes) the operator could therefore fill the box with Start-all, and an expired licence could
  be worked around the same way - the dashboard said "started" and the engines really were running.

  The gate now lives inside `Blackgate.start_route/1` and `Blackgate.restart_route/1`, under the admission lock, so
  every path that starts an engine is judged by it. A refused start spawns NOTHING, which is why these cases need
  no engine: the licence is judged before anything else is touched.

  Who is running is judged from live engine processes, and a test may not spawn one, so the running set comes from
  the seam in `Blackgate.engine_process_route_ids/0` (`:persistent_term`, only read when set). The licence state is
  read from ETS, which is what `License.get_license/0` answers from, so it is set and restored here.
  """

  # `async: false` on purpose: the licence is one ETS entry for the whole node, and this file rewrites it.
  use BlackgateWeb.ConnCase, async: false

  alias Blackgate.Db

  @table :blackgate_license

  # Both routes in the claim cases listen on the same local port: that is the exclusive resource being fought over.
  # The listening port is a ROUTE-level field (`SdiClaims.listening_ports_of/1` reads the route's own schema options).
  @port 17_194

  defp license_attrs(name) do
    %{"name" => name, "schema" => "SRT", "schema_options" => %{"mode" => "caller"}}
  end

  defp listener_attrs(name) do
    %{
      "name" => name,
      "schema" => "SRT",
      "schema_options" => %{"mode" => "listener", "localport" => @port}
    }
  end

  # Nothing running: the routes are records only, so a refusal is the licence's and a mistaken allowance would go on
  # to spawn an engine (which is exactly what the refusal is there to prevent).
  defp put_license(data), do: :ets.insert(@table, {:license, data})

  defp licensed(max_routes) do
    put_license(%{
      status: :licensed,
      expired: false,
      max_routes: max_routes,
      days_remaining: 9999
    })
  end

  defp trial, do: put_license(%{status: :trial, expired: false, days_remaining: 20})

  defp expired, do: put_license(%{status: :licensed, expired: true, max_routes: 10})

  defp running(ids), do: :persistent_term.put({Blackgate, :running_route_ids}, ids)

  setup %{conn: conn} do
    previous = :ets.lookup(@table, :license)

    route_ids = Enum.map(1..3, fn _ -> UUID.uuid4() end)

    for {id, n} <- Enum.with_index(route_ids) do
      assert {:ok, _} = Db.create_route(license_attrs("Route #{n}"), id)
    end

    on_exit(fn ->
      :persistent_term.erase({Blackgate, :running_route_ids})

      case previous do
        [{:license, data}] -> :ets.insert(@table, {:license, data})
        [] -> :ets.delete(@table, :license)
      end

      Enum.each(route_ids, &Db.delete_route/1)
    end)

    %{conn: conn, ids: route_ids}
  end

  test "Start refuses with 402 once the licence capacity is already running", %{
    conn: conn,
    ids: [id | _]
  } do
    licensed(1)
    running([UUID.uuid4()])

    conn = get(conn, ~p"/api/routes/#{id}/start")

    assert %{"error" => error} = json_response(conn, 402)
    assert error =~ "Route limit reached (1)"
  end

  test "Start-all obeys the same gate - the path that used to bypass it", %{conn: conn, ids: ids} do
    licensed(1)
    running([UUID.uuid4()])

    conn = post(conn, ~p"/api/routes/bulk-action", %{action: "start", route_ids: ids})

    results = json_response(conn, 200)["data"]

    assert length(results) == 3

    # Every route is refused, by the licence, in the words the operator can act on: the summary the dashboard
    # builds from this ("0 routes started, 3 failed") must not be the only thing that says so.
    for result <- results do
      assert result["error"] =~ "Route limit reached (1)"
      refute Map.has_key?(result, "status")
    end
  end

  test "a trial licence stops at the trial limit, not at the plan limit", %{
    conn: conn,
    ids: [id | _]
  } do
    trial()
    running([UUID.uuid4(), UUID.uuid4()])

    conn = get(conn, ~p"/api/routes/#{id}/start")

    assert %{"error" => error} = json_response(conn, 402)
    assert error =~ "Trial limit reached (2 routes)"
  end

  test "an expired licence refuses even with nothing running", %{conn: conn, ids: [id | _]} do
    expired()
    running([])

    conn = get(conn, ~p"/api/routes/#{id}/start")

    assert %{"error" => error} = json_response(conn, 402)
    assert error =~ "License expired"
  end

  test "the licence is judged first: room left means the claim gate is what answers", %{
    conn: conn
  } do
    licensed(10)

    # Both routes listen on the same local port and the holder is running, so the claim gate refuses. The licence
    # is NOT what refuses - and that is the proof the gate ran and let this through: at capacity (or without the
    # gate) the answer below would have been the licence sentence, or a started engine.
    holder = UUID.uuid4()
    subject = UUID.uuid4()

    assert {:ok, _} = Db.create_route(listener_attrs("Holder"), holder)
    assert {:ok, _} = Db.create_route(listener_attrs("Subject"), subject)

    on_exit(fn ->
      Db.delete_route(holder)
      Db.delete_route(subject)
    end)

    running([holder])

    conn = get(conn, ~p"/api/routes/#{subject}/start")

    # `message` is the sentence the dashboard shows (it prefers `message` over `error`), and it names the port and
    # the holder. The licence did not answer.
    body = json_response(conn, 409)
    assert body["message"] =~ "port #{@port} is in use by Holder"
    refute body["message"] =~ "Route limit"
  end

  test "a restart is not a second slot: the running route is not counted against itself", %{} do
    # Two routes run, the licence has room for two, and BOTH listen on the same port, so the restart is refused by
    # the claim gate. Counting the route against itself is what this pins: `restart` reaches the gate with the
    # route it is about to stop still in the running set, and 2 >= 2 would make the licence refuse an edit the
    # operator is entitled to make. The refusal must be the claim, not the licence.
    holder = UUID.uuid4()
    subject = UUID.uuid4()

    assert {:ok, _} = Db.create_route(listener_attrs("Holder"), holder)
    assert {:ok, _} = Db.create_route(listener_attrs("Subject"), subject)

    on_exit(fn ->
      Db.delete_route(holder)
      Db.delete_route(subject)
    end)

    licensed(2)
    running([holder, subject])

    assert {:error, {:resource_in_use, claims}} = Blackgate.restart_route(subject)
    assert Blackgate.SdiClaims.describe_conflicts(claims) =~ "port #{@port} is in use by Holder"
  end

  test "a restart of a route that is NOT running is judged as the start it is", %{ids: [id | _]} do
    licensed(1)
    running([UUID.uuid4()])

    # Nothing holds the route and it is not running, so there is no engine to give back: this is a start that must
    # fit in the licence, and the licence is full.
    assert {:error, {:license, reason}} = Blackgate.restart_route(id)
    assert reason =~ "Route limit reached (1)"
  end
end
