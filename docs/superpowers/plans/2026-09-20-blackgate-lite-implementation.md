# Blackgate Lite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update `blackgate-lite` from the current Full gateway while removing SDI/DeckLink capability and isolating Lite update packages.

**Architecture:** Merge the current Full branch into Lite, retain shared licensing and IP-gateway features, then remove SDI from API, runtime, UI, and appliance build layers. Lite installers write `blackgate-lite` to `/etc/blackgate/product`; signed Lite packages carry the same product value and updater compares them before extraction.

**Tech Stack:** Elixir/Phoenix/Khepri, C/GStreamer, React/Vite, Bash, Ubuntu autoinstall, OpenSSL signatures.

---

## File map

- `lib/blackgate/db.ex` and `lib/blackgate_web/controllers/fallback_controller.ex`: reject SDI writes with HTTP 422.
- `lib/blackgate/route_handler.ex`, `route_health.ex`, `route_stats_registry.ex`, `system_control.ex`, and `route_validator.ex`: remove SDI route state and DeckLink reporting.
- `native/src/gst_pipeline.c`, `native/decklink-sdk/`, and `Dockerfile`: remove DeckLink pipeline and build dependencies.
- `web_app/src/pages/routes/*`, `web_app/src/components/RouteStats.jsx`, `web_app/src/pages/Settings.jsx`, and `web_app/src/utils/sdiPorts.js`: remove SDI controls and metrics.
- `iso-builder/` and `scripts/package-signed-update.sh`: make Lite installer/package/updater identity explicit and omit Desktop Video.
- `test/blackgate/db_sdi_validation_test.exs`, `test/blackgate/route_handler_test.exs`, and `test/scripts/blackgate_updater_product_test.sh`: verify boundary behavior.

### Task 1: Merge current Full baseline into Lite

**Files:** Git history on `blackgate-lite` only.

- [ ] Create isolated worktree without touching the current dirty Full worktree.

  Run: `git worktree add ../blackgate-lite-worktree blackgate-lite`

- [ ] Merge current baseline.

  Run from Lite worktree: `git merge --no-ff feat/decklink-duo2 -m "merge: update Lite from current Full baseline"`

  Resolve conflicts by keeping Full behavior unless the code is SDI/DeckLink-only. Commit only conflict resolutions.

- [ ] Verify current license commits are in Lite history.

  Run: `git log --left-right --cherry-pick --oneline blackgate-lite...feat/decklink-duo2`

  Expected: license enforcement and manual sync are no longer missing from Lite.

### Task 2: Add server-side Lite output boundary

**Files:**

- Create: `test/blackgate/db_sdi_validation_test.exs`
- Modify: `lib/blackgate/db.ex`
- Modify: `lib/blackgate_web/controllers/fallback_controller.ex`

- [ ] Write failing tests for route create/update and destination create/update with `schema: "SDI"`. Each must expect `{:error, "SDI output not supported on Blackgate Lite"}`. Include positive SRT and UDP cases.

- [ ] Run: `mix test test/blackgate/db_sdi_validation_test.exs`

  Expected: fail before guard implementation.

- [ ] Implement `has_sdi_destination?/1` and `sdi_destination?/1` in `Blackgate.Db`. Reject before each write. For an existing destination update, merge stored and incoming data before validation. Map the known error to HTTP 422.

- [ ] Re-run the focused test. Expected: pass.

- [ ] Commit: `feat(lite): reject SDI destinations`.

### Task 3: Remove SDI route runtime behavior

**Files:**

- Modify: `lib/blackgate/route_handler.ex`
- Modify: `lib/blackgate/route_health.ex`
- Modify: `lib/blackgate/route_stats_registry.ex`
- Modify: `lib/blackgate/system_control.ex`
- Modify: `lib/blackgate/route_validator.ex`
- Modify: `test/blackgate/route_handler_test.exs`

- [ ] Add failing test: `RouteHandler.sink_from_record(%{"schema" => "SDI", "schema_options" => %{}})` returns `{:error, :invalid_destination}`.

- [ ] Run: `mix test test/blackgate/route_handler_test.exs`

  Expected: fail while SDI returns `sdisink` configuration.

- [ ] Delete SDI sink translation, DeckLink hardware diagnosis, SDI audio restart logic, SDI playout-frame watchdog data, SDI events, SDI stats/health branches, DeckLink node status, and `seamless_sdi_failover` validation. Preserve regular source failover, SRT/UDP sink conversion, generic errors, and byte-based watchdogs. Unknown sinks must return `{:error, :invalid_destination}`.

- [ ] Re-run focused route-handler tests. Expected: pass.

- [ ] Commit: `feat(lite): remove SDI route lifecycle`.

### Task 4: Remove DeckLink native engine and build inputs

**Files:**

- Modify: `native/src/gst_pipeline.c`
- Delete: `native/decklink-sdk/`
- Modify: `Dockerfile`
- Modify: `native/AGENTS.md`

