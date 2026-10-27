defmodule Blackgate.EventGuidance do
  @moduledoc """
  What the operator should do about an event.

  The Events page is where an operator looks after a warning, so every event has to answer
  "what now?" on its own: an event that only states what happened leaves them guessing whether it
  matters. `action/3` returns that answer as text; `Blackgate.EventLog.log/4` stores it in
  `metadata[:action]` and the Events page renders it as a separate line under the message, so the
  message itself stays short.

  Rules for the text:
    - "none — ..." when nothing needs doing, and say why it is safe to ignore.
    - an instruction when the operator has to act, phrased as what to check or fix.
    - `nil` for pure bookkeeping events (a route starting or stopping needs no reaction).

  Keep it English: operators read these events, and the shared language of the UI is English.
  """

  @type metadata :: map()

  # One entry per event type. Types with no entry are bookkeeping and get no action text.
  @actions %{
    "system_action" =>
      "scheduled from Settings > System: it runs after a short delay and can still be cancelled from the same card",
    "loss_burst" => "none — SRT is retransmitting, the stream is not affected",
    "route_reconnected" => "none — the pipeline reconnected on its own",
    "route_reconnecting" =>
      "none if it recovers within a few seconds; if it repeats, check the source and the network path",
    "route_crashed" =>
      "check the route's engine output and configuration; the gateway restarts the pipeline automatically",
    "route_start_failed" =>
      "the route did not start: check its configuration, the source URL, and that the source is reachable",
    "route_hardware_error" =>
      "check the SDI device: Blackmagic Desktop Video driver, cable, and incoming signal",
    "reconnect_failed" =>
      "the source is unreachable after repeated attempts: check the source and the network path",
    "watchdog_restart" =>
      "none if the route recovers; if it repeats, check CPU load and the source bitrate",
    "source_video_corrupted" =>
      "check the source encoder — the gateway is receiving corrupt frames",
    "sdi_failed" =>
      "the route keeps streaming but has no SDI output, and the engine does not retry: check the Blackmagic Desktop Video driver and the card's devices, then restart the route",
    "sdi_audio_silent" =>
      "check the audio in the source; the gateway restarts the pipeline automatically while SDI audio stays silent",
    "sdi_audio_source_silent" =>
      "the source has no audio yet: no action needed unless audio is expected",
    "sdi_audio_desync_restart" =>
      "none — the pipeline was restarted automatically to resync SDI audio",
    "sdi_audio_desync_repeated" =>
      "audio keeps losing SDI sync: check the source audio and the SDI card",
    "sdi_audio_recovered" => "none — SDI audio is back in sync",
    "ffmpeg_missing" =>
      "install ffmpeg (the appliance image and `make install` provide it); RTMP/HTTP/HLS sources cannot start without it",
    "ffmpeg_started" => "none — informational",
    "failover_primary_timeout" =>
      "none if the backup source takes over; check the primary source if it keeps timing out",
    "failover_switched" => "none — failover is automatic; check the source that failed",
    "failover_auto" => "none — failover is automatic; check the source that failed",
    "output_in_use" =>
      "stop the route that holds this output or port, or point this route at another one",
    "license_route_stopped" =>
      "more routes were running than the licence covers: stop routes yourself or activate a licence that covers " <>
        "them; the gateway keeps the same routes running and stops the rest",
    "license_missing" =>
      "this gateway has no licence: activate one, or keep using the trial within its window and route count",
    "license_unreadable" =>
      "the gateway could not read its licence state, so no routes were stopped: check that the box\'s storage is " <>
        "intact, then restart the gateway",
    "failover_inprocess_switch" =>
      "none — the pipeline switched source in place; check the source that failed",
    "failover_inprocess_requested" =>
      "none yet — the switch completes on the new source's next keyframe; a rebuild follows if none arrives",
    "failover_inprocess_rejected" =>
      "the two sources cannot be cut together in place: compare their video codec, resolution, framerate, " <>
        "and programme (PID) settings",
    "failover_inprocess_timeout" =>
      "the new source produced no keyframe in time: check that it is really streaming, then start the route " <>
        "if the rebuild did not recover it",
    "failover_manual_switch" => "none — the operator selected this source",
    "failover_both_invalid" =>
      "both sources are unusable: fix their configurations, then start the route",
    "failover_manual_stop" =>
      "manual failover has no next source: fix the failed source or add a backup, then start the route"
  }

  @doc """
  The action text for an event, or nil when no reaction is expected.

  `health_changed` carries the number of the verdict in the message, so its action depends
  on the health the route moved to (`metadata[:current_health]`).
  """
  @spec action(String.t(), atom(), metadata()) :: String.t() | nil
  def action("health_changed", _severity, metadata) do
    case metadata[:current_health] do
      "healthy" ->
        "none — the route is back inside its thresholds"

      "disconnected" ->
        "none while no stream is expected; check the source if it should be sending"

      "warning" ->
        "check the ingest path to the source (uplink, ISP, router); SRT retransmits, so expect visible artifacts only if the loss persists"

      "critical" ->
        "check the ingest path to the source now; loss this high is visible to viewers"

      "network_loss_egress" ->
        "check the egress link to the destinations — the ingest side is clean"

      "source_corrupted" ->
        "check the source encoder — the gateway is receiving corrupt frames"

      "blackgate_config_issue" ->
        "check the route configuration against the source: codec, pids, and container format"

      _ ->
        nil
    end
  end

  def action(type, _severity, _metadata), do: Map.get(@actions, type)
end
