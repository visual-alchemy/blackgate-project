# System actions and software updates

How Settings > System gets its powers, what each privileged step actually does, and how to prove it
works without rebooting a live gateway.

## What the tab shows and does

| Card | Reads / does | Needs root |
| --- | --- | --- |
| Gateway Status | host, OS, kernel, uptime, memory, disk, UDP socket buffers (vs the documented 16 MB), DeckLink devices, engine binary sha256, service unit state, deployed release, per-route SDI stats | no |
| Download System Report | the same facts plus Blackmagic's firmware view, as a `.txt` (`GET /api/system/report`) | no |
| Maintenance | Restart Gateway, Reboot Gateway, Shutdown Gateway, cancel a scheduled action | yes, via the helper |
| Software Update | upload a `.bgupdate`, list packages, deploy or roll back to a version | yes, for deploy |

Endpoints: `GET /api/system/status`, `GET /api/system/report`, `POST /api/system/actions/:action`,
`GET /api/system/updates`, `POST /api/system/updates` (package body), `POST
/api/system/updates/:version/deploy`. All of them sit behind the same bearer-token auth as the rest
of the API.

## Install (once, as root)

```bash
sudo scripts/install-system-actions.sh                 # appliance layout (/opt/blackgate)
sudo scripts/install-system-actions.sh --root /srv/blackgate --data-dir /var/lib/blackgate/khepri
sudo scripts/install-system-actions.sh --help
```

It installs, idempotently:

- `/etc/systemd/system/blackgate.service` — runs `$ROOT/current`, so an update only swaps a symlink.
  `Restart=always`, and `ExecStartPre` clears the stale `/tmp/hydra_unix_sock` that otherwise makes
  the Ranch unix listener fail to bind.
- `/usr/local/libexec/blackgate-system-action` — the only privileged path, `0750 root:root`.
- `/etc/sudoers.d/blackgate-system-action` — NOPASSWD for that helper and nothing else; validated with
  `visudo -c` before it is installed, because a broken file there locks out every sudo user.
- `/usr/local/libexec/blackgate-updater` — verifies and applies packages.
- `/etc/blackgate/blackgate.env` (`0600 root:root`) — API credentials and the release cookie. They are
  deliberately **not** in the unit file: unit files are world readable.
- `/etc/blackgate/update-private-key.pem` (`0600`) and `update-public-key.pem` (`0644`) — the Ed25519
  pair used to sign and verify update packages. Keep the private key off the appliance when you can.
- `$ROOT/{releases,incoming,backups}` and, with `--tarball`, the first release plus the `current`
  symlink.

Two things the installer cannot guess:

- **`--data-dir` must point at the directory that already holds the Khepri database**, or the gateway
  comes up with an empty one and every route disappears. On a production appliance that is
  `/var/lib/blackgate/khepri`.
- If a node is already running outside systemd, the installer refuses to start the unit: stop it
  (`make stop`) first. Two nodes at once leave a stale `/tmp/hydra_unix_sock` and every engine fails
  to connect.

## Safety model

Every action is *scheduled*, never executed inline:

```
dashboard → POST /api/system/actions/reboot
          → sudo -n /usr/local/libexec/blackgate-system-action reboot
          → systemd-run --on-active=10s --unit=blackgate-dashboard-reboot systemctl reboot
```

- Restart: 3 s delay. Reboot and shutdown: 10 s. Deploy: 2 s. Deploy also hands off to the updater.
- The delay is the cancel window: `blackgate-system-action cancel blackgate-dashboard-reboot` stops
  the transient timer, and the dashboard shows a Cancel button while an action is pending.
- Reboot and shutdown require typing the action back in the confirmation dialog; deploy requires the
  version.
- Every scheduled action is written to Events (`system_action`) with its argument, so a reboot from
  the dashboard leaves a trace next to route and SDI events.
- Without the helper and the sudoers drop-in the dashboard disables the buttons and says why. Without
  the systemd unit, Restart is additionally unavailable: a hand-started node carries its environment
  in the shell that launched it, and there is no safe way to restart it.

