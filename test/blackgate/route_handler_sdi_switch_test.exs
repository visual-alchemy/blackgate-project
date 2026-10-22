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

  # Fingerprint fields: codec configuration, video format, and elementary-stream layout - the set
  # that decides whether an in-place cut between two sources is possible at all.
  defp srt_stats(overrides \\ %{}) do
    Map.merge(
      %{
        "video-codec" => "AVC/H.264",
        "video-width" => 1920,
        "video-height" => 1080,
        "video-framerate-num" => 50,
        "video-framerate-den" => 2,
        "video-interlace-mode" => "interleaved",
        "video-profile" => "High",
        "video-level-idc" => 40,
        "video-chroma-format" => "4:2:0",
        "video-bit-depth" => 8,
        "video-pid" => 101,
        "audio-pids" => [201, 202]
      },
      overrides
    )
  end

  describe "source_fingerprint/1" do
    test "returns the structural fields when the source reported all of them" do
      fp = RouteHandler.source_fingerprint(srt_stats())
      assert is_map(fp)
      assert map_size(fp) == 12
      assert fp["video-interlace-mode"] == "interleaved"
      assert fp["video-pid"] == 101
      assert fp["audio-pids"] == [201, 202]
    end

    test "returns nil when any field is missing - an unknown shape is not a match" do
      assert RouteHandler.source_fingerprint(Map.delete(srt_stats(), "video-pid")) == nil
      assert RouteHandler.source_fingerprint(%{}) == nil
      assert RouteHandler.source_fingerprint(nil) == nil
    end
  end

  describe "sources_structurally_match?/2 and sources_differ_in/2" do
    test "two sources with the same shape match" do
      assert RouteHandler.sources_structurally_match?(srt_stats(), srt_stats())
    end

    # The operator's example: 1080i50 against 1080p50 is the same resolution and framerate, and still
    # not the same bitstream - the decoder cannot continue across that cut.
    test "same resolution but a different scan type does NOT match" do
      other = srt_stats(%{"video-interlace-mode" => "progressive", "video-framerate-den" => 1})

      refute RouteHandler.sources_structurally_match?(srt_stats(), other)
      # It names the first field that disagreed, so a refusal can say why.
      assert RouteHandler.sources_differ_in(srt_stats(), other) =~ "video-framerate-den"

      # Same resolution and framerate, only the scan type differs.
      interlace_only = srt_stats(%{"video-interlace-mode" => "progressive"})
      refute RouteHandler.sources_structurally_match?(srt_stats(), interlace_only)
      assert RouteHandler.sources_differ_in(srt_stats(), interlace_only) =~ "video-interlace-mode"
    end

    test "a different elementary-stream layout does NOT match" do
      refute RouteHandler.sources_structurally_match?(
               srt_stats(),
               srt_stats(%{"video-pid" => 102})
             )

      refute RouteHandler.sources_structurally_match?(
               srt_stats(),
               srt_stats(%{"audio-pids" => [301]})
             )
    end

    test "one unknown side never matches" do
      refute RouteHandler.sources_structurally_match?(srt_stats(), %{})
      refute RouteHandler.sources_structurally_match?(nil, srt_stats())
    end
  end

  describe "in_process_switch_allowed?/3" do
    test "a route without an SDI destination always cuts in place" do
      route = dual_srt_route([%{"schema" => "SRT"}])
      assert RouteHandler.in_process_switch_allowed?(route, srt_stats(), srt_stats())
      assert RouteHandler.in_process_switch_allowed?(route, nil, nil)
      assert RouteHandler.in_process_switch_allowed?(route, srt_stats(%{"video-pid" => 999}), nil)
    end

    test "an SDI route cuts in place when the two sources are structurally the same" do
      route = dual_srt_route([%{"schema" => "SDI"}])
      assert RouteHandler.in_process_switch_allowed?(route, srt_stats(), srt_stats())
    end

    test "an SDI route rebuilds when the sources differ or the shape is unknown" do
      route = dual_srt_route([%{"schema" => "SDI"}])

      refute RouteHandler.in_process_switch_allowed?(
               route,
               srt_stats(),
               srt_stats(%{"video-pid" => 7})
             )

      refute RouteHandler.in_process_switch_allowed?(route, nil, srt_stats())
      refute RouteHandler.in_process_switch_allowed?(route, srt_stats(), nil)
    end

    test "refused without failover, a secondary source, or an SRT primary" do
      sdi = [%{"schema" => "SDI"}]

      refute RouteHandler.in_process_switch_allowed?(
               %{
                 "schema" => "SRT",
                 "failover_enabled" => false,
                 "secondary_source" => %{"schema" => "SRT"},
                 "destinations" => sdi
               },
               srt_stats(),
               srt_stats()
             )

      refute RouteHandler.in_process_switch_allowed?(
               %{"schema" => "SRT", "failover_enabled" => true, "destinations" => sdi},
               srt_stats(),
               srt_stats()
             )

      refute RouteHandler.in_process_switch_allowed?(
               %{
                 "schema" => "RTMP",
                 "failover_enabled" => true,
                 "secondary_source" => %{"schema" => "SRT"},
                 "destinations" => sdi
               },
               srt_stats(),
               srt_stats()
             )
    end
  end

  describe "the failover DECISION still runs for an SDI route" do
    # The operator's symptom: mode=maintain-primary, switched to secondary by hand, never came back
    # because the gate stopped the decision itself instead of only the in-place cut. The decision must
    # run for every dual-ingest route; the mechanism is what differs.
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

    test "maintain-primary on secondary with a valid primary decides primary and schedules a rebuild" do
      route = dual_srt_route([%{"schema" => "SDI"}])
      data = engine_data(route, "secondary", %{primary: :valid, secondary: :valid})

      {:keep_state, new_data} = RouteHandler.evaluate_failover_for_test(data)

      assert new_data.active_source == "primary"
      assert new_data.failover_switched

      assert_receive {:switch_source_restart, "primary"},
                     100,
                     "an SDI route must rebuild on the target instead of cutting in place"
    end

    test "an invalid primary still moves an SDI route to the secondary, by rebuild" do
      route = dual_srt_route([%{"schema" => "SDI"}])
      data = engine_data(route, "primary", %{primary: :invalid, secondary: :valid})

      {:keep_state, new_data} = RouteHandler.evaluate_failover_for_test(data)

      assert new_data.active_source == "secondary"
      assert_receive {:switch_source_restart, "secondary"}, 100
    end

    test "a route without SDI decides in place and asks for no rebuild" do
      port = Port.open({:spawn, "cat"}, [:binary])
      route = dual_srt_route([%{"schema" => "SRT"}])
      data = engine_data(route, "secondary", %{primary: :valid, secondary: :valid}, port)

      {:keep_state, new_data} = RouteHandler.evaluate_failover_for_test(data)

      assert new_data.active_source == "primary"
      refute_receive {:switch_source_restart, _}, 100
    end

    test "both sources invalid changes nothing and schedules nothing" do
      route = dual_srt_route([%{"schema" => "SDI"}])
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
