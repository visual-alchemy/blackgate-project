defmodule Blackgate.RouteHealthTest do
  use ExUnit.Case, async: true
  alias Blackgate.RouteHealth

  test "evaluate/1 disconnected" do
    assert RouteHealth.evaluate(nil) == "disconnected"
    assert RouteHealth.evaluate(%{}) == "disconnected"
    assert RouteHealth.evaluate(%{"receive-rate-mbps" => 0.0}) == "disconnected"
  end

  test "evaluate/1 healthy stream" do
    stats = %{
      "receive-rate-mbps" => 5.5,
      "packets-received" => 1000,
      "packets-received-lost" => 0,
      "rtt-ms" => 10.0,
      "warning_count" => 0,
      "sink_stats" => []
    }

    assert RouteHealth.evaluate(stats) == "healthy"
  end

  test "evaluate/1 uses the windowed loss so a settled connection stays healthy" do
    # The cumulative counters still carry the connection-startup burst (3.2% here)
    # while the last report window shows 0.65%: the route has settled and must not
    # be reported as degraded for the rest of its life.
    stats = %{
      "receive-rate-mbps" => 13.6,
      "packets-received" => 103_738,
      "packets-received-lost" => 3403,
      "loss-window-pct" => 0.653,
      "rtt-ms" => 0.54,
      "warning_count" => 0,
      "sink_stats" => []
    }

    assert RouteHealth.evaluate(stats) == "healthy"
  end

  test "evaluate/1 still warns when the current window is lossy" do
    stats = %{
      "receive-rate-mbps" => 13.6,
      "packets-received" => 100_000,
      "packets-received-lost" => 100,
      "loss-window-pct" => 3.5,
      "rtt-ms" => 0.5,
      "warning_count" => 0,
      "sink_stats" => []
    }

    assert RouteHealth.evaluate(stats) == "warning"
  end

  test "evaluate/1 source corrupted (warnings present, no packet loss)" do
    stats = %{
      "receive-rate-mbps" => 5.5,
      "packets-received" => 1000,
      "packets-received-lost" => 0,
      "rtt-ms" => 10.0,
      "warning_count" => 5,
      "sink_stats" => []
    }

    assert RouteHealth.evaluate(stats) == "source_corrupted"
  end

  test "evaluate/1 blackgate config issue (warnings + ingest loss)" do
    stats = %{
      "receive-rate-mbps" => 5.5,
      "packets-received" => 1000,
      # 2.0% loss
      "packets-received-lost" => 20,
      "rtt-ms" => 10.0,
      "warning_count" => 5,
      "sink_stats" => []
    }

    assert RouteHealth.evaluate(stats) == "blackgate_config_issue"
  end

  test "evaluate/1 network loss egress (egress link dropping packets)" do
    stats = %{
      "receive-rate-mbps" => 5.5,
      "packets-received" => 1000,
      "packets-received-lost" => 0,
      "rtt-ms" => 10.0,
      "warning_count" => 0,
      "sink_stats" => [
        %{
          sink_index: 0,
          stats: %{
            "packets-sent" => 1000,
            # 3% loss
            "packets-sent-lost" => 30
          }
        }
      ]
    }

    assert RouteHealth.evaluate(stats) == "network_loss_egress"
  end
end
