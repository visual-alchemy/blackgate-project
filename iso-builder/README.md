# Blackgate Server Appliance

Builds a bootable **Ubuntu 24.04 (Noble) Server** ISO appliance containing the
native Blackgate OTP release, Blackmagic Desktop Video 16.0.1 driver, and
headless DeckLink Duo 2 connector-profile configuration.

## How to Build

### Build locally

Required host tools: `apt-get`, `dpkg-scanpackages`, `dosfstools`, `rsync`, and
`g++`. When `xorriso` is absent, builder stages private copy automatically.

```bash
./build.sh
```

Default inputs are discovered next to the project directory. Override them when
needed:

```bash
BLACKGATE_SOURCE_ISO=/path/to/ubuntu-24.04.4-live-server-amd64.iso \
BLACKGATE_DESKTOPVIDEO_DEB=/path/to/desktopvideo_16.0.1a2_amd64.deb \
./build.sh
```

Output: `output/blackgate-installer-amd64.iso`

First build downloads Ubuntu dependency closure into
`cache/offline-packages/`. Generated installer then installs Ubuntu,
GStreamer, DKMS, matching kernel headers, Desktop Video, and Blackgate without
Internet access. The installer forces Ubuntu's offline fallback even when a LAN
cable with Internet is connected. Later builds reuse package cache.

## What's Inside the ISO
| Component | Details |
|-----------|---------|
| **OS** | Ubuntu 24.04 (Noble) CLI; offline autoinstall |
| **Engine** | Native Elixir/OTP release + C/GStreamer pipeline |
| **Packages** | Local APT repository with runtime and DKMS dependency closure |
| **DeckLink** | Desktop Video 16.0.1; first boot rebuilds DKMS for installed kernel, then activates Duo 2 `2dhd` |
| **SSH** | Enabled |
| **Boot** | systemd starts Blackgate after first-boot provisioning |

With `2dhd`, four GStreamer devices drive four independent outputs. Duo 2
enumeration order is `device 0 → SDI 1`, `device 1 → SDI 3`,
`device 2 → SDI 2`, and `device 3 → SDI 4`. Frontend mapping presents ports in
physical SDI 1–4 order.

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
