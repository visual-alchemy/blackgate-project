defmodule BlackgateWeb.DestinationRestartRefusalTest do
  @moduledoc """
  A destination save on a RUNNING route restarts that route, and the restart can be REFUSED: the engine that
  would take the route's listening port, or its SDI connector, is someone else's. The controller used to answer
  `restarted: was_running` either way, so the operator was told the change was live while the route stayed down on
  its previous destination. This pins the honest answer.

  Who is running is judged from live engine processes, and a test may not spawn one, so the route ids come from a
  seam in `Blackgate.engine_process_route_ids/0` (`:persistent_term`, only read when set). The refusal happens
  BEFORE the route is stopped, which is why these cases need no engine: a restart that is allowed would go on to
  start a real one, and that path is already pinned by `destination_controller_test.exs` (a stopped route reports
  no restart) plus the live gateway.
  """
  use BlackgateWeb.ConnCase

  alias Blackgate.Db

  # Both routes LISTEN on the same local port: that is the exclusive resource being fought over. The listening port
  # is a ROUTE-level field (`SdiClaims.listening_ports_of/1` reads the route's own schema options).
  @port 17_192

  defp route_attrs(name) do
    %{
      "name" => name,
      "schema" => "SRT",
      "schema_options" => %{"mode" => "listener", "localport" => @port}
    }
  end

  # UDP on purpose: the destination must not be the thing claiming the port, so the refusal can only come from the
  # route-level listener.
  @destination %{
    "name" => "UDP out",
    "schema" => "UDP",
    "schema_options" => %{"address" => "127.0.0.1", "port" => 9101}
  }

  # `Db.get_all_destinations/1` answers `{:ok, %{path => destination}}`, so unwrap it rather than pattern-matching
  # a list.
  defp only_destination_id(route_id) do
    {:ok, destinations} = Db.get_all_destinations(route_id)
    [{_path, destination}] = Enum.to_list(destinations)
    destination["id"]
  end

  setup %{conn: conn} do
    holder_id = UUID.uuid4()
    subject_id = UUID.uuid4()

    assert {:ok, _holder} = Db.create_route(route_attrs("Holder"), holder_id)
    assert {:ok, _subject} = Db.create_route(route_attrs("Subject"), subject_id)

    assert {:ok, _dest} = Db.create_destination(holder_id, @destination)
    assert {:ok, _dest} = Db.create_destination(subject_id, @destination)

    # The subject must look RUNNING to the controller. `Blackgate.get_route/1` reads the registry, so register a
    # plain process under the same name `RoutesSupervisor` uses; nothing in this path calls `:sys.get_state/1` on
    # it, so an Agent stands in for the real supervisor tree.
    {:ok, subject_tree} =
      Agent.start_link(fn -> :ok end, name: {:via, :syn, {:routes, subject_id}})

    # The holder is "running": its route id is in the listing seam, so the engine list answers with it.
    :persistent_term.put({Blackgate, :running_route_ids}, [holder_id])

    on_exit(fn ->
      :persistent_term.erase({Blackgate, :running_route_ids})
      if Process.alive?(subject_tree), do: Agent.stop(subject_tree)
      Db.delete_route(holder_id)
      Db.delete_route(subject_id)
    end)

    %{conn: conn, route_id: subject_id, holder: holder_id}
  end

  test "editing a destination on a running route reports the refusal instead of claiming a restart",
       %{
         conn: conn,
         route_id: route_id
       } do
    dest_id = only_destination_id(route_id)

    conn =
      put(conn, ~p"/api/routes/#{route_id}/destinations/#{dest_id}",
        destination: %{"name" => "SRT out renamed"}
      )

    assert %{"restarted" => false, "restart_error" => error} = json_response(conn, 200)["data"]
    assert error =~ "port #{@port} is in use by Holder"
  end

  test "deleting a destination reports the refusal the same way", %{
    conn: conn,
    route_id: route_id
  } do
    dest_id = only_destination_id(route_id)

    conn = delete(conn, ~p"/api/routes/#{route_id}/destinations/#{dest_id}")

    assert %{"deleted" => true, "restarted" => false, "restart_error" => error} =
             json_response(conn, 200)["data"]

    assert error =~ "port #{@port} is in use by Holder"
  end
end
