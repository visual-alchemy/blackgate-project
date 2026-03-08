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

### 5. Live Video Preview
- [ ] Decode incoming SRT stream server-side (GStreamer → JPEG/WebP thumbnails)
- [ ] Serve thumbnail snapshots via API endpoint
- [ ] Display live thumbnail on route detail page with auto-refresh
- [ ] Optional: WebRTC-based low-latency preview in browser

### 6. Route Health Monitoring
- [ ] Define health thresholds (packet loss > X%, RTT > Y ms, disconnected)
- [ ] Add health status indicator to routes table (green/yellow/red dot)
- [ ] Show health alerts on the dashboard
- [ ] Auto-detect disconnected callers and update status

### 7. WebSocket Live Stats
- [ ] Replace polling-based stats with Phoenix Channels (WebSocket)
- [ ] Push real-time bitrate, RTT, and packet loss to the frontend
- [ ] Reduce server load from repeated HTTP polling
- [ ] Smoother, more responsive stats graphs

### 8. Route Groups / Tags
- [ ] Add `tags` or `group` field to route schema
- [ ] Allow creating/naming groups (e.g., "ATP Stadium", "Studio A")
- [ ] Filter routes table by group/tag
- [ ] Collapsible group sections in the routes list

---

## 🏗️ Strategic / Long-Term

### 9. Multi-Node Clustering
- [ ] Leverage Khepri's built-in Raft consensus for multi-node state sync
- [ ] Route discovery across nodes
- [ ] Failover: if one node goes down, routes can be started on another
- [ ] Cluster management UI in Settings

### 10. Alerting & Webhooks
- [ ] Define alert rules (stream disconnect, high packet loss, route crash)
- [ ] Webhook integration (POST to external URL on alert)
- [ ] Slack/Discord notification support
- [ ] Alert history log in the dashboard

### 11. Stream Recording (DVR)
- [ ] Add optional "Record" toggle per route
- [ ] GStreamer: tee → filesink for recording to disk
- [ ] Configurable recording directory and retention policy
- [ ] Recordings browser in the UI with download/delete

### 12. REST API Documentation (Swagger/OpenAPI)
- [ ] Auto-generate OpenAPI spec from Phoenix routes
- [ ] Serve Swagger UI at `/api/docs`
- [ ] Document all endpoints with request/response schemas
- [ ] Enable third-party integrations
