# Blackgate Ubuntu 24.04 LTS Appliance

Builds a bootable Ubuntu 24.04 LTS (Noble) amd64 installer. Installed gateways
run Blackgate directly as a systemd-managed OTP release with bundled ERTS and
the Rust media engine. Docker is not installed or required at runtime.

## Build contract

- Ubuntu source ISO: `ubuntu-24.04.4-live-server-amd64.iso`
- Erlang/OTP: 27.0.1
- Elixir: 1.18.2
- Node.js: 20.19.0
- Rust: 1.96.0
- GStreamer: Ubuntu Noble 1.24 runtime plus bundled DeckLink plugin

GitHub Actions installs these exact toolchains and downloads source ISO. For a
local build, place source ISO beside `build.sh`, install dependencies listed in
`.github/workflows/build-iso.yml`, then run:

```bash
VERSION=1.0.0 ./iso-builder/build.sh
```

Output: `iso-builder/output/blackgate-installer-amd64.iso`.

## Installed layout

| Component | Details |
| --- | --- |
| OS | Ubuntu 24.04 LTS amd64, bare metal |
| Application | `/opt/blackgate`, systemd service `blackgate` |
| Media engine | Rust `blackgate-engine` bundled inside OTP release |
| Database | Khepri data under `/var/lib/blackgate/khepri` |
| DeckLink | Bundled GStreamer 1.24 DeckLink plugin |
| Network | DHCP, 16 MiB UDP send/receive buffer ceiling |

## Default credentials

| Service | User | Password |
| --- | --- | --- |
| Dashboard | admin | password123 |
| SSH | blackgate | blackgate123 |

Change both passwords after installation.

## Operations

```bash
sudo systemctl status blackgate
sudo journalctl -u blackgate -f
sudo systemctl restart blackgate
```

Physical DeckLink/SDI validation remains manual release sign-off step.
