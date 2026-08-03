defmodule Blackgate.RouteHandlerTest do
  use ExUnit.Case
  alias Blackgate.RouteHandler

  setup do
    # Clear registry stats for test routes if they exist
    try do
      :ets.delete(:route_stats, "test_route")
      :ets.delete(:route_stats, "test_route_sdi")
    rescue
      _ -> :ok
    end

    # Mock Db, Blackgate.EventLog, and Blackgate
    :meck.new(Blackgate.Db, [:non_strict])

    :meck.expect(Blackgate.Db, :get_route, fn
      "test_route", _assoc ->
        {:ok,
         %{
           "id" => "test_route",
           "schema" => "SRT",
           "schema_options" => %{
             "localaddress" => "127.0.0.1",
             "localport" => 4201,
             "mode" => "listener"
           },
           "destinations" => [
             %{
               "schema" => "SRT",
               "schema_options" => %{
                 "localaddress" => "127.0.0.1",
                 "localport" => 4202,
                 "mode" => "listener"
               }
             }
           ]
         }}

      "test_route_sdi", _assoc ->
        {:ok,
         %{
           "id" => "test_route_sdi",
           "schema" => "SRT",
           "schema_options" => %{
             "localaddress" => "127.0.0.1",
             "localport" => 4201,
             "mode" => "listener"
           },
           "destinations" => [
             %{
               "schema" => "SDI",
               "device-number" => 2,
               "video-mode" => "1080p25",
               "interlaced" => false
             }
           ]
         }}

      _id, _assoc ->
        {:ok, %{}}
    end)

    :meck.expect(Blackgate.Db, :update_route, fn _id, _params -> {:ok, %{}} end)

    :meck.new(Blackgate, [:non_strict])
    :meck.expect(Blackgate, :set_route_status, fn _id, _status -> {:ok, %{}} end)
    :meck.expect(Blackgate, :set_route_error, fn _id, _err -> {:ok, %{}} end)

    :meck.new(Blackgate.EventLog, [:non_strict])
    :meck.expect(Blackgate.EventLog, :log, fn _level, _event_type, _msg, _meta -> :ok end)

    on_exit(fn ->
      :meck.unload()
    end)

    :ok
  end

  test "source_from_record with valid SRT schema" do
    record = %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 4201,
        "mode" => "listener",
        "latency" => 200,
        "auto-reconnect" => true,
        "keep-listening" => true
      }
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["type"] == "srtsrc"
    assert source["uri"] =~ "srt://127.0.0.1:4201"
    assert source["uri"] =~ "mode=listener"
    assert source["latency"] == 200
    assert source["auto-reconnect"] == true
    assert source["keep-listening"] == true
  end

  test "source_from_record with valid SRT schema and advanced options" do
    record = %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 4201,
        "mode" => "listener",
        "latency" => 200,
        "auto-reconnect" => true,
        "keep-listening" => true,
        "rcvbuf" => 50_000_000,
        "lossmaxttl" => 10,
        "oheadbw" => 50
      }
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["type"] == "srtsrc"
    assert source["uri"] =~ "srt://127.0.0.1:4201"
    assert source["uri"] =~ "mode=listener"
    assert source["latency"] == 200
    assert source["auto-reconnect"] == true
    assert source["keep-listening"] == true
    assert source["rcvbuf"] == 50_000_000
    assert source["lossmaxttl"] == 10
    assert source["oheadbw"] == 50
  end

  test "sink_from_record with valid SRT schema and advanced options" do
    record = %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 4202,
        "mode" => "caller",
        "latency" => 250,
        "sndbuf" => 12_000_000,
        "rcvbuf" => 8_000_000,
        "oheadbw" => 30,
        "maxbw" => 50_000_000
      }
    }

    assert {:ok, sink} = RouteHandler.sink_from_record(record)
    assert sink["type"] == "srtsink"
    assert sink["uri"] =~ "srt://127.0.0.1:4202"
    assert sink["uri"] =~ "mode=caller"
    assert sink["latency"] == 250
    assert sink["sndbuf"] == 12_000_000
    assert sink["rcvbuf"] == 8_000_000
    assert sink["oheadbw"] == 30
    assert sink["maxbw"] == 50_000_000
  end

  test "source_from_record with SRT schema and passphrase" do
    record = %{
      "schema" => "SRT",
      "schema_options" => %{
        "localaddress" => "127.0.0.1",
        "localport" => 4201,
        "mode" => "listener",
        "passphrase" => "secret",
        "pbkeylen" => 16
      }
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["type"] == "srtsrc"
    assert source["uri"] =~ "srt://127.0.0.1:4201"
    assert source["uri"] =~ "mode=listener"
    assert source["uri"] =~ "passphrase=secret"
    assert source["uri"] =~ "pbkeylen=16"
  end

  test "source_from_record with valid UDP schema" do
    record = %{
      "schema" => "UDP",
      "schema_options" => %{
        "address" => "127.0.0.1",
        "port" => 4201,
        "buffer-size" => 65536,
        "mtu" => 1500
      }
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["type"] == "udpsrc"
    assert source["address"] == "127.0.0.1"
    assert source["port"] == 4201
    assert source["buffer-size"] == 65536
    assert source["mtu"] == 1500
  end

  test "source_from_record with UDP schema and minimal options" do
    record = %{
      "schema" => "UDP",
      "schema_options" => %{
        "address" => "127.0.0.1",
        "port" => 4201
      }
    }

    assert {:ok, source} = RouteHandler.source_from_record(record)
    assert source["type"] == "udpsrc"
    assert source["address"] == "127.0.0.1"
    assert source["port"] == 4201
  end

  test "source_from_record with invalid schema" do
    record = %{
      "schema" => "INVALID",
      "schema_options" => %{}
    }

    assert {:error, :invalid_source} = RouteHandler.source_from_record(record)
  end

  test "source_from_record with missing schema_options" do
    record = %{"schema" => "SRT"}
    assert {:error, :invalid_source} = RouteHandler.source_from_record(record)
  end

  test "route_data_to_params with valid route data" do
    route_id = "test_route"

    assert {:ok, params} = RouteHandler.route_data_to_params(route_id)
    assert is_map(params)
    assert Map.has_key?(params, "source")
    assert Map.has_key?(params, "sinks")
    assert is_list(params["sinks"])
  end

  test "route_data_to_params with multiple destinations" do
    # Setting up meck to return a route with multiple destinations
    :meck.expect(Blackgate.Db, :get_route, fn
      "test_route_multiple", _assoc ->
        {:ok,
         %{
           "schema" => "SRT",
           "schema_options" => %{
             "localaddress" => "127.0.0.1",
             "localport" => 4201,
             "mode" => "listener"
           },
           "destinations" => [
             %{
               "schema" => "SRT",
               "schema_options" => %{
                 "localaddress" => "127.0.0.1",
                 "localport" => 4202,
                 "mode" => "listener"
               }
             },
             %{
               "schema" => "UDP",
               "schema_options" => %{
                 "address" => "127.0.0.1",
                 "port" => 4203
               }
             }
           ]
         }}
    end)

    route_id = "test_route_multiple"

    assert {:ok, params} = RouteHandler.route_data_to_params(route_id)
    assert is_map(params)
    assert Map.has_key?(params, "source")
    assert Map.has_key?(params, "sinks")
    assert length(params["sinks"]) == 2
  end

  test "callback_mode returns handle_event_function" do
    assert RouteHandler.callback_mode() == [:handle_event_function]
  end

  test "init sets up initial state" do
    args = %{id: "test_route"}

    assert {:ok, :start, %{id: "test_route", port: nil}, {:next_event, :internal, :start}} =
             RouteHandler.init(args)
  end

  test "init with process flag" do
    args = %{id: "test_route"}
    # Verify trap_exit flag can be configured/retrieved
    old_flag = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, old_flag) end)

    assert {:ok, :start, %{id: "test_route", port: nil}, {:next_event, :internal, :start}} =
             RouteHandler.init(args)
  end

  test "terminate handles port cleanup" do
    state = :started
    data = %{port: nil, id: "test_route"}
    assert :ok = RouteHandler.terminate(:normal, state, data)
  end

  test "terminate with active port" do
    state = :started
    port = Port.open({:spawn, "echo test"}, [:binary])
    data = %{port: port, id: "test_route"}
    assert :ok = RouteHandler.terminate(:normal, state, data)
  end

  # =========================================================================
  # WATCHDOG TESTS
  # =========================================================================

  test "watchdog skips check during grace period" do
    now = System.monotonic_time(:millisecond)

    data = %{
      id: "test_route",
      route: %{
        "id" => "test_route",
        "destinations" => []
      },
      port: nil,
      ffmpeg_port: nil,
      reconnect_timer: nil,
      reconnect_started_at: nil,
      reconnect_count: 0,
      last_bytes_received: 0,
      last_bytes_changed_at: now,
      last_sdi_frames: %{},
      last_sdi_frames_changed_at: now,
      # 10 seconds ago (grace period is 30s)
      started_at: now - 10_000,
      consecutive_startup_crashes: 0
    }

    assert {:keep_state_and_data, _} =
             RouteHandler.handle_event({:timeout, :watchdog}, :check, :started, data)
  end

  test "watchdog keeps state when network data is flowing" do
    now = System.monotonic_time(:millisecond)

    data = %{
      id: "test_route",
      route: %{
        "id" => "test_route",
        "destinations" => []
      },
      port: nil,
      ffmpeg_port: nil,
      reconnect_timer: nil,
      reconnect_started_at: nil,
      reconnect_count: 0,
      last_bytes_received: 100,
      last_bytes_changed_at: now - 20_000,
      last_sdi_frames: %{},
      last_sdi_frames_changed_at: now - 20_000,
      # past grace period
      started_at: now - 40_000,
      consecutive_startup_crashes: 0
    }

    # Put new bytes in stats registry
    stats = %{"total-bytes-received" => 200}
    Blackgate.RouteStatsRegistry.put_stats("test_route", stats)

    assert {:keep_state, updated_data, _} =
             RouteHandler.handle_event({:timeout, :watchdog}, :check, :started, data)

    assert updated_data.last_bytes_received == 200
    assert updated_data.last_bytes_changed_at > now - 5000
  end

  test "watchdog restarts route when network data is stalled" do
    now = System.monotonic_time(:millisecond)

    data = %{
      id: "test_route",
      route: %{
        "id" => "test_route",
        "destinations" => []
      },
      port: nil,
      ffmpeg_port: nil,
      reconnect_timer: nil,
      reconnect_started_at: nil,
      reconnect_count: 0,
      last_bytes_received: 100,
      # stalled for 70 seconds (> 60s threshold)
      last_bytes_changed_at: now - 70_000,
      last_sdi_frames: %{},
      last_sdi_frames_changed_at: now - 70_000,
      started_at: now - 80_000,
      consecutive_startup_crashes: 0
    }

    # bytes have not changed
    stats = %{"total-bytes-received" => 100}
    Blackgate.RouteStatsRegistry.put_stats("test_route", stats)

    res = RouteHandler.handle_event({:timeout, :watchdog}, :check, :started, data)
    assert elem(res, 0) == :next_state
    assert elem(res, 1) == :reconnecting
  end

  test "watchdog keeps state when SDI output is flowing" do
    now = System.monotonic_time(:millisecond)

    data = %{
      id: "test_route_sdi",
      route: %{
        "id" => "test_route_sdi",
        "destinations" => [
          %{"schema" => "SDI", "device-number" => 2}
        ]
      },
      port: nil,
      ffmpeg_port: nil,
      reconnect_timer: nil,
      reconnect_started_at: nil,
      reconnect_count: 0,
      last_bytes_received: 100,
      last_bytes_changed_at: now,
      last_sdi_frames: %{2 => 500},
      last_sdi_frames_changed_at: now - 20_000,
      started_at: now - 40_000,
      consecutive_startup_crashes: 0
    }

    # Put new frames in stats registry
    stats = %{
      "total-bytes-received" => 100,
      "sdi_video_stats" => [
        %{"device_number" => 2, "video_frames" => 510}
      ]
    }

    Blackgate.RouteStatsRegistry.put_stats("test_route_sdi", stats)

    assert {:keep_state, updated_data, _} =
             RouteHandler.handle_event({:timeout, :watchdog}, :check, :started, data)

    assert updated_data.last_sdi_frames[2] == 510
    assert updated_data.last_sdi_frames_changed_at > now - 5000
  end

  test "watchdog restarts route when SDI playout is frozen" do
    now = System.monotonic_time(:millisecond)

    data = %{
      id: "test_route_sdi",
      route: %{
        "id" => "test_route_sdi",
        "destinations" => [
          %{"schema" => "SDI", "device-number" => 2}
        ]
      },
      port: nil,
      ffmpeg_port: nil,
      reconnect_timer: nil,
      reconnect_started_at: nil,
      reconnect_count: 0,
      last_bytes_received: 100,
      # network is fine
      last_bytes_changed_at: now,
      last_sdi_frames: %{2 => 500},
      # playout frozen for 70 seconds (> 60s threshold)
      last_sdi_frames_changed_at: now - 70_000,
      started_at: now - 80_000,
      consecutive_startup_crashes: 0
    }

    # SDI frames have not advanced (still 500)
    stats = %{
      "total-bytes-received" => 100,
      "sdi_video_stats" => [
        %{"device_number" => 2, "video_frames" => 500}
      ]
    }

    Blackgate.RouteStatsRegistry.put_stats("test_route_sdi", stats)

    res = RouteHandler.handle_event({:timeout, :watchdog}, :check, :started, data)
    assert elem(res, 0) == :next_state
    assert elem(res, 1) == :reconnecting
  end

  # =========================================================================
  # FAILOVER HELPER TESTS
  # =========================================================================

  describe "failover helpers" do
    test "failover_active? returns false when route has no failover_enabled key" do
      route = %{"schema" => "SRT", "secondary_source" => %{"schema" => "SRT"}}
      refute RouteHandler.failover_active?(route)
    end

    test "failover_active? returns false when failover_enabled is false" do
      route = %{
        "schema" => "SRT",
        "failover_enabled" => false,
        "secondary_source" => %{"schema" => "SRT"}
      }

      refute RouteHandler.failover_active?(route)
    end

    test "failover_active? returns false when schema is UDP (not SRT)" do
      route = %{
        "schema" => "UDP",
        "failover_enabled" => true,
        "secondary_source" => %{"schema" => "SRT"}
      }

      refute RouteHandler.failover_active?(route)
    end

    test "failover_active? returns false when secondary_source is nil" do
      route = %{
        "schema" => "SRT",
        "failover_enabled" => true,
        "secondary_source" => nil
      }

      refute RouteHandler.failover_active?(route)
    end

    test "failover_active? returns true when SRT + enabled + secondary configured" do
      route = %{
        "schema" => "SRT",
        "failover_enabled" => true,
        "secondary_source" => %{"schema" => "SRT", "schema_options" => %{}}
      }

      assert RouteHandler.failover_active?(route)
    end

    test "active_route_for_pipeline returns original route when active is primary" do
      route = %{
        "schema" => "SRT",
        "schema_options" => %{"localaddress" => "primary-host"},
        "secondary_source" => %{
          "schema" => "SRT",
          "schema_options" => %{"localaddress" => "secondary-host"}
        }
      }

      data = %{active_source: "primary", route: route}

      result = RouteHandler.active_route_for_pipeline(data)
      assert result["schema_options"]["localaddress"] == "primary-host"
      assert result == route
    end

    test "active_route_for_pipeline overlays secondary schema + schema_options when active is secondary" do
      route = %{
        "schema" => "SRT",
        "schema_options" => %{"localaddress" => "primary-host", "localport" => 4201},
        "secondary_source" => %{
          "schema" => "SRT",
          "schema_options" => %{"localaddress" => "secondary-host", "localport" => 9999}
        }
      }

      data = %{active_source: "secondary", route: route}

      result = RouteHandler.active_route_for_pipeline(data)
      assert result["schema"] == "SRT"
      assert result["schema_options"]["localaddress"] == "secondary-host"
      assert result["schema_options"]["localport"] == 9999
    end

    test "choose_next_source with maintain-stability toggles primary to secondary and back" do
      route = %{}

      assert RouteHandler.choose_next_source("primary", false, "maintain-stability", route) ==
               "secondary"

      assert RouteHandler.choose_next_source("secondary", false, "maintain-stability", route) ==
               "primary"
    end

    test "choose_next_source with manual-switchback switches once then stays" do
      route = %{}

      assert RouteHandler.choose_next_source("primary", false, "manual-switchback", route) ==
               "secondary"

      assert RouteHandler.choose_next_source("secondary", true, "manual-switchback", route) ==
               "secondary"
    end

    test "choose_next_source with manual never changes source" do
      route = %{}

      assert RouteHandler.choose_next_source("primary", false, "manual", route) == "primary"
      assert RouteHandler.choose_next_source("secondary", true, "manual", route) == "secondary"
    end

    test "choose_next_source with maintain-primary always returns primary" do
      route = %{}

      assert RouteHandler.choose_next_source("primary", false, "maintain-primary", route) ==
               "primary"

      assert RouteHandler.choose_next_source("secondary", true, "maintain-primary", route) ==
               "primary"
    end
  end

  # =========================================================================
  # FAILOVER INTEGRATION (gen_statem failure paths)
  # =========================================================================

  describe "failover integration" do
    # Mirrors RouteHandler.init data struct shape.
    defp base_data(overrides) do
      now = System.monotonic_time(:millisecond)

      %{
        id: "test_route",
        route: %{
          "id" => "test_route",
          "name" => "Test Route",
          "schema" => "SRT",
          "destinations" => [],
          "schema_options" => %{"localaddress" => "127.0.0.1", "localport" => 4201}
        },
        port: nil,
        ffmpeg_port: nil,
        reconnect_started_at: nil,
        reconnect_count: 0,
        last_bytes_received: 0,
        last_bytes_changed_at: now,
        last_sdi_frames: %{},
        last_sdi_frames_changed_at: now,
        started_at: now - 20_000,
        consecutive_startup_crashes: 0,
        sdi_audio_last_restart_at: nil,
        active_source: "primary",
        failover_switched: false,
        source_health: %{primary: :unknown, secondary: :unknown},
        auto_join: true
      }
      |> Map.merge(overrides)
    end

    defp failover_route(mode) do
      %{
        "id" => "test_route",
        "name" => "Test Route",
        "schema" => "SRT",
        "destinations" => [],
        "schema_options" => %{"localaddress" => "primary-host", "localport" => 4201},
        "failover_enabled" => true,
        "failover_mode" => mode,
        "secondary_source" => %{
          "schema" => "SRT",
          "schema_options" => %{"localaddress" => "secondary-host", "localport" => 9999}
        }
      }
    end

    # Captures Db.update_route calls into the process dictionary for assertions.
    defp capture_update_route do
      Process.put(:captured_update_route, [])

      :meck.expect(Blackgate.Db, :update_route, fn id, params ->
        Process.put(:captured_update_route, [{id, params} | Process.get(:captured_update_route)])
        {:ok, %{}}
      end)
    end

    defp captured_update_route, do: Enum.reverse(Process.get(:captured_update_route, []))

    # Scenario (a): failover_enabled=false -> exit_status triggers normal restart,
    # active_source stays "primary", no Db.update_route for active_source.
    # Regression test: proves failover-off path is unchanged.
    test "failover_enabled=false: exit_status triggers restart, active_source stays primary" do
      capture_update_route()

      port = Port.open({:spawn, "cat"}, [:binary])

      data =
        base_data(%{
          port: port,
          route: %{
            "id" => "test_route",
            "name" => "Test Route",
            "schema" => "SRT",
            "destinations" => [],
            "failover_enabled" => false
          }
        })

      res = RouteHandler.handle_event(:info, {port, {:exit_status, 1}}, :started, data)

      assert elem(res, 0) == :next_state
      assert elem(res, 1) == :reconnecting

      new_data = elem(res, 2)
      assert new_data.active_source == "primary"

      refute Enum.any?(captured_update_route(), fn {_id, params} ->
               Map.has_key?(params, "active_source")
             end)
    end

    # Scenario (b): mode="manual" with a live port + SRT secondary is now
    # dual-ingest eligible, so trigger_restart takes the in-process path.
    # The stub engine ignores failover_mode and naively toggles to the other
    # source instead of stopping. Task 6 replaces the stub with mode-aware
    # evaluate_failover/1 that will restore manual mode's "stop" behavior.
    test "mode=manual with live port switches in-process (stub; Task 6 restores stop)" do
      capture_update_route()

      port = Port.open({:spawn, "cat"}, [:binary])
      data = base_data(%{port: port, route: failover_route("manual")})

      res = RouteHandler.handle_event(:info, {port, {:exit_status, 1}}, :started, data)

      assert elem(res, 0) == :keep_state

      new_data = elem(res, 1)
      assert new_data.active_source == "secondary"
      assert new_data.port == port
      assert new_data.failover_switched == true

      assert {"test_route", %{"active_source" => "secondary"}} in captured_update_route()
    end

    # Scenario (c): mode="maintain-stability" with a live port + SRT secondary
    # is dual-ingest eligible, so trigger_restart switches in-process: the C
    # dual-srtsrc bin is told to switch-source via its stdin channel and the
    # pipeline port is preserved (no reconnect storm). active_source toggles to
    # secondary and the new source is persisted.
    test "mode=maintain-stability on live port switches in-process to secondary" do
      capture_update_route()

      port = Port.open({:spawn, "cat"}, [:binary])
      data = base_data(%{port: port, route: failover_route("maintain-stability")})

      res = RouteHandler.handle_event(:info, {port, {:exit_status, 1}}, :started, data)

      assert elem(res, 0) == :keep_state

      new_data = elem(res, 1)
      assert new_data.active_source == "secondary"
      # In-process switch preserves the live port — no kill/respawn.
      assert new_data.port == port
      assert new_data.failover_switched == true

      assert {"test_route", %{"active_source" => "secondary"}} in captured_update_route()
    end

    # Scenario (d): maintain-primary reconnect timeout -> one-shot fallback to
    # secondary (re-enters :reconnecting instead of stopping).
    test "maintain-primary reconnect timeout falls back to secondary once" do
      capture_update_route()

      now = System.monotonic_time(:millisecond)

      data =
        base_data(%{
          route: failover_route("maintain-primary"),
          # Exceeds @reconnect_timeout_ms (180_000)
          reconnect_started_at: now - 200_000,
          reconnect_count: 5,
          active_source: "primary",
          failover_switched: false
        })

      res = RouteHandler.handle_event({:timeout, :reconnect}, :retry, :reconnecting, data)

      assert elem(res, 0) == :next_state
      assert elem(res, 1) == :reconnecting

      new_data = elem(res, 2)
      assert new_data.active_source == "secondary"
      assert new_data.failover_switched == true
      assert new_data.reconnect_count == 0

      assert {"test_route", %{"active_source" => "secondary"}} in captured_update_route()
    end

    # Scenario (d') guard: once already switched, timeout stops (no repeat switch).
    test "maintain-primary reconnect timeout stops when already switched to secondary" do
      capture_update_route()

      now = System.monotonic_time(:millisecond)

      data =
        base_data(%{
          route: failover_route("maintain-primary"),
          reconnect_started_at: now - 200_000,
          reconnect_count: 5,
          active_source: "secondary",
          failover_switched: true
        })

      res = RouteHandler.handle_event({:timeout, :reconnect}, :retry, :reconnecting, data)

      assert elem(res, 0) == :stop
    end
  end

  # =========================================================================
  # DUAL-SOURCE INIT PAYLOAD (send_initial_command)
  # =========================================================================

  describe "send_initial_command dual-source payload" do
    # Spawns a real port that redirects stdin to a temp file so we can inspect
    # the JSON bytes that RouteHandler.send_initial_command emits.
    defp capture_port(path) do
      Port.open({:spawn, "cat > #{path}"}, [:binary, :exit_status])
    end

    defp read_and_cleanup(path) do
      captured = File.read!(path)
      File.rm!(path)
      captured
    end

    defp failover_route_with_sinks do
      %{
        "id" => "test_route_failover",
        "name" => "Failover Route",
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "primary-host",
          "localport" => 4201,
          "mode" => "listener"
        },
        "destinations" => [
          %{
            "schema" => "SRT",
            "schema_options" => %{
              "localaddress" => "127.0.0.1",
              "localport" => 4202,
              "mode" => "listener"
            }
          }
        ],
        "failover_enabled" => true,
        "failover_mode" => "maintain-stability",
        "secondary_source" => %{
          "schema" => "SRT",
          "schema_options" => %{
            "localaddress" => "secondary-host",
            "localport" => 9999,
            "mode" => "caller"
          }
        },
        "auto_join" => true
      }
    end

    defp plain_route do
      %{
        "id" => "test_route_plain",
        "schema" => "SRT",
        "schema_options" => %{
          "localaddress" => "127.0.0.1",
          "localport" => 4201,
          "mode" => "listener"
        },
        "destinations" => [
          %{
            "schema" => "SRT",
            "schema_options" => %{
              "localaddress" => "127.0.0.1",
              "localport" => 4202,
              "mode" => "listener"
            }
          }
        ]
      }
    end

    test "send_initial_command emits dual-source JSON for failover route" do
      path = Path.join(System.tmp_dir!(), "bg_init_#{System.unique_integer([:positive])}.json")
      port = capture_port(path)
      route = failover_route_with_sinks()

      assert :ok = RouteHandler.send_initial_command(port, route)

      Port.close(port)

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        1_000 -> :ok
      end

      captured = read_and_cleanup(path)
      assert is_binary(captured)
      assert String.ends_with?(captured, "\n")

      {:ok, payload} = captured |> String.trim_trailing("\n") |> Jason.decode()

      assert payload["type"] == "init"
      assert payload["route_id"] == "test_route_failover"
      assert Map.has_key?(payload, "primary_source")
      assert Map.has_key?(payload, "secondary_source")

      assert is_map(payload["primary_source"])
      assert payload["primary_source"]["type"] == "srtsrc"
      assert payload["primary_source"]["uri"] =~ "primary-host"

      assert is_map(payload["secondary_source"])
      assert payload["secondary_source"]["type"] == "srtsrc"
      assert payload["secondary_source"]["uri"] =~ "secondary-host"

      assert payload["auto_join"] == true
      assert is_list(payload["sinks"])
      refute Map.has_key?(payload, "source")
    end

    test "send_initial_command emits legacy source-only JSON for non-failover route" do
      path = Path.join(System.tmp_dir!(), "bg_init_#{System.unique_integer([:positive])}.json")
      port = capture_port(path)
      route = plain_route()

      assert :ok = RouteHandler.send_initial_command(port, route)

      Port.close(port)

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        1_000 -> :ok
      end

      captured = read_and_cleanup(path)
      assert is_binary(captured)
      assert String.ends_with?(captured, "\n")

      {:ok, payload} = captured |> String.trim_trailing("\n") |> Jason.decode()

      assert Map.has_key?(payload, "source")
      assert is_map(payload["source"])
      assert payload["source"]["type"] == "srtsrc"
      assert is_list(payload["sinks"])
      refute Map.has_key?(payload, "secondary_source")
      refute Map.has_key?(payload, "primary_source")
      refute Map.has_key?(payload, "auto_join")
      refute Map.has_key?(payload, "type")
    end
  end

  # =========================================================================
  # IN-PROCESS SOURCE SWITCH (dual-ingest SRT)
  # =========================================================================

  describe "in-process switch (dual-ingest)" do
    # base_data/1 and failover_route/1 are defined in the "failover integration"
    # describe above; both are module-private and reused here so the data struct
    # stays a single source of truth mirroring RouteHandler.init/1.

    test "switch_source cast sends switch-source command and keeps the port alive" do
      path = Path.join(System.tmp_dir!(), "bg_switch_#{System.unique_integer([:positive])}.json")
      port = Port.open({:spawn, "cat > #{path}"}, [:binary, :exit_status])

      data = base_data(%{port: port, route: failover_route("maintain-primary")})

      result = RouteHandler.handle_event(:cast, {:switch_source, "secondary"}, :started, data)

      assert {:keep_state, new_data} = result
      assert new_data.active_source == "secondary"
      assert new_data.failover_switched == true
      # In-process switch preserves the live port — no kill/respawn.
      assert new_data.port == port

      Port.close(port)

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        1_000 -> :ok
      end

      captured = File.read!(path)
      File.rm!(path)

      {:ok, json} = Jason.decode(String.trim(captured))
      assert json["command"] == "switch-source"
      assert json["target"] == "secondary"
    end

    test "switch_source falls back to kill/respawn when secondary is non-SRT" do
      port = Port.open({:spawn, "cat"}, [:binary, :exit_status])

      route =
        put_in(failover_route("maintain-primary"), ["secondary_source", "schema"], "RTMP")

      data = base_data(%{port: port, route: route})

      result = RouteHandler.handle_event(:cast, {:switch_source, "secondary"}, :started, data)

      assert {:next_state, :reconnecting, new_data, _actions} = result
      assert is_nil(new_data.port)
      assert is_nil(new_data.ffmpeg_port)
      assert new_data.active_source == "secondary"
      assert new_data.failover_switched == false
    end
  end
end
