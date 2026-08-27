defmodule BlackgateWeb.DestinationControllerTest do
  use BlackgateWeb.ConnCase

  alias Blackgate.Db

  @destination_attrs %{
    "name" => "UDP destination",
    "schema" => "UDP",
    "schema_options" => %{"address" => "127.0.0.1", "port" => 9001}
  }

  setup do
    route_id = UUID.uuid4()
    assert {:ok, _route} = Db.create_route(%{"name" => "Destination parent"}, route_id)
    on_exit(fn -> Db.delete_route(route_id) end)

    %{route_id: route_id}
  end

  test "create and show use nested route path", %{conn: conn, route_id: route_id} do
    conn =
      post(conn, ~p"/api/routes/#{route_id}/destinations", destination: @destination_attrs)

    assert %{
             "id" => destination_id,
             "route_id" => ^route_id,
             "name" => "UDP destination",
             "restarted" => false
           } = json_response(conn, 201)["data"]

    conn =
      get(recycle(conn), ~p"/api/routes/#{route_id}/destinations/#{destination_id}")

    assert %{"id" => ^destination_id, "route_id" => ^route_id} =
             json_response(conn, 200)["data"]
  end

  test "index lists destinations below route", %{conn: conn, route_id: route_id} do
    destination_id = UUID.uuid4()

    assert {:ok, _destination} =
             Db.create_destination(route_id, @destination_attrs, destination_id)

    conn = get(conn, ~p"/api/routes/#{route_id}/destinations")

    assert [%{"id" => ^destination_id, "route_id" => ^route_id}] =
             json_response(conn, 200)["data"]
  end

  test "update persists destination and reports no restart for stopped route", %{
    conn: conn,
    route_id: route_id
  } do
    destination_id = UUID.uuid4()

    assert {:ok, _destination} =
             Db.create_destination(route_id, @destination_attrs, destination_id)

    conn =
      put(conn, ~p"/api/routes/#{route_id}/destinations/#{destination_id}",
        destination: %{"name" => "Updated destination"}
      )

    assert %{
             "id" => ^destination_id,
             "name" => "Updated destination",
             "restarted" => false
           } = json_response(conn, 200)["data"]

    assert {:ok, %{"name" => "Updated destination"}} =
             Db.get_destination(route_id, destination_id)
  end

  test "delete reports restart metadata and removes destination", %{
    conn: conn,
    route_id: route_id
  } do
    destination_id = UUID.uuid4()

    assert {:ok, _destination} =
             Db.create_destination(route_id, @destination_attrs, destination_id)

    conn = delete(conn, ~p"/api/routes/#{route_id}/destinations/#{destination_id}")

    assert %{"deleted" => true, "restarted" => false} = json_response(conn, 200)["data"]
    assert {:error, :not_found} = Db.get_destination(route_id, destination_id)
  end
end
