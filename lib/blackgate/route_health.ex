defmodule Blackgate.RouteHealth do
  @moduledoc """
  Evaluates the health of a route based on its current stats.

  Returns one of:
    - :healthy       — stream connected, all metrics within normal range
    - :warning       — stream connected, metrics slightly degraded
    - :critical      — stream connected, metrics severely degraded
    - :disconnected  — route is running but no active stream data
  """

  # Packet loss thresholds (percentage)
  @loss_warning 2.0
  @loss_critical 10.0

  # RTT thresholds (milliseconds)
  @rtt_warning 150.0
  @rtt_critical 500.0

  @doc """
  Evaluate health from a stats map (as received from the GStreamer pipeline).
  Returns a string so it serialises cleanly to JSON over the WebSocket.
  """
  def evaluate(nil), do: "disconnected"

  def evaluate(stats) when is_map(stats) do
    receive_mbps = stats["receive-rate-mbps"] || 0
    callers = stats["callers"] || []
    connected_callers = stats["connected-callers"] || 0

    # In caller mode the top-level bitrate is populated;
    # in listener mode we look at the first caller entry.
    caller = List.first(callers) || %{}
    caller_mbps = caller["receive-rate-mbps"] || 0
    has_signal = receive_mbps > 0 or caller_mbps > 0 or connected_callers > 0

    if not has_signal do
      "disconnected"
    else
      loss = packet_loss_pct(stats, caller)
      rtt = stats["rtt-ms"] || caller["rtt-ms"] || 0.0

      cond do
        loss >= @loss_critical or rtt >= @rtt_critical -> "critical"
        loss >= @loss_warning or rtt >= @rtt_warning   -> "warning"
        true                                           -> "healthy"
      end
    end
  end

  # --- private ---

  defp packet_loss_pct(stats, caller) do
    received = stats["packets-received"] || caller["packets-received"] || 0
    lost     = stats["packets-received-lost"] || caller["packets-received-lost"] || 0

    if received + lost == 0 do
      0.0
    else
      lost / (received + lost) * 100.0
    end
  end
end
