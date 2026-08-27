# SRT Failover Integration Test — Runbook

End-to-end procedure for verifying Blackgate's primary/secondary SRT failover
using the `docker-compose.failover.yml` harness.

Harness image contains production Rust-only engine. GitHub migration CI runs
same functional contract on Ubuntu 24.04 LTS.

The harness runs **two ffmpeg emitters** (`emitter-a`, `emitter-b`) that push
MPEG-TS test patterns as SRT callers into two Blackgate SRT listeners
(ports `12100` and `12101`). You then create a single failover route whose
**primary** source listens on `12100` and **secondary** source listens on
`12101`, and observe the route automatically switching sources when one emitter
is killed.

```
emitter-a --SRT caller--> blackgate:12100 (primary listener)   ┐
                                                               ├─> failover route
emitter-b --SRT caller--> blackgate:12101 (secondary listener) ┘
```

---

## Prerequisites

| Tool | Why | Check |
|------|-----|-------|
| Docker Engine 24+ | Container runtime | `docker version` |
| Docker Compose v2 | Merge base + override file | `docker compose version` |
| `curl` | HTTP API calls | `curl --version` |
| `jq` | Parse JSON / extract token + route id | `jq --version` |

You also need the Blackgate image built locally (the base compose file
`build:`es it):

```bash
docker compose -f docker-compose.yml build blackgate
```

Default API credentials (from `docker-compose.yml`): **admin / password123**.

---

## 1. Startup

Bring up Blackgate plus both emitters:

```bash
docker compose -f docker-compose.yml -f docker-compose.failover.yml up -d
```

Wait for Blackgate to finish boot, then confirm all three services are running:

```bash
docker compose -f docker-compose.yml -f docker-compose.failover.yml ps
```

Expected: `blackgate`, `emitter-a`, `emitter-b` all `Up`.

Sanity-check the API is reachable:

```bash
curl -s http://localhost:4000/api/login \
  -H "Content-Type: application/json" \
  -d '{"login":{"user":"admin","password":"password123"}}' | jq .
```

Expected: `{"token": "...", "user": "admin"}`.

> The emitters use `restart: unless-stopped`, so they will keep retrying the
> SRT connection until Blackgate's listeners are bound. Transient connection
> refused errors in the emitter logs during boot are normal.

---

## 2. Authenticate — capture a Bearer token

All subsequent calls need an `Authorization: Bearer <token>` header. Capture it
once into a shell variable:

```bash
TOKEN=$(curl -s -X POST http://localhost:4000/api/login \
  -H "Content-Type: application/json" \
  -d '{"login":{"user":"admin","password":"password123"}}' \
  | jq -r .token)

echo "token: $TOKEN"
```

---

## 3. Create the failover route

Create one route with a primary SRT **listener** on `12100` and a secondary SRT
**listener** on `12101`, failover enabled, mode `maintain-stability` (toggles
to the other source on each failure — best mode for exercising failover):

```bash
curl -s -X POST http://localhost:4000/api/routes \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "route": {
      "name": "failover-test",
      "enabled": true,
      "schema": "SRT",
      "schema_options": {
        "mode": "listener",
        "localaddress": "0.0.0.0",
        "localport": 12100,
        "latency": 125,
        "auto-reconnect": true,
        "keep-listening": true
      },
      "failover_enabled": true,
      "failover_mode": "maintain-stability",
      "active_source": "primary",
      "secondary_source": {
        "schema": "SRT",
        "schema_options": {
          "mode": "listener",
          "localaddress": "0.0.0.0",
          "localport": 12101,
          "latency": 125,
          "auto-reconnect": true,
          "keep-listening": true
        }
      }
    }
  }' | jq .
```

Capture the route id from the response:

```bash
ROUTE_ID=$(curl -s http://localhost:4000/api/routes \
  -H "Authorization: Bearer $TOKEN" \
  | jq -r '.data[] | select(.name=="failover-test") | .id')

echo "route id: $ROUTE_ID"
```

> If `jq -r '.data[]'` is empty, inspect the raw list: `... | jq .`. The list
> key is `data`; each item's `id` is the route handle used below.

---

## 4. Start the route

```bash
curl -s "http://localhost:4000/api/routes/$ROUTE_ID/start" \
  -H "Authorization: Bearer $TOKEN" | jq .
```

Expected: `{"data": {"status": "started", "route_id": "<id>"}}`.

---

## 5. Verify streaming on the primary source

Give the pipeline ~5 seconds to bind the SRT listener and accept `emitter-a`'s
caller connection, then inspect the route:

```bash
sleep 5

curl -s "http://localhost:4000/api/routes/$ROUTE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  | jq '{status, active_source, schema, failover_enabled, failover_mode}'
```

Expected:

```json
{
  "status": "started",
  "active_source": "primary",
  "schema": "SRT",
  "failover_enabled": true,
  "failover_mode": "maintain-stability"
}
```

Confirm bytes are actually flowing on the primary (bitrate > 0 means the emitter
is connected and streaming):

```bash
curl -s "http://localhost:4000/api/routes/$ROUTE_ID/stats" \
  -H "Authorization: Bearer $TOKEN" | jq .
```

