defmodule BlackgateWeb.DestinationRefusalTest do
  use BlackgateWeb.ConnCase

  alias Blackgate.Db

  @destination_attrs %{
    "name" => "UDP destination",
    "schema" => "UDP",
    "schema_options" => %{"address" => "127.0.0.1", "port" => 9101}
  }

  setup do
    route_id = UUID.uuid4()
    assert {:ok, _route} = Db.create_route(%{"name" => "Refusal parent"}, route_id)
    on_exit(fn -> Db.delete_route(route_id) end)

    %{route_id: route_id}
  end

  # `Db.update_destination/3` answers `{:error, :destination_not_found}` for a destination that is gone
  # (a second dashboard tab, a restore, a delete in between). The controller's `with` handed that to
  # `BlackgateWeb.FallbackController`, whose only clause matched `:not_found`, so the unmatched tuple
  # raised `FunctionClauseError` inside the fallback: the operator saw a server fault for a destination
  # that simply is not there any more. Verified red against the old fallback - both tests below raised.
  test "editing a destination that no longer exists answers 404, not a crash", %{
    conn: conn,
    route_id: route_id
  } do
    gone_id = UUID.uuid4()

    conn =
      put(conn, ~p"/api/routes/#{route_id}/destinations/#{gone_id}",
        destination: @destination_attrs
      )

    assert json_response(conn, 404)["message"] == "Destination not found"
  end

  test "editing a route that no longer exists answers 404, not a crash", %{conn: conn} do
    conn = put(conn, ~p"/api/routes/#{UUID.uuid4()}", route: %{"name" => "gone"})

    assert json_response(conn, 404)["message"] == "Route not found"
  end

  # The same class one step earlier: `Db.create_destinations/2` halts with a non-object entry in a
  # create-route request, which is the operator's input and not a server fault.
  test "creating a route whose destinations contain a non-object answers 400", %{conn: conn} do
    conn =
      post(conn, ~p"/api/routes",
        route: %{"name" => "bad destinations", "destinations" => ["not an object"]}
      )

    assert json_response(conn, 400)["message"] =~
             "A destination must be an object, got: \"not an object\""
  end
end
