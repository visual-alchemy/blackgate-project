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

## Credentials and access

There is no fixed default password on this appliance, and nothing key-only uses one.

| Door | How in |
| --- | --- |
| Dashboard | user `admin`, random password written on first boot to `/home/blackgate/blackgate-dashboard-credentials.txt` (0640, root:blackgate). The console also prints it before login. |
| SSH (support) | key-only: `root` and `bg-support`, with the private counterpart of `files/support-authorized-keys`. `bg-support` has sudo; the application user `blackgate` does not. |
| Break-glass root | random password in `/root/blackgate-root-password.txt` (0600), physical console only — root SSH is `prohibit-password`, so this never crosses the network. |

Replace `files/support-authorized-keys` with the key you intend to use before building an image for a client.

The license endpoint travels with the image. `build.sh` takes `LICENSE_SERVER_URL` from the environment or the
repository `Makefile` and writes it as `/blackgate/license-server-url`; the installer's late-commands put it in
`/opt/blackgate/files/`, and `install-system-actions.sh` resolves it in this order: env var, that file, the
Makefile. Empty leaves `config/runtime.exs` on `http://localhost:3000`, so the dashboard cannot activate a
license - which is how a client appliance used to arrive. The license *key* is per client and never baked: it
is entered in the dashboard.

## Operations

```bash
sudo systemctl status blackgate
sudo journalctl -u blackgate -f
sudo systemctl restart blackgate
```

## Offline install

The image installs with no network at all. `packages:` in `autoinstall/user-data` is deliberately empty: any
entry there makes curtin fetch from the Ubuntu archive, which is what used to force an install to have network.

The runtime packages are listed in `packages.list` (committed, single source of truth). `build.sh` resolves the
full apt closure of that list and downloads it into `files/pool/`, indexed by `dpkg-scanpackages` as
`Packages.gz`. The installer's late-commands copy the pool to `/opt/blackgate/pool` and register it as
`deb [trusted=yes] file:///opt/blackgate/pool ./`; `blackgate-firstboot.sh` installs from it, and falls back to
the archive when the pool is absent. That install happens on first boot, not during the install, which is what
keeps the installer off the network.

The closure is resolved against an EMPTY dpkg status on purpose: against the build machine's own status apt
answers "already installed" and the pool comes out megabytes short of what a fresh machine needs.

Pool size: 607 packages, ~380 MB (it includes the base closure apt would pull for a fresh system), so the
image is about 4.5 GB.

Adding a runtime package: add it to `packages.list` and rebuild. Never add `packages:` back to the autoinstall.

Verify a build with the archive irrelevant:

```bash
xorriso -osirrox on -indev output/blackgate-installer-amd64.iso -extract /blackgate /tmp/iso-check
ls /tmp/iso-check/blackgate/pool | wc -l            # 608 = 607 .deb + Packages.gz
wc -l /tmp/iso-check/blackgate/packages.list        # 22
```

Physical DeckLink/SDI validation remains manual release sign-off step.
