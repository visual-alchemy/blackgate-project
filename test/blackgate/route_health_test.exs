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

  test "evaluate/1 does not degrade health on a single lossy report window" do
    # One 1 s window at 3.5 % while the connection has run for a while and is otherwise
    # fine: a burst SRT retransmits, not a degraded route. Measured on the box: windows of
    # 2-7 % with cumulative loss of 0.17 %.
    stats = %{
      "receive-rate-mbps" => 13.6,
      "packets-received" => 100_000,
      "packets-received-lost" => 100,
      "loss-window-pct" => 3.5,
      "loss-window-10s-pct" => 0.4,
      "loss-streak" => 0,
      "rtt-ms" => 0.5,
      "warning_count" => 0,
      "sink_stats" => []
    }

    assert RouteHealth.evaluate(stats) == "healthy"
  end

  test "evaluate/1 warns when the 10 s loss is sustained and the streak is met" do
    stats = %{
      "receive-rate-mbps" => 13.6,
      "packets-received" => 100_000,
      "packets-received-lost" => 100,
      "loss-window-pct" => 2.5,
      "loss-window-10s-pct" => 2.4,
      "loss-streak" => 3,
      "rtt-ms" => 0.5,
      "warning_count" => 0,
      "sink_stats" => []
    }

    assert RouteHealth.evaluate(stats) == "warning"

    # Two reports in a row is not yet a warning: the hysteresis gate holds it back.
    assert RouteHealth.evaluate(%{stats | "loss-streak" => 2}) == "healthy"
  end

  test "evaluate/1 critical when sustained loss is severe, without waiting for a streak" do
    stats = %{
      "receive-rate-mbps" => 13.6,
      "packets-received" => 100_000,
      "packets-received-lost" => 12_000,
      "loss-window-pct" => 12.0,
      "loss-window-10s-pct" => 12.0,
      "loss-streak" => 0,
      "rtt-ms" => 0.5,
      "warning_count" => 0,
      "sink_stats" => []
    }

    assert RouteHealth.evaluate(stats) == "critical"
  end

  test "transient_burst?/1 is true only while the sustained figure is fine" do
    burst = %{"loss-window-pct" => 4.2, "loss-window-10s-pct" => 0.3}
    assert RouteHealth.transient_burst?(burst)

    sustained = %{"loss-window-pct" => 4.2, "loss-window-10s-pct" => 3.1}
    refute RouteHealth.transient_burst?(sustained)

    refute RouteHealth.transient_burst?(%{"loss-window-pct" => 0.1, "loss-window-10s-pct" => 0.1})
    refute RouteHealth.transient_burst?(nil)
  end

  test "degraded?/1 covers loss and RTT without the hysteresis gate" do
    assert RouteHealth.degraded?(%{"loss-window-10s-pct" => 2.4})
    assert RouteHealth.degraded?(%{"rtt-ms" => 350.0})
    refute RouteHealth.degraded?(%{"loss-window-10s-pct" => 1.2, "rtt-ms" => 10.0})
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
