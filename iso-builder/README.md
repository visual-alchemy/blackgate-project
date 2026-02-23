# Blackgate ISO Builder

Builds a bootable Debian 12 ISO appliance with Blackgate SRT Gateway pre-installed.

## How to Build

### Option 1: GitHub Actions (Recommended)

Push a version tag to trigger an automatic build:

```bash
git tag v1.0.0
git push origin v1.0.0
```

The ISO will appear in **GitHub Releases** after ~15 minutes.

You can also manually trigger a build from **Actions → Build Blackgate ISO → Run workflow**.

### Option 2: Build Locally (requires Linux)

```bash
chmod +x build.sh
VERSION=1.0.0 ./build.sh
```

Output: `output/blackgate-1.0.0-amd64.iso`

## What's Inside the ISO

| Component | Details |
|-----------|---------|
| **OS** | Debian 12 (Bookworm) minimal, CLI only |
| **Blackgate** | Pre-compiled Elixir release + C pipeline |
| **GStreamer** | 1.0 with good/bad plugins |
| **SRT** | libsrt 1.5 (OpenSSL) |
| **SSH** | Enabled, root login disabled |
| **Network** | DHCP on all interfaces |
| **Boot** | Auto-starts Blackgate via systemd |

## Default Credentials

| Service | User | Password |
|---------|------|----------|
| Dashboard | admin | password123 |
| SSH / Console | blackgate | blackgate123 |

> ⚠️ **Change these after first login!**

## Client Installation Guide

1. **Download** the `.iso` from GitHub Releases
2. **Flash to USB** (or mount in VM):
   ```bash
   # USB (replace /dev/sdX with your USB device)
   sudo dd if=blackgate-1.0.0-amd64.iso of=/dev/sdX bs=4M status=progress
   
   # VirtualBox / QEMU — mount as CD-ROM and boot
   ```
3. **Boot** the machine from USB/CD
4. **Installer runs automatically** — wait for it to finish and reboot
5. **Login via console** with `blackgate` / `blackgate123`
6. **Find the IP** — shown on the console after boot:
   ```
   Blackgate SRT Gateway is running!
   Dashboard: http://192.168.1.50:4000
   SSH:       ssh blackgate@192.168.1.50
   ```
7. **Open dashboard** in browser → log in → activate license

## Managing Blackgate on the Appliance

```bash
# SSH into the appliance
ssh blackgate@<ip-address>

# Check status
sudo systemctl status blackgate

# View live logs
sudo journalctl -u blackgate -f

# Restart
sudo systemctl restart blackgate

# Stop
sudo systemctl stop blackgate
```

## File Locations on the Appliance

| Path | Contents |
|------|----------|
| `/opt/blackgate/` | Blackgate application |
| `/var/lib/blackgate/` | Data directory (Khepri DB) |
| `/var/lib/blackgate/khepri/` | Database files |

## Directory Structure

```
iso-builder/
├── build.sh                          # Main build script
├── README.md                         # This file
├── config/
│   ├── package-lists/
│   │   └── blackgate.list.chroot     # APT packages
│   ├── includes.chroot/              # Files for the ISO
│   │   ├── etc/
│   │   │   ├── systemd/system/blackgate.service
│   │   │   ├── ssh/sshd_config.d/99-blackgate.conf
│   │   │   ├── sysctl.d/99-blackgate.conf
│   │   │   ├── motd
│   │   │   └── issue
│   │   └── opt/blackgate/            # (populated during build)
│   └── hooks/live/
│       └── 0100-setup.hook.chroot    # Post-install user/service setup
└── output/                           # (generated) ISO output
```
