defmodule BlackgateWeb.RouteControllerTest do
  use BlackgateWeb.ConnCase

  alias Blackgate.Db

  @route_attrs %{
    "name" => "Khepri route",
    "schema" => "SRT",
    "schema_options" => %{"mode" => "caller", "address" => "127.0.0.1", "port" => 9000},
    "status" => "stopped"
  }

  test "index lists Khepri routes", %{conn: conn} do
    route_id = UUID.uuid4()
    cleanup_route(route_id)
    assert {:ok, _route} = Db.create_route(@route_attrs, route_id)

    conn = get(conn, ~p"/api/routes")

    assert routes = json_response(conn, 200)["data"]
    assert Enum.any?(routes, &(&1["id"] == route_id and &1["connected"] == false))
  end

  test "create and show persist a map route", %{conn: conn} do
    conn = post(conn, ~p"/api/routes", route: @route_attrs)
    assert %{"id" => route_id, "name" => "Khepri route"} = json_response(conn, 201)["data"]
    cleanup_route(route_id)

    conn = get(recycle(conn), ~p"/api/routes/#{route_id}")

    assert %{
             "id" => ^route_id,
             "name" => "Khepri route",
             "schema" => "SRT",
             "destinations" => []
           } = json_response(conn, 200)["data"]
  end

  test "update persists route and reports no restart for stopped route", %{conn: conn} do
    route_id = UUID.uuid4()
    cleanup_route(route_id)
    assert {:ok, _route} = Db.create_route(@route_attrs, route_id)

    conn = put(conn, ~p"/api/routes/#{route_id}", route: %{"name" => "Updated route"})

    assert %{"id" => ^route_id, "name" => "Updated route", "restarted" => false} =
             json_response(conn, 200)["data"]

    assert {:ok, %{"name" => "Updated route"}} = Db.get_route(route_id)
  end

  test "delete removes route and destinations", %{conn: conn} do
    route_id = UUID.uuid4()
    cleanup_route(route_id)

    assert {:ok, _route} =
             Db.create_route(
               Map.put(@route_attrs, "destinations", [%{"schema" => "UDP"}]),
               route_id
             )

    conn = delete(conn, ~p"/api/routes/#{route_id}")

    assert response(conn, 204)
    assert {:error, :not_found} = Db.get_route(route_id)
    assert {:ok, %{}} = Db.get_all_destinations(route_id)
  end

  defp cleanup_route(route_id) do
    on_exit(fn -> Db.delete_route(route_id) end)
  end
end

defmodule BlackgateWeb.RouteControllerSwitchSourceTest do
  @moduledoc """
  Meck-isolated source-switch behavior through real Phoenix routing.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint BlackgateWeb.Endpoint

  @auth_token "switch-source-test-token"
  @route_id "route-1"

  setup do
    :meck.new(Cachex, [:passthrough])

    :meck.expect(Cachex, :get, fn
      Blackgate.Cache, "auth_session:" <> _ -> {:ok, %{user: "admin"}}
      cache, key -> :meck.passthrough([cache, key])
    end)

    :meck.new(Blackgate.Db, [:non_strict])
    :meck.new(Blackgate, [:non_strict])

    on_exit(fn ->
      :meck.unload()
    end)

    :ok
  end

  defp auth_conn do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{@auth_token}")
  end

  defp failover_route do
    %{
      "id" => @route_id,
      "name" => "Failover Route",
      "schema" => "SRT",
      "failover_enabled" => true,
      "failover_mode" => "maintain-stability",
      "secondary_source" => %{"schema" => "SRT", "schema_options" => %{}}
    }
  end

  test "switch-source with valid target returns 200 and switched status" do
    :meck.expect(Blackgate.Db, :get_route, fn @route_id, _ -> {:ok, failover_route()} end)
    :meck.expect(Blackgate, :switch_route_source, fn @route_id, "secondary" -> :ok end)

    conn =
      auth_conn()
      |> post("/api/routes/#{@route_id}/switch-source", %{target: "secondary"})

    assert json_response(conn, 200)["data"] == %{
             "status" => "switched",
             "active_source" => "secondary"
           }

    assert :meck.num_calls(Blackgate, :switch_route_source, [@route_id, "secondary"]) == 1
  end

  test "switch-source with invalid target returns 400 and does not switch" do
    :meck.expect(Blackgate.Db, :get_route, fn @route_id, _ -> {:ok, failover_route()} end)
    :meck.expect(Blackgate, :switch_route_source, fn _, _ -> :ok end)

    conn =
      auth_conn()
      |> post("/api/routes/#{@route_id}/switch-source", %{target: "tertiary"})

    assert response(conn, 400)
    assert json_response(conn, 400)["error"] != nil
    assert :meck.num_calls(Blackgate, :switch_route_source, :_) == 0
  end

  test "switch-source returns 400 when failover is disabled and does not switch" do
    route = Map.put(failover_route(), "failover_enabled", false)
    :meck.expect(Blackgate.Db, :get_route, fn @route_id, _ -> {:ok, route} end)
    :meck.expect(Blackgate, :switch_route_source, fn _, _ -> :ok end)

    conn =
      auth_conn()
      |> post("/api/routes/#{@route_id}/switch-source", %{target: "secondary"})

    assert response(conn, 400)
    assert json_response(conn, 400)["error"] != nil
    assert :meck.num_calls(Blackgate, :switch_route_source, :_) == 0
  end
end
