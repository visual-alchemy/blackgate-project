defmodule Blackgate.RouteHandlerSwitchTest do
  use ExUnit.Case, async: true

  alias Blackgate.RouteHandler

  # A source switch inside the RUNNING pipeline is safe because of the mechanism, not the route's
  # outputs: the engine holds the cut until the target carries a keyframe and normalizes its
  # timeline first. What still decides is whether the route can receive a second source at all, and
  # whether its engine port is live - without a port there is nothing to switch in place.

  defp dual_srt_route(destinations) do
    %{
      "name" => "gate test",
      "schema" => "SRT",
      "failover_enabled" => true,
      "failover_mode" => "maintain-primary",
      "auto_join" => true,
      "secondary_source" => %{"schema" => "SRT", "schema_options" => %{"mode" => "caller"}},
      "destinations" => destinations
    }
  end

  describe "in_process_switch_allowed?/3" do
    test "an eligible dual-ingest route cuts in place whatever its stats say" do
      route = dual_srt_route([%{"schema" => "SRT"}])
      assert RouteHandler.in_process_switch_allowed?(route, %{}, %{})
      assert RouteHandler.in_process_switch_allowed?(route, nil, nil)
    end

    test "refused without failover, a secondary source, or an SRT primary" do
      destinations = [%{"schema" => "SRT"}]

      refute RouteHandler.in_process_switch_allowed?(
               %{
                 "schema" => "SRT",
                 "failover_enabled" => false,
                 "secondary_source" => %{"schema" => "SRT"},
                 "destinations" => destinations
               },
               %{},
               %{}
             )

      refute RouteHandler.in_process_switch_allowed?(
               %{"schema" => "SRT", "failover_enabled" => true, "destinations" => destinations},
               %{},
               %{}
             )

      refute RouteHandler.in_process_switch_allowed?(
               %{
                 "schema" => "RTMP",
                 "failover_enabled" => true,
                 "secondary_source" => %{"schema" => "SRT"},
                 "destinations" => destinations
               },
               %{},
               %{}
             )
    end
  end

  describe "the failover DECISION runs for every dual-ingest route" do
    # The operator's symptom: mode=maintain-primary, switched to secondary by hand, never came back
    # because a gate stopped the decision itself instead of only the mechanism.
    defp engine_data(route, active, health, port \\ nil) do
      %{
        id: "decision-route",
        route: route,
        active_source: active,
        source_health: health,
        both_dead_reported: false,
        failover_switched: false,
        auto_join: true,
        port: port,
        ffmpeg_port: nil
      }
    end

    test "maintain-primary on secondary with a valid primary decides primary" do
      route = dual_srt_route([%{"schema" => "SRT"}])
      data = engine_data(route, "secondary", %{primary: :valid, secondary: :valid})

      {:keep_state, new_data} = RouteHandler.evaluate_failover_for_test(data)

      assert new_data.active_source == "primary"
      assert new_data.failover_switched

      assert_receive {:switch_source_restart, "primary"}, 100,
                     "with no live port the route rebuilds on the target"
    end

    test "an invalid primary moves the route to the secondary, by rebuild when the port is gone" do
      route = dual_srt_route([%{"schema" => "SRT"}])
      data = engine_data(route, "primary", %{primary: :invalid, secondary: :valid})

      {:keep_state, new_data} = RouteHandler.evaluate_failover_for_test(data)

      assert new_data.active_source == "secondary"
      assert_receive {:switch_source_restart, "secondary"}, 100
    end

    test "a live port decides in place and asks for no rebuild" do
      port = Port.open({:spawn, "cat"}, [:binary])
      route = dual_srt_route([%{"schema" => "SRT"}])
      data = engine_data(route, "secondary", %{primary: :valid, secondary: :valid}, port)

      {:keep_state, new_data} = RouteHandler.evaluate_failover_for_test(data)

      assert new_data.active_source == "primary"
      refute_receive {:switch_source_restart, _}, 100
    end

    test "both sources invalid changes nothing and schedules nothing" do
      route = dual_srt_route([%{"schema" => "SRT"}])
      data = engine_data(route, "primary", %{primary: :invalid, secondary: :invalid})

      {:keep_state, new_data} = RouteHandler.evaluate_failover_for_test(data)

      assert new_data.active_source == "primary"
      refute_receive {:switch_source_restart, _}, 100
    end
  end

  describe "handle_event/4 with a port exit" do
    # The clause has to exist and be tolerant: without it every departing engine logged
    # "Undefined msg" and the fsm kept whatever state it had.
    test "a port that is no longer the live one is ignored" do
      data = %{port: nil, ffmpeg_port: nil, id: "route", route: %{}}

      assert :keep_state_and_data =
               RouteHandler.handle_event(
                 :info,
                 {:EXIT, Port.open({:spawn, "true"}, []), :normal},
                 :started,
                 data
               )
    end
  end

  describe "engine exit while reconnecting" do
    # Every engine exit used to fall through to the catch-all, which pretty-printed the WHOLE route state: measured
    # 180 of those plus 110 `Error closing port` lines in three hours, which is what buried the real signal.
    test "an engine exit in :reconnecting is handled, not dumped" do
      data = %{id: "r1", port: make_ref(), state: :reconnecting}

      # The port is not a real port here, so the guard `is_port/1` sends it to the catch-all - the point of this
      # test is that the clause exists for ports and that the catch-all no longer prints the data map.
      assert RouteHandler.handle_event(:info, {:EXIT, self(), :normal}, :reconnecting, data) ==
               :keep_state_and_data
    end
  end
end