- [ ] Run: `rg -n 'decklinkvideosink|decklinkaudiosink|sdisink' native/src/gst_pipeline.c`

  Expected: existing SDI implementation matches.

- [ ] Remove DeckLink mode tables, dynamic mode detection, raw SDI branch construction, audio upmix, SDI probes/metrics, SDI rebuild logic, and special nonfatal SDI failure behavior. Keep source parsing, preview, SRT statistics/pacing, SRT sink, and UDP sink.

- [ ] Delete SDK directory. Remove DeckLink SDK copies, DeckLink GStreamer packages, and library-path setup from Docker build.

- [ ] Run: `make -C native`; then run `! rg -n 'decklinkvideosink|decklinkaudiosink|sdisink' native/src/gst_pipeline.c`.

  Expected: build passes and no SDI sink code exists.

- [ ] Commit: `feat(lite): remove DeckLink native output`.

### Task 5: Remove SDI dashboard controls

**Files:**

- Modify: `web_app/src/pages/routes/RouteDestEdit.jsx`
- Modify: `web_app/src/pages/routes/OutputPopover.jsx`
- Modify: `web_app/src/pages/routes/RouteItem.jsx`
- Modify: `web_app/src/pages/routes/Routes.jsx`
- Modify: `web_app/src/pages/routes/RouteSourceEdit.jsx`
- Modify: `web_app/src/components/RouteStats.jsx`
- Modify: `web_app/src/pages/Settings.jsx`
- Delete: `web_app/src/utils/sdiPorts.js`

- [ ] Remove SDI imports, selector, forms, labels, ports, stats, DeckLink error text, hardware status, and Seamless SDI Failover field. Keep SRT/UDP controls and ordinary source failover.

- [ ] Run: `cd web_app && npm run build`

  Expected: pass.

- [ ] Run: `! rg -n 'SDI|DeckLink|seamless_sdi_failover' web_app/src/pages/routes web_app/src/components/RouteStats.jsx web_app/src/utils`

  Expected: no matches in Lite UI code.

- [ ] Commit: `feat(lite): remove SDI dashboard controls`.

### Task 6: Implement Lite ISO and update identity

**Files:**

- Modify: `iso-builder/build.sh`
- Modify: `iso-builder/files/blackgate-firstboot.sh`
- Modify: `iso-builder/autoinstall/user-data`
- Modify: `iso-builder/offline-packages.txt`
- Delete: `iso-builder/tools/decklink-profile-config.cpp`
- Modify: `iso-builder/files/blackgate-updater`
- Modify: `iso-builder/files/99-blackgate-motd.sh`
- Modify: `scripts/package-signed-update.sh`
- Create: `test/scripts/blackgate_updater_product_test.sh`

- [ ] Add shell fixture tests for product mismatch: installed marker `blackgate-lite` plus signed manifest `product=blackgate` must fail before release extraction. Matching `blackgate-lite` manifest must pass manifest validation.

- [ ] Run: `bash test/scripts/blackgate_updater_product_test.sh`

  Expected: fail before installed-marker support.

- [ ] First boot must write marker with `install -d -m 0755 /etc/blackgate` and `printf '%s\n' 'blackgate-lite' > /etc/blackgate/product`. Updater reads that file after signature verification and requires the manifest product to equal it. Keep platform, checksum, version, restart, and rollback checks unchanged.

- [ ] Package script must write `product=blackgate-lite`. ISO build must remove Desktop Video preflight, utility compilation/copy, driver package, installer late commands, first-boot driver/profile setup, and DeckLink-only offline packages. Rename installer volume and user-facing text to Blackgate Lite.

- [ ] Re-run product test. Run `! rg -n 'desktopvideo|decklink-profile|Blackmagic_Desktop' iso-builder`.

  Expected: matching Lite update validates; Full update rejects; no DeckLink installer payload remains.

- [ ] Commit: `feat(lite): isolate appliance update product`.

### Task 7: Document and verify Lite release

**Files:**

- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `lib/AGENTS.md`
- Modify: `docs/license-enforcement.md`
- Modify: Lite release notes

- [ ] Document Lite as a fresh IP-only appliance on separate hardware/VM. State SRT/UDP output, shared license server/key behavior, and signed product-specific update rejection. Do not claim license-product enforcement.

- [ ] Run focused checks:

  `mix test test/blackgate/db_sdi_validation_test.exs test/blackgate/route_handler_test.exs test/blackgate/license_enforcement_test.exs`

  `cd web_app && npm run build`

  `make -C native`

  `bash test/scripts/blackgate_updater_product_test.sh`

- [ ] Scan final capability boundary: `rg -n 'decklinkvideosink|decklinkaudiosink|sdisink' native lib web_app iso-builder Dockerfile`.

  Expected: no executable or installer capability matches.

- [ ] Commit documentation and tests. Inspect final `git status --short --branch` and `git log --oneline --decorate -12` to confirm only Lite files are staged/committed.
