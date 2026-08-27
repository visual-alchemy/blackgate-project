# Ubuntu Appliance Packaging (`iso-builder/`)

This folder builds Blackgate bare-metal installer.

## Contract

- Base OS: Ubuntu 24.04 LTS (Noble), amd64 live-server ISO.
- Runtime: systemd-managed OTP release with bundled ERTS.
- Media runtime: Rust-only `blackgate-engine`; archived C code is never shipped.
- Database: Khepri at `/var/lib/blackgate/khepri`.
- DeckLink: GStreamer 1.24 plugin built during ISO creation and installed with
  appliance.
- Docker: allowed for development and CI image checks, never required by
  installed appliance.

## Build and checks

```bash
VERSION=1.0.0 ./iso-builder/build.sh
bash -n iso-builder/build.sh
bash -n iso-builder/files/blackgate-firstboot.sh
```

Build requires Linux plus exact toolchains and packages declared in
`.github/workflows/build-iso.yml`. Never modify or build on remote gateway;
diagnostics there remain read-only and deployments remain manual.
