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
      "packets-received-lost" => 20, # 2.0% loss
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
            "packets-sent-lost" => 30 # 3% loss
          }
        }
      ]
    }
    assert RouteHealth.evaluate(stats) == "network_loss_egress"
  end

  test "evaluate/1 healthy despite SDI framerate-conversion drops" do
    # `drops_per_sec` reflects videorate downconversion (e.g. 50p -> 25p),
    # not a hardware failure, so it must not degrade health to warning.
    stats = %{
      "receive-rate-mbps" => 5.5,
      "packets-received" => 1000,
      "packets-received-lost" => 0,
      "rtt-ms" => 10.0,
      "warning_count" => 0,
      "sink_stats" => [],
      "sdi_video_stats" => [
        %{"device_number" => 0, "drops_per_sec" => 25.0, "duplicates_per_sec" => 0.0}
      ]
    }
    assert RouteHealth.evaluate(stats) == "healthy"
  end
end
