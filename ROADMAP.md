# Blackgate Roadmap

## 🔥 Quick Wins (Low Effort, High Impact)

### 1. ~~Bulk Start/Stop Routes~~ ✅
- [x] Add checkboxes to the routes table
- [x] Add "Start Selected" / "Stop Selected" buttons to the table toolbar
- [x] Backend: new endpoint `POST /api/routes/bulk-action` accepting `{ action: "start"|"stop", route_ids: [...] }`
- [x] Show progress indicator for bulk operations

### 2. ~~Route Duplication (Clone)~~ ✅
- [x] Add "Clone" button on route detail page and/or routes table
- [x] Backend: new endpoint `POST /api/routes/:id/clone` that copies route + destinations with a new name
- [x] Auto-name cloned route as `"{original_name} (Copy)"`
- [x] Cloned route starts in `stopped` state

### 3. ~~Delete Confirmation Modal~~ ✅ (already existed)
- [x] Add "Are you sure?" confirmation modal before deleting a route
- [x] Show route name in the modal for clarity
- [x] Same for destination deletion
- [x] Optional: show warning if the route is currently running

### 4. ~~Route Search & Filter~~ ✅
- [x] Add search input to the routes table (filter by name)
- [x] Add status filter dropdown (All / Running / Stopped)
- [x] Add schema filter (SRT / UDP)
- [x] Persist filter state across page navigation

---

## 🚀 Medium Effort, High Impact

### 5. ~~Live Video Preview~~ ✅
- [x] Decode incoming SRT stream server-side (GStreamer → JPEG thumbnails)
- [x] Serve thumbnail snapshots via API endpoint
- [x] Display live thumbnail on dashboard with auto-refresh
- [ ] Optional: WebRTC-based low-latency preview in browser

### 6. ~~Route Health Monitoring~~ ✅
- [x] Define health thresholds (packet loss > 2%/10%, RTT > 150ms/500ms, disconnected)
- [x] Add health status badge to dashboard preview cards (HealthBadge component)
- [x] Show health alert banner on the dashboard for warning/critical routes
- [x] Auto-detect disconnected callers (no signal = disconnected state)
- [x] Optional: health dot indicator in routes table

### 7. ~~WebSocket Live Stats~~ ✅
- [x] Replace polling-based stats with Phoenix Channels (Phoenix.PubSub + UserSocket + StatsChannel)
- [x] Push real-time bitrate, RTT, and packet loss to the frontend
- [x] Reduce server load (HTTP polling dropped from 1.5s to 3s fallback; WS handles live updates)
- [x] Hybrid fallback: HTTP on mount + WebSocket push for reliability

### 8. ~~Routes Table — Replace "Last Updated" with "Output" column~~ ✅
- [x] Remove "Last Updated" column (low-value for live monitoring)
- [x] Add "Output" column showing compact destination summary
  - SRT: `SRT:15000` (listener port)
  - UDP: `UDP:239.0.0.1:1234`
  - Multiple: `SRT:15000 (+2)` if many

### 9. ~~Event Log~~ ✅
- [x] `Blackgate.EventLog` GenServer — in-memory ring buffer (last 500 events) in ETS
- [x] Events emitted from RouteHandler: route started, stopped, crashed
- [x] API endpoints: `GET /api/events`, `GET /api/events/counts`, `DELETE /api/events`
- [x] Filter by severity (info/warning/critical), route_id, event type
- [x] New "Events" page in sidebar with severity badges and auto-refresh
- [ ] PubSub broadcast for real-time event push to frontend (WebSocket)
- [x] Connection lost/established events from stats monitoring
- [x] Health threshold events (high packet loss, high RTT, stream corruption)

### 10. Route Groups / Tags
- [ ] Add `tags` or `group` field to route schema
- [ ] Allow creating/naming groups (e.g., "ATP Stadium", "Studio A")
- [ ] Filter routes table by group/tag
- [ ] Collapsible group sections in the routes list

