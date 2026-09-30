# Blackgate Server Appliance

Builds a bootable **Ubuntu 24.04 (Noble) Server** ISO appliance containing the
native Blackgate OTP release.

## How to Build

### Build locally

Required host tools: `apt-get`, `dpkg-scanpackages`, `dosfstools`, and
`rsync`. When `xorriso` is absent, builder stages private copy automatically.

```bash
./build.sh
```

Default inputs are discovered next to the project directory. Override them when
needed:

```bash
BLACKGATE_SOURCE_ISO=/path/to/ubuntu-24.04.4-live-server-amd64.iso \
./build.sh
```

Output: `output/blackgate-installer-amd64.iso`

First build downloads Ubuntu dependency closure into
`cache/offline-packages/`. Generated installer then installs Ubuntu,
GStreamer, and Blackgate without
Internet access. The installer forces Ubuntu's offline fallback even when a LAN
cable with Internet is connected. Later builds reuse package cache.

## What's Inside the ISO
| Component | Details |
|-----------|---------|
| **OS** | Ubuntu 24.04 (Noble) CLI; offline autoinstall |
| **Engine** | Native Elixir/OTP release + C/GStreamer pipeline |
| **Packages** | Local APT repository with runtime dependency closure |
| **SSH** | Enabled |
| **Boot** | systemd starts Blackgate after first-boot provisioning |

## Default Credentials
| Service | User | Password |
|---------|------|----------|
| Dashboard | admin | password123 |
| SSH       | blackgate | blackgate123 |

> ⚠️ **Change these after first login!**

## Managing Blackgate on the Appliance
Blackgate runs as a systemd service from `/opt/blackgate/current`. Future
signed dashboard updates are installed beneath `/opt/blackgate/releases/`.
```bash
sudo journalctl -u blackgate -f
sudo systemctl restart blackgate
sudo systemctl stop blackgate
```

## Migrating a Source Installation

Gateways currently running from a source checkout such as
`/home/woi/blackgate-project` require one-time migration before dashboard
updates work. Build a source migration bundle with:

```bash
scripts/package-source-appliance-bootstrap.sh VERSION output
```

See [`docs/source-appliance-migration.md`](../docs/source-appliance-migration.md)
for checksum verification, read-only preflight, confirmed migration, rollback,
and post-migration checks.
