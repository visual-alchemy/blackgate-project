# Physical DeckLink / SDI Manual Sign-off

Automated tests cannot validate electrical SDI output, DeckLink clocking, or
embedded audio. Complete this checklist on target Ubuntu 24.04 LTS gateway only
after repository status reaches `SDI_MANUAL_PENDING`.

## Test identity

- Gateway identifier / serial:
- Blackgate commit:
- Appliance ISO/version:
- Ubuntu version (`lsb_release -ds`):
- Kernel (`uname -r`):
- Blackmagic Desktop Video version:
- DeckLink model and firmware:
- GStreamer version (`gst-launch-1.0 --version`):
- Operator:
- Date/time/timezone:
- Attached evidence/log path:

## Preconditions

- [ ] `systemctl status blackgate` healthy; no restart loop.
- [ ] `gst-inspect-1.0 decklinkvideosink` succeeds.
- [ ] All expected `/dev/blackmagic/io*` devices exist and permissions work for
      `blackgate` user.
- [ ] Rust engine path/process confirmed; no legacy engine executable present.
- [ ] Known-good SDI analyzer/monitor and audio meter connected.

## Video modes

Record output, lock time, image continuity, and analyzer result for each mode
supported by deployment:

- [ ] 1080p25
- [ ] 1080p50
- [ ] 1080i50
- [ ] 720p50
- [ ] PAL/NTSC SD when required
- [ ] 2160p mode when required by installed card
- [ ] Automatic source-mode detection selects correct output mode.
- [ ] Mode changes do not leave stale/frozen output.

Notes/results:

## Embedded audio

- [ ] Exactly eight embedded output channels visible on analyzer.
- [ ] Stereo source mapping/upmix matches intended channel matrix.
- [ ] Continuous tone/program audio has no drift, underrun, stutter, or silence.
- [ ] Audio remains synchronized after route restart and source reconnect.
- [ ] `SDI_AUDIO_SILENT` recovery restores audio without restart loop.

Notes/results:

## Failover and stability

- [ ] Primary-to-secondary SRT failover preserves SDI output.
- [ ] Manual switchback restores primary source correctly.
- [ ] Recovered primary behavior matches configured failover policy.
- [ ] One-hour continuous SDI run completes without engine crash, watchdog
      restart, growing memory, frozen video, or audio loss.
- [ ] Service reboot recovery starts route and restores valid SDI output.

Notes/results:

## Evidence

- [ ] `journalctl -u blackgate` captured for full test window.
- [ ] Route/event logs captured.
- [ ] Analyzer screenshots/photos attached.
- [ ] Any failures include timestamp, route configuration, source details, and
      reproduction steps.

## Decision

- Result: `PASS` / `FAIL`
- Exceptions/waivers: none / describe:
- Operator signature:
- Reviewer signature:
- Approval date:

Only signed `PASS` permits migration status `PRODUCTION_COMPLETE`. Unsigned,
partial, or waived hardware result remains `SDI_MANUAL_PENDING` or returns to
`IN_PROGRESS` when it exposes software regression.
