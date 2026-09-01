# Seamless SDI Failover Implementation Plan

## Objective

Reduce or eliminate the visible SDI blackout during source failover by keeping both source branches running and switching at a synchronized media boundary.

## Current baseline

- Dual-source configuration and selector switching are implemented.
- Safe dual-SRT routes can switch in-process.
- SDI routes use restart/reconnect failover unless `seamless_sdi_failover` is enabled.
- Observed SDI recovery gap is approximately 5–6 seconds.

## Implemented checkpoint

- Added opt-in `seamless_sdi_failover` route setting; default remains disabled.
- Seamless mode forces both SRT branches to remain warm.
- Native probes collect PAT/PMT program maps independently from both sources.
- Switch requests wait for an H.264 IDR, H.265 IRAP, or MPEG-2 I-picture on the target source.
- Selector switches only when program, PMT/PCR/video PIDs, codec, and all elementary stream PID/type entries match.
- Missing metadata, incompatible maps, missing keyframes, or missing acknowledgment use the existing restart fallback.
- Active-source persistence remains gated by native acknowledgment.
- Selector inactive-stream synchronization remains disabled because deployed testing showed it can stall the active SRT source when its peer is absent. Network sources preserve encoder PCR/PTS with `do-timestamp=false`; keyframe gating supplies the guarded media boundary without rewriting arrival timestamps.

## Remaining optional normalization work

The guarded implementation provides fast switching for matching encoders. It does not rewrite incompatible PIDs, continuity counters, PCR, or PTS. Supporting seamless switching between arbitrary encoder/muxer layouts requires a demux/remux normalizer before selection; until then those pairs deliberately use restart fallback.

## Implementation phases

1. Confirm pipeline topology and keep both source branches in `PLAYING` for seamless-capable routes.
2. Validate GStreamer selector `sync-streams` and `sync-mode` semantics against the deployed version; switch only at a safe running-time boundary.
3. Require matching encoder parameters: codec/profile, resolution, frame rate, audio layout, PIDs, PCR interval, timestamp mode, and IDR interval.
4. Ensure PAT/PMT and PCR are emitted promptly and periodically; add MPEG-TS normalization/remuxing if sources cannot be made identical.
5. Request or wait for an IDR/keyframe before selecting a new source when supported.
6. Track source connectivity, health, and selection separately. Do not tear down the inactive source during normal failover.
7. Keep restart/reconnect as a guarded fallback when synchronized switching cannot complete.
8. Persist and expose active source only after native selector acknowledgment; report seamless versus fallback switching.
9. Add metrics for switch request, selector acknowledgment, first output buffer, first IDR, and recovered SDI frame. Redact SRT credentials and full URIs.

## Verification

- Native selector and boundary unit tests.
- Synthetic MPEG-TS tests for PID, continuity counter, PCR, PTS, and IDR behavior.
- Long-running dual-source soak test.
- Hardware SDI tests in both directions, repeated cycles, inactive-source loss, switching-time loss, and encoder restart.
- Acceptance target: no visible black frame, or a measured gap within the agreed broadcast tolerance.

## Deployment strategy

Use a feature flag, enable first on the sandbox route, compare measured blackout against the 5–6 second restart baseline, and retain automatic fallback until soak testing is complete.

## Key decision

Determine whether both encoders can be configured identically. If not, implement a normalizer/remux stage before selector switching.
