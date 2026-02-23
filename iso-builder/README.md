# Blackgate Server (Docker Appliance)

Builds a bootable **Ubuntu 22.04 (Jammy) Server** ISO appliance that natively auto-starts Blackgate securely inside a Docker container using host networking.

## How to Build

### Option 1: GitHub Actions (Recommended)

Push a version tag to trigger an automatic build:
```bash
git tag v1.0.0
git push origin v1.0.0
```

### Option 2: Build Locally (requires Linux with Docker)
```bash
chmod +x build.sh
VERSION=1.0.0 ./build.sh
```

Output: `output/blackgate-1.0.0-amd64.iso`

## What's Inside the ISO
| Component | Details |
|-----------|---------|
| **OS** | Ubuntu 22.04 (Jammy) CLI |
| **Engine** | `docker` + `docker compose` running `blackgate/app:latest` |
| **SSH** | Enabled, root login disabled |
| **Boot** | `docker load` & `docker compose up` run automatically |

## Default Credentials
| Service | User | Password |
|---------|------|----------|
| Dashboard | admin | password123 |
| SSH       | blackgate | blackgate123 |

> ⚠️ **Change these after first login!**

## Managing Blackgate on the Appliance
Blackgate runs via Docker Compose in `/opt/blackgate`.
```bash
cd /opt/blackgate

# View live logs
docker compose logs -f

# Restart Blackgate
docker compose restart

# Stop Blackgate
docker compose down
```