---

## 🏗️ Strategic / Long-Term

### 11. Multi-Node Clustering
- [ ] Leverage Khepri's built-in Raft consensus for multi-node state sync
- [ ] Route discovery across nodes
- [ ] Failover: if one node goes down, routes can be started on another
- [ ] Cluster management UI in Settings

### 12. Alerting & Webhooks
- [ ] Define alert rules (stream disconnect, high packet loss, route crash)
- [ ] Webhook integration (POST to external URL on alert)
- [ ] Slack/Discord notification support
- [ ] Alert history log in the dashboard

### 13. Stream Recording (DVR)
- [ ] Add optional "Record" toggle per route
- [ ] GStreamer: tee → filesink for recording to disk
- [ ] Configurable recording directory and retention policy
- [ ] Recordings browser in the UI with download/delete

### 14. REST API Documentation (Swagger/OpenAPI)
- [ ] Auto-generate OpenAPI spec from Phoenix routes
- [ ] Serve Swagger UI at `/api/docs`
- [ ] Document all endpoints with request/response schemas
- [ ] Enable third-party integrations

### 15. ~~RTMP Protocol Support~~ ✅
- [x] RTMP/HTTP-FLV/HLS source via ffmpeg sidecar (normalizes to SRT MPEG-TS loopback)
- [x] Auto-reconnect for ffmpeg sidecar on source disconnect (10s retry, 3min timeout)
- [x] Cross-protocol routing: RTMP/HLS/FLV → SRT/UDP
- [x] `-mpegts_copyts 0 -pcr_period 40` for clean timestamp regeneration (fixes hardware decoder macroblocks)
- [ ] HLS preview player in dashboard for RTMP source routes (hls.js)
- [ ] Stream key regeneration UI
- [x] RTMP source health monitoring (GStreamer bus warnings intercept & state metrics)

---

## 💰 Commercialization / Licensing (Sell Blackgate to Clients)

### 16. License Hardening — blockers before first sale
- [ ] **#1 Bound offline grace period** — currently INFINITE (`license.ex:220-221` logs "Keeping cached license active", never expires offline → revocation can't bite an air-gapped box). Add configurable grace (e.g. 30 days offline → deactivate).
- [ ] **#2 Enforce node-lock server-side** — client currently trusts server response; `license_key → machine_id` binding must be authoritative on the server (server not in this repo).
- [ ] **#3 Stable `machine_id`** — currently first MAC from `ip link` (`machine_id.ex:46-66`), fragile on multi-NIC / USB NIC reorder. Store a generated node ID at first boot instead.
- [ ] **#4 Remove default creds** — `admin/password123` hardcoded in Makefile `start` + systemd unit. Per-client provisioning + firstboot secret generation.
- [ ] **#5 Replace dev license URL** — `LICENSE_SERVER_URL=https://license-server-eta-bay.vercel.app` → production license server.
- [ ] **#6 Fix stale comment** — `license.ex:5` claims "RSA public key cryptography" but real impl is online HTTP validation (`verify_license_with_server`). Document actual model.

### 17. Deployment Model — decide before first sale
- [ ] **Fork 1:** software-only vs hardware appliance (iso-builder produces the appliance ISO — recommended path)
- [ ] **Fork 2:** subscription vs perpetual (license `expires_at` supports both: `null` = lifetime)
- [ ] **Fork 3:** internet-connected vs air-gapped (validation is online-only today → air-gapped = 30-day trial only)

### 18. Client Delivery & Support Pipeline
- [ ] Ship via iso-builder appliance, not repo clone / git-pull
- [ ] Real license server (not Vercel dev) + backend per `license.ex:15` Supabase comment
- [ ] Support access: read-only SSH + Tailscale (respect AGENTS.md remote read-only rule)
- [ ] Signed-release update path riding the license heartbeat channel
