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
  end
end
