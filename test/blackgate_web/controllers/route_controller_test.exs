defmodule BlackgateWeb.RouteControllerTest do
  use BlackgateWeb.ConnCase

  import Blackgate.ApiFixtures

  alias Blackgate.Api.Route

  @create_attrs %{
    alias: "some alias",
    enabled: true,
    name: "some name",
    status: "some status",
    started_at: ~U[2025-02-18 14:51:00Z],
    source: %{},
    destinations: %{},
    stopped_at: ~U[2025-02-18 14:51:00Z]
  }
  @update_attrs %{
    alias: "some updated alias",
    enabled: false,
    name: "some updated name",
    status: "some updated status",
    started_at: ~U[2025-02-19 14:51:00Z],
    source: %{},
    destinations: %{},
    stopped_at: ~U[2025-02-19 14:51:00Z]
  }
  @invalid_attrs %{
    alias: nil,
    enabled: nil,
    name: nil,
    status: nil,
    started_at: nil,
    source: nil,
    destinations: nil,
    stopped_at: nil
  }

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "index" do
    test "lists all routes", %{conn: conn} do
      conn = get(conn, ~p"/api/routes")
      assert json_response(conn, 200)["data"] == []
    end
  end

  describe "create route" do
    test "renders route when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/api/routes", route: @create_attrs)
      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/routes/#{id}")

      assert %{
               "id" => ^id,
               "alias" => "some alias",
               "destinations" => %{},
               "enabled" => true,
               "name" => "some name",
               "source" => %{},
               "started_at" => "2025-02-18T14:51:00Z",
               "status" => "some status",
               "stopped_at" => "2025-02-18T14:51:00Z"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/routes", route: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "update route" do
    setup [:create_route]

    test "renders route when data is valid", %{conn: conn, route: %Route{id: id} = route} do
      conn = put(conn, ~p"/api/routes/#{route}", route: @update_attrs)
      assert %{"id" => ^id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/routes/#{id}")

      assert %{
               "id" => ^id,
               "alias" => "some updated alias",
               "destinations" => %{},
               "enabled" => false,
               "name" => "some updated name",
               "source" => %{},
               "started_at" => "2025-02-19T14:51:00Z",
               "status" => "some updated status",
               "stopped_at" => "2025-02-19T14:51:00Z"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn, route: route} do
      conn = put(conn, ~p"/api/routes/#{route}", route: @invalid_attrs)
      assert json_response(conn, 422)["errors"] != %{}
    end
  end

  describe "delete route" do
    setup [:create_route]

    test "deletes chosen route", %{conn: conn, route: route} do
      conn = delete(conn, ~p"/api/routes/#{route}")
      assert response(conn, 204)

      assert_error_sent 404, fn ->
        get(conn, ~p"/api/routes/#{route}")
      end
    end
  end

  defp create_route(_) do
    route = route_fixture()
    %{route: route}
  end
end

defmodule BlackgateWeb.RouteControllerSwitchSourceTest do
  @moduledoc """
  Manual source-switch endpoint tests.

  The legacy CRUD tests above rely on the stale Ecto sandbox scaffold which is
  disabled in this Khepri-based project. These switch-source tests are fully
  Meck-isolated and dispatch through the real Phoenix endpoint via Plug.Conn.

  Blackgate.Cache is only started on distributed nodes (see
  Blackgate.Application), so the :auth pipeline's Cachex lookup is mecked here
  with :passthrough to admit the bearer token without a running cache.
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
