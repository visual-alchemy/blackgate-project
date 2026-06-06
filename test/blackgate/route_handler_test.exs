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
        {:ok, %{
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
        {:ok, %{
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
        {:ok, %{
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
      started_at: now - 10_000, # 10 seconds ago (grace period is 30s)
      consecutive_startup_crashes: 0
    }

    assert {:keep_state_and_data, _} = RouteHandler.handle_event({:timeout, :watchdog}, :check, :started, data)
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
      started_at: now - 40_000, # past grace period
      consecutive_startup_crashes: 0
    }

    # Put new bytes in stats registry
    stats = %{"total-bytes-received" => 200}
    Blackgate.RouteStatsRegistry.put_stats("test_route", stats)

    assert {:keep_state, updated_data, _} = RouteHandler.handle_event({:timeout, :watchdog}, :check, :started, data)
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
      last_bytes_changed_at: now - 70_000, # stalled for 70 seconds (> 60s threshold)
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

    assert {:keep_state, updated_data, _} = RouteHandler.handle_event({:timeout, :watchdog}, :check, :started, data)
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
      last_bytes_changed_at: now, # network is fine
      last_sdi_frames: %{2 => 500},
      last_sdi_frames_changed_at: now - 70_000, # playout frozen for 70 seconds (> 60s threshold)
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
end
