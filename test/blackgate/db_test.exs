defmodule Blackgate.DbTest do
  use ExUnit.Case, async: false

  alias Blackgate.Db

  setup do
    route_id = UUID.uuid4()

    on_exit(fn ->
      :khepri.delete_many("routes/#{route_id}/**")
      :khepri.delete(["routes", route_id])
    end)

    %{route_id: route_id}
  end

  test "create_route stores destinations below route and returns hydrated route", %{
    route_id: route_id
  } do
    destination = %{
      "schema" => "UDP",
      "schema_options" => %{"address" => "127.0.0.1", "port" => 9001}
    }

    assert {:ok, route} =
             Db.create_route(
               %{"name" => "Khepri route", "destinations" => [destination]},
               route_id
             )

    assert route["id"] == route_id
    assert [%{"route_id" => ^route_id}] = route["destinations"]
    assert {:ok, stored} = :khepri.get(["routes", route_id])
    refute Map.has_key?(stored, "destinations")
  end

  test "update and delete route preserve Khepri contracts", %{route_id: route_id} do
    assert {:ok, _} = Db.create_route(%{"name" => "before"}, route_id)
    assert {:ok, %{"name" => "after"}} = Db.update_route(route_id, %{"name" => "after"})
    assert [:ok, :ok] = Db.delete_route(route_id)
    assert {:error, :not_found} = Db.get_route(route_id)
    assert {:error, :not_found} = Db.get_destination(route_id, UUID.uuid4())
  end

  test "create_route removes partial data when a destination is invalid", %{route_id: route_id} do
    valid_destination = %{
      "schema" => "UDP",
      "schema_options" => %{"address" => "127.0.0.1", "port" => 9002}
    }

    assert {:error, _reason} =
             Db.create_route(
               %{"name" => "rollback", "destinations" => [valid_destination, :invalid]},
               route_id
             )

    assert {:error, :not_found} = Db.get_route(route_id)
    assert {:ok, destinations} = :khepri.get_many("routes/#{route_id}/destinations/*")
    assert destinations == %{}
  end
end
