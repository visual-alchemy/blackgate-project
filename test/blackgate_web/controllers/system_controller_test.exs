defmodule BlackgateWeb.SystemControllerTest do
  use BlackgateWeb.ConnCase

  alias Blackgate.Db
  alias BlackgateWeb.SystemController

  setup do
    route_id = UUID.uuid4()
    assert {:ok, _route} = Db.create_route(%{"name" => "Pipeline name test"}, route_id)

    on_exit(fn ->
      :khepri.delete_many("routes/#{route_id}/destinations/*")
      :khepri.delete(["routes", route_id])
    end)

    %{route_id: route_id}
  end

  test "add_route_names/1 resolves a route id to the route's name", %{route_id: route_id} do
    assert [pipeline] = SystemController.add_route_names([%{pid: 1, route_id: route_id}])
    assert pipeline.route_name == "Pipeline name test"
  end

  test "a pipeline from a route that no longer exists keeps no name", %{route_id: _route_id} do
    assert [pipeline] = SystemController.add_route_names([%{pid: 1, route_id: "deleted-route"}])
    assert pipeline.route_name == nil
  end

  test "add_route_names/1 passes anything that is not a list through untouched" do
    assert SystemController.add_route_names(%{error: "nope"}) == %{error: "nope"}
  end

  test "the detailed pipeline endpoint answers with a list of pipelines", %{conn: conn} do
    conn = get(conn, ~p"/api/system/pipelines/detailed")

    assert is_list(json_response(conn, 200))
  end

  test "the pipeline endpoint answers with a list too", %{conn: conn} do
    conn = get(conn, ~p"/api/system/pipelines")

    assert is_list(json_response(conn, 200))
  end

  test "the kill endpoint refuses a pid that is not an engine", %{conn: conn} do
    # The case that matters is the node's own pid: this button must not be able to stop the gateway, and the
    # node is still answering when the assertion below runs.
    conn = post(conn, "/api/system/pipelines/#{System.pid()}/kill")

    assert json_response(conn, 422)["error"] =~ "not a blackgate-engine process"
  end

  test "the kill endpoint refuses a pid that is not even a number", %{conn: conn} do
    conn = post(conn, "/api/system/pipelines/not-a-pid/kill")

    assert json_response(conn, 400)["error"] =~ "Invalid PID format"
  end
end
