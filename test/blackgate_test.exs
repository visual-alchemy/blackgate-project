defmodule BlackgateTest do
  use ExUnit.Case, async: false

  describe "start_route/1" do
    test "rejects start and restart when central admission denies operation" do
      :meck.new(Blackgate.License, [:passthrough])
      :meck.expect(Blackgate.License, :can_start_route?, fn _ -> {:error, "License expired"} end)
      on_exit(fn -> :meck.unload() end)
      assert {:error, "License expired"} = Blackgate.start_route("not-running")
      assert {:error, "License expired"} = Blackgate.restart_route("not-running")
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
