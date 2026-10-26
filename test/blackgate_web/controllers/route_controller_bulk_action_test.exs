defmodule BlackgateWeb.RouteControllerBulkActionTest do
  @moduledoc """
  The bulk-action response contract, which the dashboard's bulk stop depends on.

  The UI reads `result.data.filter(...)`. A response without `data` therefore throws
  "Cannot read properties of undefined (reading 'filter')" and hides the real reason, so
  these tests pin the shape a caller can rely on: success always carries `data`, and a
  malformed request is a 400 whose body has no `data` at all (the UI must not parse it as
  success).
  """

  use BlackgateWeb.ConnCase

  alias Blackgate.Db

  @route_attrs %{
    "name" => "Bulk action route",
    "schema" => "SRT",
    "schema_options" => %{"mode" => "caller", "address" => "127.0.0.1", "port" => 9100},
    "status" => "stopped"
  }

  test "stop reports one entry per requested route", %{conn: conn} do
    route_id = UUID.uuid4()
    on_exit(fn -> Db.delete_route(route_id) end)
    assert {:ok, _route} = Db.create_route(@route_attrs, route_id)

    conn = post(conn, ~p"/api/routes/bulk-action", %{action: "stop", route_ids: [route_id]})

    assert %{"data" => [entry]} = json_response(conn, 200)
    assert entry["route_id"] == route_id
    # Either the route stopped, or the reason is reported per entry. Both are contractually
    # fine; what must never happen is a body with no `data`.
    assert entry["status"] == "stopped" or is_binary(entry["error"])
  end

  test "an unknown route id is reported per entry, not as a whole-request failure", %{conn: conn} do
    missing = "00000000-0000-0000-0000-000000000000"

    conn = post(conn, ~p"/api/routes/bulk-action", %{action: "stop", route_ids: [missing]})

    assert %{"data" => [entry]} = json_response(conn, 200)
    assert entry["route_id"] == missing
    assert is_binary(entry["error"])
  end

  test "an empty selection is a successful no-op with an empty list", %{conn: conn} do
    conn = post(conn, ~p"/api/routes/bulk-action", %{action: "stop", route_ids: []})

    assert %{"data" => []} = json_response(conn, 200)
  end

  # The dashboard used to send whatever the selection held. An action the controller does not
  # accept produced a 400 whose body has no `data`, which is exactly what crashed the UI.
  test "an unsupported action is a 400 without a data key", %{conn: conn} do
    conn = post(conn, ~p"/api/routes/bulk-action", %{action: "delete", route_ids: ["x"]})

    assert response(conn, 400)
    refute Map.has_key?(json_response(conn, 400), "data")
  end

  test "a request without route_ids is a 400 without a data key", %{conn: conn} do
    conn = post(conn, ~p"/api/routes/bulk-action", %{action: "stop"})

    assert response(conn, 400)
    refute Map.has_key?(json_response(conn, 400), "data")
  end
end
