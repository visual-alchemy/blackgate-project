# Source Installation to Appliance Layout

Use this one-time migration for gateways whose `blackgate.service` currently
runs from a source checkout such as `/home/woi/blackgate-project`.

Do not use the older `blackgate-bootstrap-install` workflow for this layout. It
expects an existing `/opt/blackgate` installation.

## Build Trusted Bundle

On the release-build machine, check out the intended branch and run:

```bash
scripts/package-source-appliance-bootstrap.sh VERSION output
```

Example:

```bash
scripts/package-source-appliance-bootstrap.sh 2026.09.15.1 output
```

This builds Blackgate and creates:

```text
output/blackgate-source-bootstrap-2026.09.15.1.tar.gz
```

## Transfer and Verify

Copy the archive and its separately recorded SHA-256 value to the gateway.
Verify the archive before extraction. After extraction, verify all bundled
files:

```bash
sha256sum -c SHA256SUMS
```

## Run Migration

Run read-only preflight from the unpacked bundle:

```bash
./blackgate-source-bootstrap-install \
  --check \
  /home/woi/blackgate-project \
  legacy-1.0.0
```

After preflight passes, stop route changes and run migration:

```bash
sudo ./blackgate-source-bootstrap-install \
  --confirm \
  /home/woi/blackgate-project \
  legacy-1.0.0
```

When multiple `khepri*` directories exist beneath the source root, pass the
active directory explicitly:

```bash
sudo ./blackgate-source-bootstrap-install \
  --confirm \
  /home/woi/blackgate-project \
  legacy-1.0.0 \
  '/home/woi/blackgate-project/khepri#blackgate@127.0.0.1'
```

Migration performs these operations:

1. Validates source release, database, systemd unit, updater files, and version.
2. Creates dedicated `blackgate` service user when needed.
3. Stages release beneath `/opt/blackgate/releases/VERSION` before downtime.
4. Stops `blackgate.service`.
5. Creates cold Khepri backup and copies data into `/var/lib/blackgate/khepri`.
6. Removes legacy-user preview files before starting dedicated service user.
7. Installs updater helper, sudo policy, and update verification public key.
8. Creates `/opt/blackgate/current` and standardized systemd unit.
9. Starts service and waits for active state.
10. Restores previous service unit automatically if migration fails after stop.

Source checkout and source database remain untouched for manual recovery.

## Verify

```bash
systemctl status blackgate.service
readlink /opt/blackgate/current
journalctl -u blackgate.service -n 100 --no-pager
```

Dashboard System page should show calendar release version, eight DeckLink
nodes, and update status `idle`. Confirm routes, accounts, SDI outputs 1–8, and
failover before uploading a signed `.bgupdate` package.