## Prove the plumbing without rebooting anything

```bash
sudo /usr/local/libexec/blackgate-system-action test-action
systemctl is-active blackgate-dashboard-test.timer      # active
sudo /usr/local/libexec/blackgate-system-action cancel blackgate-dashboard-test
systemctl is-active blackgate-dashboard-test.timer      # inactive
```

`test-action` schedules `/bin/true` through exactly the same path as reboot, so a successful run
proves sudoers, `systemd-run` and cancel all work.

## Update packages

A package is a tar.gz named `<version>.bgupdate` with four members:

```
manifest.txt              product=blackgate version=<v> platform=ubuntu-24.04-amd64
                          release_sha256=<sha> updater_sha256=<sha>
manifest.sig              Ed25519 signature over manifest.txt
blackgate-release.tar.gz  the OTP release, priv/release-notes.json baked in
blackgate-updater         the root updater, so an old appliance can update itself
```

Build one (the version comes from `iso-builder/release-version` unless you pass one):

```bash
scripts/package-signed-update.sh                    # → dist/<version>.bgupdate
scripts/package-signed-update.sh 2026.11.01.1 /path/to/update-private-key.pem /tmp/out
```

Notes: the script runs `make build` first, and `mix release` rebuilds the Rust engine into the release
(`mix.exs` `copy_native/1`), so an engine change ships with the package automatically.
`iso-builder/release-notes.txt`, when present, becomes the "What changed" list in the dashboard;
otherwise the last twelve commit subjects are used.

Deploy, from the dashboard (Software Update → Upload → Deploy) or by hand:

```bash
sudo install -o blackgate -g blackgate -m 0644 dist/2026.11.01.1.bgupdate /opt/blackgate/incoming/
# then Deploy in the UI, or:
sudo /usr/local/libexec/blackgate-system-action deploy 2026.11.01.1
cat /run/blackgate-update-status        # verifying: … / deploying: … / deployed: … / failed: …
```

What the updater does, in order: verify the signature against `update-public-key.pem`, check
`product`/`version`/`platform`, check the release's sha256, unpack into `releases/<version>`, swap
`current` atomically (`current.next` + `mv -Tf`), `systemctl restart blackgate.service`, wait, and if
the service is not active **roll back** to the previous release and restart. It keeps the newest five
releases and backs up the updater before replacing it.

A version whose directory already exists is treated as a rollback to that release — that is what the
"Roll back to this" button does.

## Operational notes

- **Routes stop on restart and on deploy.** A clean shutdown writes `stopped` into Khepri and nothing
  resumes them at boot, so start them again from Routes afterwards. The confirmation dialogs say so.
- A deploy restarts the service, so the dashboard page is interrupted for a few seconds; it resumes
  and the deploy status keeps updating while the updater works.
- `$ROOT/incoming` keeps the newest five packages; uploads are streamed to a `.part` file and only
  renamed once complete, and a file that is not a gzip archive is refused (an HTML error page saved as
  `.bgupdate` is the classic mistake).
- Migrating a legacy `/opt/blackgate` install (release unpacked directly in the root) to the
  releases/current layout: `iso-builder/files/blackgate-update-bootstrap`.

## Troubleshooting

| Symptom | Where to look |
| --- | --- |
| Buttons greyed out, "helper is not installed" | `scripts/install-system-actions.sh` has not been run, or its files were removed |
| `sudo: a password is required` in the body of a 422 response | the sudoers drop-in is missing or has the wrong mode (`0440 root:root`); re-run the installer |
| Deploy fails with `signature verification failed` | the package was signed with a different key than `/etc/blackgate/update-public-key.pem` |
| Deploy fails with `platform rejected` | the manifest was not built for `ubuntu-24.04-amd64` |
| Deploy ends in `failed: new release failed; rolled back` | the new release did not become active within ~8 s: check `journalctl -u blackgate.service`, then the release's own logs |
| Upload returns "cannot use /opt/blackgate/incoming" | the gateway's `BLACKGATE_ROOT` and the installed root disagree, or the directory is not writable by the service user |
