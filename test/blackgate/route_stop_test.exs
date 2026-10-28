defmodule Blackgate.RouteStopTest do
  use ExUnit.Case, async: false

  # Measured on the box: every operator Stop and every destination change (11 of them in one day) logged
  #   Ranch listener BlackgateWeb.Endpoint.HTTP ... had its request process exit with reason
  #   {{{:noproc, {GenServer, :stop, [pid, :normal, :infinity]}}, {BlackgateWeb.Endpoint, :call, [...]}}
  # while the route itself stopped or restarted correctly. `Supervisor.stop/2` EXITS on a tree that is already
  # down; it does not return an error, so nothing in the stop path could have caught it as a value.
  describe "stop_route_tree/1" do
    test "reports :ok for a tree that is already down instead of exiting the caller" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert Blackgate.stop_route_tree(pid) == :ok
    end

    test "stops a live tree and reports :ok" do
      {:ok, sup} =
        Supervisor.start_link(
          [%{id: :idle, start: {Agent, :start_link, [fn -> :ok end]}}],
          strategy: :one_for_one
        )

      assert Blackgate.stop_route_tree(sup) == :ok
      refute Process.alive?(sup)
    end

    test "a tree that dies between the liveness check and the stop is still reported as :ok" do
      # Two stops in a row is exactly the sequence the stop path performs (stop, then judge the tree,
      # then clear what is left) - the second one must not take the caller down.
      {:ok, sup} =
        Supervisor.start_link(
          [%{id: :idle, start: {Agent, :start_link, [fn -> :ok end]}}],
          strategy: :one_for_one
        )

      assert Blackgate.stop_route_tree(sup) == :ok
      assert Blackgate.stop_route_tree(sup) == :ok
    end
  end

  describe "stop_route/1" do
    # The route is started the way the app starts it - through the {:via, :syn, {:routes, id}} name - so the
    # registration the stop path looks up is the real one, not a stand-in.
    test "a registered route whose handler is gone still stops without exiting the caller" do
      for _ <- 1..10 do
        id = "stop-test-#{System.unique_integer([:positive])}"

        {:ok, sup} =
          Supervisor.start_link(
            [%{id: {:route_handler, id}, start: {Agent, :start_link, [fn -> :ok end]}}],
            strategy: :one_for_one,
            name: {:via, :syn, {:routes, id}}
          )

        assert {:ok, ^sup} = Blackgate.get_route(id)

        assert Blackgate.stop_route(id) == :ok
        refute Process.alive?(sup)
      end
    end

    test "a second stop on the same id is answered, not crashed" do
      id = "stop-test-#{System.unique_integer([:positive])}"

      {:ok, sup} =
        Supervisor.start_link(
          [%{id: {:route_handler, id}, start: {Agent, :start_link, [fn -> :ok end]}}],
          strategy: :one_for_one,
          name: {:via, :syn, {:routes, id}}
        )

      assert Blackgate.stop_route(id) == :ok
      refute Process.alive?(sup)

      # Second stop: nothing is registered for this id any more, so the answer is the same not_found the
      # elsewhere-missing route gets. What matters is that it is an ANSWER - this is the shape that used to
      # take the request process down with a {:noproc, {GenServer, :stop, ...}} exit.
      assert Blackgate.stop_route(id) == {:error, :not_found}
    end
  end
end
