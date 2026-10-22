defmodule Blackgate.RouteHandlerSdiSwitchTest do
  use ExUnit.Case, async: true

  alias Blackgate.RouteHandler

  # An SDI route may only switch sources inside the running pipeline when the guarded seamless
  # machinery can survive it. Without it, flipping the input-selector under a live decklink branch
  # feeds a foreign timeline into the decoder - measured as macroblocks in one direction and a
  # starved demuxer (black) in the other. These tests pin the gate that keeps SDI routes on
  # restart-based switching.

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

  describe "route_has_sdi_destination?/1" do
    test "true when any destination is SDI" do
      assert RouteHandler.route_has_sdi_destination?(%{"destinations" => [%{"schema" => "SDI"}]})
    end

    test "true when SDI sits beside other destinations" do
      route = %{"destinations" => [%{"schema" => "SRT"}, %{"schema" => "SDI"}]}
      assert RouteHandler.route_has_sdi_destination?(route)
    end

    test "false for non-SDI destinations and for a missing or unusable list" do
      refute RouteHandler.route_has_sdi_destination?(%{"destinations" => [%{"schema" => "SRT"}]})
      refute RouteHandler.route_has_sdi_destination?(%{"destinations" => []})
      refute RouteHandler.route_has_sdi_destination?(%{})
      refute RouteHandler.route_has_sdi_destination?(%{"destinations" => "SDI"})
      refute RouteHandler.route_has_sdi_destination?(nil)
      refute RouteHandler.route_has_sdi_destination?("not a route")
    end

    test "ignores a malformed destination entry instead of crashing" do
      refute RouteHandler.route_has_sdi_destination?(%{"destinations" => [nil, "SDI", 3]})
    end
  end

  describe "in_process_switch_allowed?/1" do
    test "allowed for a dual-ingest SRT route without an SDI destination" do
      assert RouteHandler.in_process_switch_allowed?(dual_srt_route([%{"schema" => "SRT"}]))
      assert RouteHandler.in_process_switch_allowed?(dual_srt_route([%{"schema" => "UDP"}]))
    end

    test "refused for the same route once a destination is SDI" do
      refute RouteHandler.in_process_switch_allowed?(dual_srt_route([%{"schema" => "SDI"}]))

      refute RouteHandler.in_process_switch_allowed?(
               dual_srt_route([
                 %{"schema" => "SRT"},
                 %{"schema" => "SDI"}
               ])
             )
    end

    test "refused without failover, a secondary source, or an SRT primary" do
      sdi = [%{"schema" => "SRT"}]

      refute RouteHandler.in_process_switch_allowed?(%{
               "schema" => "SRT",
               "failover_enabled" => false,
               "secondary_source" => %{"schema" => "SRT"},
               "destinations" => sdi
             })

      refute RouteHandler.in_process_switch_allowed?(%{
               "schema" => "SRT",
               "failover_enabled" => true,
               "destinations" => sdi
             })

      refute RouteHandler.in_process_switch_allowed?(%{
               "schema" => "SRT",
               "failover_enabled" => true,
               "secondary_source" => %{},
               "destinations" => sdi
             })

      refute RouteHandler.in_process_switch_allowed?(%{
               "schema" => "RTMP",
               "failover_enabled" => true,
               "secondary_source" => %{"schema" => "SRT"},
               "destinations" => sdi
             })
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
end
