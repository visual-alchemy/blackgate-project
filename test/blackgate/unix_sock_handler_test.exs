defmodule Blackgate.UnixSockHandlerTest do
  use ExUnit.Case
  alias Blackgate.UnixSockHandler

  # Every engine record is newline-terminated (the unframed "route_id:" / "stats_source_stream_id:"
  # writes were fixed at the source), so the handler buffers per connection and parses COMPLETE
  # records. The tests below therefore feed whole records, and the boundary tests at the end cover
  # the chunk shapes that used to be dropped silently.

  test "callback_mode returns handle_event_function" do
    assert UnixSockHandler.callback_mode() == [:handle_event_function]
  end

  test "init returns ignore" do
    assert :ignore = UnixSockHandler.init([])
  end

  test "handle_event with route_id message" do
    route_id = "test_route"
    message = {:tcp, nil, "route_id:" <> route_id <> "\n"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert {:keep_state, new_data} = UnixSockHandler.handle_event(:info, message, state, data)
    assert new_data.route_id == route_id
  end

  test "handle_event with empty route_id message" do
    message = {:tcp, nil, "route_id:\n"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert {:keep_state, new_data} = UnixSockHandler.handle_event(:info, message, state, data)
    assert new_data.route_id == ""
  end

  test "handle_event with stats_json message and exportStats true" do
    json = ~s({"bytes_sent": 1000, "bytes_received": 2000})
    message = {:tcp, nil, "stats_json:" <> json <> "\n"}
    state = :exchange

    data = %{
      sock: nil,
      trans: nil,
      source_stream_id: "test_stream",
      route_id: "test_route",
      route_record: %{"exportStats" => true, "name" => "test"}
    }

    assert {:keep_state, _} = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "handle_event with invalid stats_json message" do
    json = ~s({invalid_json)
    message = {:tcp, nil, "stats_json:" <> json <> "\n"}
    state = :exchange

    data = %{
      sock: nil,
      trans: nil,
      source_stream_id: "test_stream",
      route_id: "test_route",
      route_record: %{"exportStats" => true, "name" => "test"}
    }

    assert {:keep_state, _} = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "handle_event with stats_json message and exportStats false" do
    json = ~s({"bytes_sent": 1000, "bytes_received": 2000})
    message = {:tcp, nil, "stats_json:" <> json <> "\n"}
    state = :exchange

    data = %{
      sock: nil,
      trans: nil,
      source_stream_id: "test_stream",
      route_id: "test_route",
      route_record: %{"exportStats" => false}
    }

    assert {:keep_state, _} = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "handle_event with stats_json message and missing route_record" do
    json = ~s({"bytes_sent": 1000, "bytes_received": 2000})
    message = {:tcp, nil, "stats_json:" <> json <> "\n"}
    state = :exchange

    data = %{
      sock: nil,
      trans: nil,
      source_stream_id: "test_stream",
      route_id: "test_route",
      route_record: nil
    }

    assert {:keep_state, _} = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "handle_event with stats_source_stream_id message" do
    stream_id = "test_stream"
    message = {:tcp, nil, "stats_source_stream_id:" <> stream_id <> "\n"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert {:keep_state, new_data} = UnixSockHandler.handle_event(:info, message, state, data)
    assert new_data.source_stream_id == stream_id
  end

  test "handle_event with empty stats_source_stream_id message" do
    message = {:tcp, nil, "stats_source_stream_id:\n"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert {:keep_state, new_data} = UnixSockHandler.handle_event(:info, message, state, data)
    assert new_data.source_stream_id == ""
  end

  test "handle_event processes a sink payload that follows a terminator" do
    # The engine can flush the previous record's terminator in the same chunk as the next payload
    # ("\nstats_sink:{...}"). That is no longer a special case: the leading empty record is skipped
    # and the sink record is parsed as a whole.
    route_id = "newline_sink_route"
    json = ~s({"sink-index":0,"bytes-sent-total":1234})
    message = {:tcp, nil, "\nstats_sink:" <> json <> "\n"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: route_id, route_record: nil}

    assert {:keep_state, _} = UnixSockHandler.handle_event(:info, message, state, data)

    assert %{stats: %{"bytes-sent-total" => 1234}} =
             Blackgate.RouteStatsRegistry.get_sink_stats(route_id, 0)
  end

  test "handle_event processes a source payload that follows a terminator" do
    route_id = "newline_source_route"
    json = ~s({"total-bytes-received":4321})
    message = {:tcp, nil, "\n" <> json <> "\n"}
    state = :exchange

    data = %{
      sock: nil,
      trans: nil,
      source_stream_id: nil,
      route_id: route_id,
      route_record: %{"exportStats" => false, "name" => "newline source"}
    }

    assert {:keep_state, _} = UnixSockHandler.handle_event(:info, message, state, data)

    assert %{stats: %{"total-bytes-received" => 4321}} =
             Blackgate.RouteStatsRegistry.get_stats(route_id)
  end

  test "handle_event routes a sink record whose bytes were split across chunks" do
    # The bug this replaces: a chunk that began inside a JSON payload matched no clause, fell into
    # the catch-all and its stats were dropped without a trace.
    route_id = "split_sink_route"
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: route_id, route_record: nil}

    assert {:keep_state, data} =
             UnixSockHandler.handle_event(
               :info,
               {:tcp, nil, "stats_sink:{\"sink-index\":0,"},
               state,
               data
             )

    # Nothing is parsed until the record is complete.
    assert Blackgate.RouteStatsRegistry.get_sink_stats(route_id, 0) == nil

    assert {:keep_state, _data} =
             UnixSockHandler.handle_event(
               :info,
               {:tcp, nil, "\"bytes-sent-total\":77}\n"},
               state,
               data
             )

    assert %{stats: %{"bytes-sent-total" => 77}} =
             Blackgate.RouteStatsRegistry.get_sink_stats(route_id, 0)

    # The source slot must be untouched by sink data.
    assert Blackgate.RouteStatsRegistry.get_stats(route_id) == nil
  end

  test "handle_event ignores a bare newline" do
    assert {:keep_state, _} =
             UnixSockHandler.handle_event(:info, {:tcp, nil, "\n"}, :exchange, %{})
  end

  test "handle_event with undefined message" do
    message = {:tcp, nil, "undefined_message\n"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert {:keep_state, _} = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "handle_event with non-tcp message" do
    message = {:other, nil, "some_message"}
    state = :exchange
    data = %{sock: nil, trans: nil, source_stream_id: nil, route_id: nil, route_record: nil}

    assert :keep_state_and_data = UnixSockHandler.handle_event(:info, message, state, data)
  end

  test "an engine transport exit stops the handler instead of logging an undefined message" do
    # trap_exit is on, so this arrives as a plain message; without a clause each engine that went
    # away logged an "Undefined msg" error as it left.
    assert {:stop, :normal} =
             UnixSockHandler.handle_event(:info, {:EXIT, nil, :normal}, :exchange, %{})
  end

  test "a closed socket stops the handler" do
    assert {:stop, :normal} =
             UnixSockHandler.handle_event(:info, {:tcp_closed, nil}, :exchange, %{})
  end

  ## Boundary cases: TCP gives no record boundaries, the handler must supply them

  test "split_lines reassembles a record cut in the middle" do
    {lines, rest} = UnixSockHandler.split_lines(~s({"source":"primary","rate":10.))
    assert lines == []
    assert rest == ~s({"source":"primary","rate":10.)

    {lines, rest} = UnixSockHandler.split_lines(rest <> "34}\n")
    assert lines == [~s({"source":"primary","rate":10.34})]
    assert rest == ""
  end

  test "split_lines returns every record from one chunk" do
    {lines, rest} =
      UnixSockHandler.split_lines("stats_sink:{\"sink-index\":0}\n{\"source\":\"primary\"}\n")

    assert lines == ["stats_sink:{\"sink-index\":0}", "{\"source\":\"primary\"}"]
    assert rest == ""
  end

  test "split_lines keeps a partial trailing record" do
    {lines, rest} = UnixSockHandler.split_lines("{\"a\":1}\nstats_sink:{\"b\":2}")
    assert lines == ["{\"a\":1}"]
    assert rest == ~s(stats_sink:{"b":2})
  end

  test "split_lines on an empty buffer yields nothing to parse" do
    assert {[], ""} = UnixSockHandler.split_lines("")
  end

  test "terminate returns ok" do
    assert :ok = UnixSockHandler.terminate(:normal, :exchange, %{})
  end

  test "terminate with different reasons" do
    reasons = [:normal, :shutdown, :timeout, {:error, "test"}]

    for reason <- reasons do
      assert :ok = UnixSockHandler.terminate(reason, :exchange, %{})
    end
  end

  test "stats_to_metrics with nested data" do
    stats = %{
      "nested" => [
        %{"value" => 100},
        %{"value" => 200}
      ],
      "simple" => 300
    }

    data = %{
      route_id: "test_route",
      route_record: %{"name" => "test"},
      source_stream_id: "test_stream"
    }

    UnixSockHandler.stats_to_metrics(stats, data)
  end

  test "stats_to_metrics with deeply nested data" do
    stats = %{
      "level1" => %{
        "level2" => [
          %{"level3" => %{"value" => 100}},
          %{"level3" => %{"value" => 200}}
        ]
      },
      "simple" => 300
    }

    data = %{
      route_id: "test_route",
      route_record: %{"name" => "test"},
      source_stream_id: "test_stream"
    }

    UnixSockHandler.stats_to_metrics(stats, data)
  end

  test "stats_to_metrics with a list of scalars (audio-pids)" do
    # audio-pids is a list of integers; walking it as if it held maps raised
    # BadMapError on every stats report.
    stats = %{
      "audio-pids" => [66],
      "video-pid" => 65,
      "callers" => [%{"rtt-ms" => 0.5}]
    }

    data = %{
      route_id: "test_route",
      route_record: %{"name" => "test"},
      source_stream_id: "test_stream"
    }

    UnixSockHandler.stats_to_metrics(stats, data)
  end

  test "norm_names normalizes metric names" do
    assert "test_metric" = UnixSockHandler.norm_names("test-metric")
    assert "test_metric" = UnixSockHandler.norm_names("TEST_METRIC")
    assert "test_metric" = UnixSockHandler.norm_names("Test-Metric")
  end

  test "test runs never bind the production stats socket" do
    # Binding /tmp/hydra_unix_sock from a test run unlinked the live listener's
    # socket and left a dead file behind, so every new engine failed to connect
    # and its route crash-looped while already-connected routes kept running.
    refute Blackgate.stats_socket_path() == "/tmp/hydra_unix_sock"
    assert String.ends_with?(Blackgate.stats_socket_path(), ".sock")
  end

  test "assert_stats_socket_free!/1 refuses a path that already has a listener" do
    path = Path.join(System.tmp_dir!(), "blackgate_sock_probe_#{System.pid()}.sock")
    File.rm(path)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {:local, path}, active: false])

    assert_raise RuntimeError, ~r/already has a live listener/, fn ->
      Blackgate.Application.assert_stats_socket_free!(path)
    end

    :gen_tcp.close(listener)
    File.rm(path)
  end

  test "assert_stats_socket_free!/1 accepts a missing path and a stale file" do
    missing = Path.join(System.tmp_dir!(), "blackgate_sock_missing_#{System.pid()}.sock")
    File.rm(missing)
    assert :ok = Blackgate.Application.assert_stats_socket_free!(missing)

    # A leftover socket file with no listener behind it is what a crashed node
    # leaves; Ranch unlinks it when binding, so it must not block startup.
    stale = Path.join(System.tmp_dir!(), "blackgate_sock_stale_#{System.pid()}.sock")
    File.rm(stale)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {:local, stale}, active: false])
    :gen_tcp.close(listener)

    assert :ok = Blackgate.Application.assert_stats_socket_free!(stale)
    File.rm(stale)
  end

  test "norm_names with various special characters" do
    assert "test_metric_name" = UnixSockHandler.norm_names("test-metric-name")
    assert "test_metric_name" = UnixSockHandler.norm_names("test.metric.name")
    assert "test_metric_name" = UnixSockHandler.norm_names("test/metric/name")
    assert "test_metric_name" = UnixSockHandler.norm_names("test:metric:name")
  end
end
