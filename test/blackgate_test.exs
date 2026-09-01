defmodule BlackgateTest do
  use ExUnit.Case, async: false

  describe "start_route/1" do
    test "returns {:ok, pid} when route process is already running" do
      id = "test_route_already_started"
      :ok = :syn.register(:routes, id, self(), nil)

      try do
        assert {:ok, pid} = Blackgate.start_route(id)
        assert is_pid(pid)
        assert Process.alive?(pid)
      after
        :syn.unregister(:routes, id)
      end
    end

    test "detects route supervisors whose transient handler has exited normally" do
      id = "test_empty_route_supervisor"
      {:ok, empty_supervisor} = Supervisor.start_link([], strategy: :one_for_one)

      refute Blackgate.route_supervisor_has_handler?(empty_supervisor, id)
      Supervisor.stop(empty_supervisor)

      child = %{
        id: {:route_handler, id},
        start: {Agent, :start_link, [fn -> :ok end]},
        type: :worker
      }

      {:ok, populated_supervisor} = Supervisor.start_link([child], strategy: :one_for_one)
      assert Blackgate.route_supervisor_has_handler?(populated_supervisor, id)
      Supervisor.stop(populated_supervisor)
    end
  end

  test "Phoenix logs filter authentication parameters" do
    assert Phoenix.Logger.filter_values(%{"token" => "sensitive", "vsn" => "2.0.0"}) == %{
             "token" => "[FILTERED]",
             "vsn" => "2.0.0"
           }
  end
end
