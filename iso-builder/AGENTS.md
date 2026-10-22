# Ubuntu Appliance Packaging (`iso-builder/`)

This folder builds Blackgate bare-metal installer.

## Contract

- Base OS: Ubuntu 24.04 LTS (Noble), amd64 live-server ISO.
- Runtime: systemd-managed OTP release with bundled ERTS.
- Media runtime: Rust-only `blackgate-engine`; archived C code is never shipped.
- Database: Khepri at `/var/lib/blackgate/khepri`.
- Delivery: SRT/UDP only. No SDI plugin and no Blackmagic driver in the image.
- Docker: allowed for development and CI image checks, never required by
  installed appliance.

## Shipped system integration

`files/` carries the artifacts that give the dashboard its privileged surface. First boot installs
them through `scripts/install-system-actions.sh` (shipped as
`/opt/blackgate/blackgate-install-system-actions.sh`, run with `BLACKGATE_ARTIFACT_DIR=/opt/blackgate/files`):

- `files/blackgate.service` — unit running `/opt/blackgate/current`; credentials come from
  `/etc/blackgate/blackgate.env` (0600 root), never from the world-readable unit.
- `files/blackgate-system-action` (+ `.sudoers`) — the only privileged path, allowlisted and delayed.
- `files/blackgate-updater` — verifies and applies signed `.bgupdate` packages, with automatic rollback.
- `files/release-version` — the release version the packaging and update paths agree on.
- `files/blackgate-update-bootstrap` — moves a legacy `/opt/blackgate` install to the releases/current
  layout.

Packages are built by `scripts/package-signed-update.sh` (Ed25519 keypair generated at install time in
`/etc/blackgate/`). Runbook: `docs/operations/system-actions-and-updates.md`.

The ISO also carries an apt pool (`files/pool/`, built from `packages.list`) and `packages:` in
`autoinstall/user-data` is deliberately empty, so an install needs no network at all: first boot installs
the runtime packages from the pool. `LICENSE_SERVER_URL` travels the same way. See README.md for the
offline install path.

## Build and checks

```bash
VERSION=1.0.0 ./iso-builder/build.sh
bash -n iso-builder/build.sh
bash -n iso-builder/files/blackgate-firstboot.sh
```

Build requires Linux plus exact toolchains and packages declared in
`.github/workflows/build-iso.yml`. Never modify or build on remote gateway;
diagnostics there remain read-only and deployments remain manual.