> Visual verification: open the Blackgate web UI at
> [http://localhost:4000](http://localhost:4000), log in with
> `admin` / `password123`, and confirm the `failover-test` route shows a green
> **Connected** badge and a live preview from `emitter-a`.

---

## 6. Kill the primary emitter — trigger automatic failover

Stop `emitter-a` to simulate primary source loss:

```bash
docker compose -f docker-compose.yml -f docker-compose.failover.yml stop emitter-a
```

The failover state machine detects the lost source via the watchdog heartbeat
(default 60s) and, because `failover_mode` is `maintain-stability`, toggles the
active source to `secondary`. Poll until the switch is visible (usually within
~60s; allow up to 90s):

```bash
for i in $(seq 1 18); do
  STATE=$(curl -s "http://localhost:4000/api/routes/$ROUTE_ID" \
    -H "Authorization: Bearer $TOKEN" \
    | jq -r '{status, active_source} | tostring')
  echo "[$i] $STATE"
  echo "$STATE" | grep -q '"active_source":"secondary"' && break
  sleep 5
done
```

---

## 7. Verify failover to the secondary source

```bash
curl -s "http://localhost:4000/api/routes/$ROUTE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  | jq '{status, active_source, failover_mode}'
```

Expected:

```json
{
  "status": "started",
  "active_source": "secondary",
  "failover_mode": "maintain-stability"
}
```

The route stays `started` and is now fed by `emitter-b` (port `12101`).
Confirm secondary bytes are flowing:

```bash
curl -s "http://localhost:4000/api/routes/$ROUTE_ID/stats" \
  -H "Authorization: Bearer $TOKEN" | jq .
```

---

## 8. Manually switch back to the primary

Restart the primary emitter so there is a stream to come back to, then invoke
the manual switch-source endpoint:

```bash
docker compose -f docker-compose.yml -f docker-compose.failover.yml start emitter-a

# wait for emitter-a to re-establish its SRT caller connection
sleep 5

curl -s -X POST "http://localhost:4000/api/routes/$ROUTE_ID/switch-source" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"target":"primary"}' | jq .
```

Expected: `{"data": {"status": "switched", "active_source": "primary"}}`.

> `switch-source` rejects with `400` if the route has `failover_enabled != true`,
> or if `target` is anything other than `"primary"` / `"secondary"`.

---

## 9. Verify the manual switch

```bash
curl -s "http://localhost:4000/api/routes/$ROUTE_ID" \
  -H "Authorization: Bearer $TOKEN" \
  | jq '{status, active_source}'
```

Expected:

```json
{
  "status": "started",
  "active_source": "primary"
}
```

---

## 10. Cleanup

Tear down all services and remove volumes (this deletes the Khepri DB, so the
test route is wiped):

```bash
docker compose -f docker-compose.yml -f docker-compose.failover.yml down -v
```

To keep the database between runs, drop `-v`.

---

## Troubleshooting

### `emitter-a` / `emitter-b` log `Connection refused`

The emitter tried to connect before Blackgate bound the SRT listener. This is
expected during startup; `restart: unless-stopped` retries automatically. If it
persists after ~30s:

- Confirm Blackgate is up: `docker compose ... ps blackgate`
- Confirm the route is **started** (a listener port is only bound once the
  route's pipeline is running): see step 4.
- Confirm the route's `localport` (`12100` / `12101`) matches the emitter's
  destination port.

### Failover never triggers after `docker stop emitter-a`

- Verify `failover_enabled` is JSON `true` (boolean), not the string `"true"`:
  ```bash
  curl -s "http://localhost:4000/api/routes/$ROUTE_ID" \
    -H "Authorization: Bearer $TOKEN" | jq '.failover_enabled, .schema'
  ```
  Failover only activates when `failover_enabled == true` **and**
  `schema == "SRT"` **and** `secondary_source` is a non-empty map.
- The watchdog heartbeat runs on a ~60s cadence. Failover is not instant —
  allow up to 90s after stopping the emitter.
- `keep-listening: true` keeps the listener socket open after the caller drops,
  which is required so the secondary emitter can re-call in. Make sure both
  sources set it.

### `switch-source` returns `400 Failover is not enabled for this route`

The route was created without `failover_enabled: true`. Recreate it (step 3) or
`PUT /api/routes/$ROUTE_ID` with the corrected fields.

### `switch-source` returns `422` / `not_found`

The route is not currently running. Start it first (step 4); `switch-source`
only targets live routes.

### Port `12100` / `12101` / `4000` already in use on the host

Another process (or a previous run) is bound to the port:
```bash
lsof -iTCP:12100 -sTCP:LISTEN   # macOS
ss -ltnp 'sport = :12100'       # Linux
```
Either stop the other process or remap the published port in
`docker-compose.failover.yml` (and match the new port in the emitter `srt://`
URL).

### Blackgate fails to start: `device ... not found`

You are running an older base image or a different override that re-introduces
the `devices:` passthrough. `docker-compose.failover.yml` already resets
`devices:` for this exact reason — make sure it is the **second** `-f` argument
so it takes precedence:
```bash
docker compose -f docker-compose.yml -f docker-compose.failover.yml up -d
```

### Emitters connect but `stats` shows bitrate `0`

The SRT handshake completed but no MPEG-TS frames are flowing. Check the
emitter logs for ffmpeg encode errors:
```bash
docker compose -f docker-compose.yml -f docker-compose.failover.yml logs emitter-a
```
`mwader/static-ffmpeg` includes `libx264`; if you switched images and the codec
is missing, swap `-c:v libx264` for `-c:v mpeg2video` in the emitter commands.

### Token works once then 401s

Tokens are cached server-side for 14 days. If you ran `down -v`, the cache was
wiped — just re-login (step 2) to mint a fresh `$TOKEN`.
