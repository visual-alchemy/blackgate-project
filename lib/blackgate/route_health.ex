defmodule Blackgate.RouteHealth do
  @moduledoc """
  Evaluates the health of a route based on its current stats.

  Returns one of:
    - "healthy"       — stream connected, all metrics within normal range
    - "warning"       — sustained loss or RTT degradation
    - "critical"      — sustained loss or RTT far past the limit
    - "network_loss_egress" / "source_corrupted" / "blackgate_config_issue"
    - "disconnected"  — route is running but no active stream data

  Loss is judged on the SUSTAINED loss over ~10 s (`loss-window-10s-pct`), not on a single
  one-second report window, and a warning additionally requires the condition to hold for
  `@warning_streak` consecutive reports. A one-second burst at 20 Mbps is ~40 packets: SRT
  retransmits it and the stream is healthy again a second later, yet judging on the 1 s
  window logged ~20 warnings per hour per route on streams whose cumulative loss stayed at
  0.17 %. Such bursts are reported separately, as an informational event.
  """

  # Sustained packet loss thresholds (percentage, over ~10 s)
  @loss_warning 2.0
  @loss_critical 10.0

  # Consecutive reports at or above the warning threshold before health degrades
  @warning_streak 3

  # A single report window at or above this, while the sustained figure is fine, is a burst
  @burst_warning 2.0

  # RTT thresholds (milliseconds)
  @rtt_warning 300.0
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
      # Prefer the sustained loss over ~10 s: the cumulative counters keep the
      # connection-startup burst in the ratio for the whole life of the connection, and a
      # single 1 s window is too short to mean anything (a handful of lost packets in one
      # second reads as several percent). Until ~10 s of history exists the 1 s window is
      # the only signal available, and the streak requirement below keeps it from firing on
      # one bad report.
      sustained = sustained_loss(stats, caller)
      rtt = stats["rtt-ms"] || caller["rtt-ms"] || 0.0
      streak = stats["loss-streak"] || 0

      # `drops_per_sec` in `sdi_video_stats` is deliberately excluded here:
      # it counts `videorate` "drop" events, i.e. expected framerate-conversion
      # drops (50p -> 25p drops every other frame), not DeckLink hardware
      # failures. Hardware failures crash the pipeline and are handled by
      # RouteHandler restart logic instead.

      # Extract pipeline warnings and the egress verdict
      warning_count = stats["warning_count"] || 0

      # Egress loss is judged on the same ~10 s window and the same hysteresis as the ingest
      # leg, not on the sink's lifetime counters. `packets-sent-lost` on an srtsink is SRT's
      # reported loss (`pktSndLossTotal`): packets the PEER reported missing, most of which the
      # sender retransmits inside the negotiated latency. Summed over the life of the engine, a
      # burst while a client connected pinned the route to "Egress Loss" while every viewer
      # played without a single artefact. The windowed figure and the destination that held it
      # come from Blackgate.RouteStatsRegistry, which owns the history.
      has_egress_loss? = egress_loss?(stats["egress-loss-10s-pct"], stats["egress-streak"] || 0)

      cond do
        # 1. Pipeline warning present
        warning_count > 0 ->
          if sustained >= 0.5 do
            "blackgate_config_issue"
          else
            "source_corrupted"
          end

        # 2. Critical network issues
        sustained >= @loss_critical or rtt >= @rtt_critical ->
          "critical"

        # 3. Egress packet loss to client players
        has_egress_loss? ->
          "network_loss_egress"

        # 4. Warnings — sustained past the threshold, for several reports in a row
        (sustained >= @loss_warning or rtt >= @rtt_warning) and streak >= @warning_streak ->
          "warning"

        true ->
          "healthy"
      end
    end
  end

  @doc """
  True when a single report window lost packets while the sustained figure is fine.

  Reported as an informational event, never as degraded health: measured windows reach
  2-7 % with SRT retransmitting everything and a cumulative loss of 0.17 %.
  """
  def transient_burst?(stats) when is_map(stats) do
    instant = stats["loss-window-pct"]
    sustained = sustained_loss(stats, List.first(stats["callers"] || []) || %{})

    is_number(instant) and instant >= @burst_warning and sustained < @loss_warning
  end

  def transient_burst?(_), do: false

  @doc """
  True when the current figures are past the warning threshold, before hysteresis.

  The registry uses this to count how many reports in a row the route was degraded: the
  condition covers both loss and RTT, so a sustained RTT spike also has to hold for
  `@warning_streak` reports before health degrades.
  """
  def degraded?(stats) when is_map(stats) do
    sustained = sustained_loss(stats, List.first(stats["callers"] || []) || %{})
    rtt = stats["rtt-ms"] || 0.0

    sustained >= @loss_warning or rtt >= @rtt_warning
  end

  def degraded?(_), do: false

  @doc """
  True when the egress leg has been losing packets long enough to be real.

  `pct` is the worst destination's ratio over the ~10 s window and `streak` the number of
  consecutive reports that crossed `egress_threshold/0`. Severe loss fires at once; anything
  between the warning threshold and severe has to hold, exactly like the ingest leg. A `nil`
  `pct` means the route has not reported enough history to judge — that is not evidence of
  loss, and it must never degrade a route on its own.
  """
  def egress_loss?(pct, streak) when is_number(pct) and is_integer(streak),
    do: pct >= @loss_critical or (pct >= @loss_warning and streak >= @warning_streak)

  def egress_loss?(_, _), do: false

  @doc """
  The threshold the egress verdict shares with the ingest verdict, so the registry can count
  a streak from one number instead of duplicating it.
  """
  def egress_threshold, do: @loss_warning

  # --- private ---

  defp sustained_loss(stats, caller) do
    stats["loss-window-10s-pct"] || stats["loss-window-pct"] || packet_loss_pct(stats, caller)
  end

  defp packet_loss_pct(stats, caller) do
    received = stats["packets-received"] || caller["packets-received"] || 0
    lost = stats["packets-received-lost"] || caller["packets-received-lost"] || 0

    if received + lost == 0 do
      0.0
    else
      lost / (received + lost) * 100.0
    end
  end
end
