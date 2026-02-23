# Blackgate Troubleshooting Guide

A quick reference guide when something goes wrong. No technical jargon — just step-by-step fixes.

---

## 🔴 Stream Not Starting

**Symptoms**: You click "Start" on a route but nothing happens, or the status stays "stopped".

**What to do:**
1. Check that the **source port** is not already used by another route
2. Make sure the source address and port are filled in correctly
3. If using **SRT Listener** mode — the encoder must connect *after* you start the route
4. If using **SRT Caller** mode — make sure the remote server is already running and reachable
5. Try clicking **Stop**, wait 3 seconds, then click **Start** again

**Still not working?**
- Restart the Blackgate service:
  ```
  docker compose restart
  ```
  or (baremetal):
  ```
  make restart
  ```

---

## 🟡 Video Has Artifacts / Macroblocking

**Symptoms**: The video output shows fuzzy squares (macroblocks), freezes, or loops the same few seconds.

**What to do:**
1. **Check your source stream first** — open the source directly in VLC to confirm it's clean
2. Check the **Packet Loss** stat on the route detail page:
   - Below 0.1% → Normal
   - 0.1% - 1% → Network issues, increase SRT latency to 500-1000ms
   - Above 1% → Serious network problem, check the connection between source and Blackgate
3. Check the **RTT (Round Trip Time)**:
   - Below 50ms → Good
   - 50-200ms → Increase SRT latency to at least 2x the RTT value
   - Above 200ms → The connection may be too slow for reliable streaming
4. **Restart the affected route** — Stop → wait 3 seconds → Start

**If it happens again after a few days:**
- This is a known issue with long-running streams. Restart the route periodically (e.g., during off-peak hours) until a fix is released.

---

## 🔴 Can't Log In to Dashboard

**Symptoms**: Login page shows "Invalid username or password" even with correct credentials.

**What to do:**
1. Default credentials are: `admin` / `password123`
2. If you changed the credentials, check your environment variables:
   - Docker: look at `docker-compose.yml` → `API_AUTH_USERNAME` and `API_AUTH_PASSWORD`
   - Baremetal: check the `Makefile` or your startup script
3. Clear your browser cache or try in an incognito/private window
4. Restart the service — this resets all login sessions

---

## 🔴 Dashboard Not Loading

**Symptoms**: Browser shows a blank page, error page, or "connection refused".

**What to do:**
1. **Check if Blackgate is running:**
   ```
   docker compose ps
   ```
   or (baremetal):
   ```
   make status
   ```
2. If it's not running, start it:
   ```
   docker compose up -d
   ```
   or:
   ```
   make start
   ```
3. Make sure you're using the right URL:
   - Docker: `http://YOUR_SERVER_IP:4000`
   - Development: `http://localhost:5173`
4. Check if another service is using port 4000

---

## 🟡 No Statistics Showing

**Symptoms**: Route is started and stream is flowing, but stats page shows "No stats available" or all zeros.

**What to do:**
1. Wait 5-10 seconds after starting the route — stats take a moment to appear
2. Make sure the **source encoder is actually sending** data (check the encoder side)
3. If using SRT Listener mode — confirm a caller has connected (check "Connected Callers" count)
4. Refresh the browser page
5. If still no stats, stop and restart the route

---

## 🔴 Destination Not Receiving Stream

**Symptoms**: Source is connected and stats are showing, but the destination player shows nothing.

**What to do:**
1. **Check the destination status** on the route detail page — is it showing errors?
2. Verify the destination settings:
   - For **SRT Listener** destination → the receiver (VLC, OBS, etc.) must connect as Caller
   - For **SRT Caller** destination → the remote server must be listening first
3. Make sure the **destination port** is not blocked by a firewall
4. If using a **passphrase** — make sure both sides use the exact same passphrase and key length
5. Try removing the destination and adding it again with the same settings

---

## 🟡 High CPU or Memory Usage

**Symptoms**: Server is slow, other services affected, or Blackgate is using too many resources.

**What to do:**
1. Check how many routes are running — each active route uses one native process
2. Go to the **Dashboard** page to see system CPU and memory
3. Stop any routes you don't need right now
4. If a single route is using excessive resources:
   - Stop and restart that specific route
   - Check if the source stream has an unusually high bitrate

**Rule of thumb**: Each active stream uses ~15-30 MB of memory. A server with 8 GB RAM can handle ~200+ simultaneous streams.

---

## 🔴 Service Won't Start After Server Reboot

**Symptoms**: After rebooting the server, Blackgate doesn't come back online.

**What to do:**
1. For Docker — make sure Docker itself is running:
   ```
   sudo systemctl start docker
   ```
2. Start Blackgate:
   ```
   docker compose up -d
   ```
3. If the database seems corrupted (error messages about Khepri):
   - Restore from backup: go to the dashboard → Settings → Import backup
   - Or if you have a backup file, use the API:
     ```
     curl -X POST http://localhost:4000/api/restore -H "Authorization: Bearer YOUR_TOKEN" --data-binary @backup.bin
     ```

---

## 🟢 Routine Maintenance

### Restarting the Service
```
# Docker
docker compose restart

# Baremetal
make restart
```

### Creating a Backup
1. Go to Dashboard → click the backup/export option
2. Save the downloaded file somewhere safe
3. Do this **before** any updates or server changes

### Updating Blackgate
```
# 1. Pull latest code
git pull origin main

# 2. Rebuild and restart
docker compose build --no-cache
docker compose up -d
```

### Checking Logs
```
# Docker - live logs
docker compose logs -f

# Docker - last 100 lines
docker compose logs --tail=100
```

---

## 📞 When to Escalate

Contact the engineering team if:
- The service crashes repeatedly (restarts more than 3 times in a row)
- You see database errors in the logs mentioning "Khepri" or "Raft"
- Streams work locally but fail across networks (possible firewall/NAT issue)
- You need to configure clustering or advanced SRT settings
