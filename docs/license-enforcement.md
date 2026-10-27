# License enforcement and manual sync

Ported from `feat/decklink-duo2` (the C-engine Duo 2 branch), adapted to this branch's API contract. Everything
below is verified by `test/blackgate/license_test.exs` and by the checks in "Validation".

## What changed

Before this change the gateway only *asked* the license at route start, and deactivating a license put the
appliance back into a fresh 30-day, 2-route trial. Measured live on the appliance before the change: a trial
license (`max_routes: 2`) with **5 engines running** — an expired or withdrawn license would have cut nothing.

Now:

- The running route count is checked at start **and** by a background reconciler every second, so expiry,
  revocation, deactivation and a capacity downgrade cut live streams even when nobody touches the API and the
  license server is unreachable.
- Deactivation blocks operation (`max_routes: 0`) instead of granting a new trial.
- Offline operation is bounded: a successful validation grants `:offline_grace_days` (default 30) of offline
  operation, and the deadline is persisted — restarts and failed requests do not renew it.
- The dashboard gains **Sync license now** (`POST /api/license/sync`), which refreshes the entitlement without
  restarting the gateway or waiting for the six-hour heartbeat.

## Enforcement rules

| Situation | Effect |
| --- | --- |
| Expired / revoked / deactivated / offline grace expired | No route may start; every running route is stopped on the next tick (1 s) |
| Named license capacity reduced (e.g. 10 → 2) | Routes beyond the limit are stopped, lowest route id first; the rest keep streaming |
| Restart of a route that is already running | Allowed at the limit — a restart is not a new route |
| Saved route count over the trial cap (2) while on trial | Creation refused with HTTP 402; running routes are unaffected |
| License process or node restart | Entitlement and both deadlines are re-read from Khepri; nothing is renewed |

All routes are stopped, never deleted: saved configurations, destinations and event history remain, so
reactivating the license lets the operator start them again. A successful sync updates expiry, plan and capacity
through the same serialized path and notifies the reconciler; **it does not restart routes that enforcement
stopped.**

## Admission gate

`Blackgate.start_route/1` and `Blackgate.restart_route/1` judge the license and start the engine inside one
`:global` lock (`Blackgate.with_route_lock/1`), and `Db.create_route/2` judges the saved-route count inside the
same lock. Without the lock, a burst of concurrent starts each sees the same free capacity and walks past the
limit. Each of the two paths checks the license only once per call, so a route already holding a slot can always
be restarted or reconfigured.

A license refusal reaches the API as `{:error, {:license, reason}}` and is answered with HTTP 402; every other
start failure keeps its own status (409 for a held output port, 422 for a start failure).

## Time and offline behavior

Full ISO timestamps are enforced at second resolution. Legacy date-only expiry keeps its previous meaning: valid
through the end of that UTC date. A null expiry means lifetime, still subject to online verification.

The clock advances from a monotonic anchor while the node runs, and a high-water mark is saved every minute and
on every entitlement change. After a restart the higher of the wall clock and that mark is used, so rolling the
clock back does not extend an expiry or the offline grace. This is a floor, **not** a tamper-proof hardware
clock: repeated offline power cycles or root-level clock and storage manipulation are outside what a
gateway-side check can defend.

Legacy cached licenses (`license/data`, written by releases before this change) are migrated once into the new
record with a persisted 24-hour window, capped by their own expiry. The window is never renewed and a reboot
re-reads it rather than extending it. Existing `license/first_boot` timestamps are retained, so an appliance
already in trial keeps its remaining days. Unreadable state fails closed (`Cannot load license enforcement
state` stops the node from booting rather than starting unlicensed).

Because the store is opened by `Blackgate.Application` and a failure is now fatal, the test environment no
longer starts a Khepri store of its own (`test/test_helper.exs`).

## Manual synchronization

`POST /api/license/sync` (authenticated like every other `/api` route) reuses the heartbeat validator:

- Concurrent callers join the one upstream request already in flight instead of starting their own.
- A completed manual sync is rate limited for 30 s (`retry_after_seconds` and a `Retry-After` header; HTTP 429).
- Activating or deactivating in the middle of a sync answers `{:error, :superseded}` to the waiting callers
  instead of a success computed from the previous entitlement.
- No activated key, or an appliance in trial: refused without calling the server.
- Server unreachable: **HTTP 503 while the cached entitlement, last verification time and original offline
  deadline are preserved.** A network problem never costs a licensed appliance its license.
- Responses and logs carry the entitlement and a reason the operator can act on; license keys, machine ids and
  upstream response bodies are not returned.

In the dashboard, `web_app/src/pages/License.jsx` shows **Sync license now** only when the gateway reports
`can_sync` (an activated key), reports the cooldown in seconds when rate limited, and states plainly when a
failure preserved the existing state.

## Backup and restore

Unchanged in this branch and **not** covered by the reference branch's protection: `Db.restore_backup/1` and
`Db.backup/0` operate on the whole Khepri store, so a crafted legacy backup can replace `license/enforcement_v1`,
`license/first_boot`, `license/data` and the `users/*` records. Restore is authenticated but has no role gate
here (this branch has no user roles). Treat restore as an operator-only action, and do not treat this branch's
license state as tamper-proof against a privileged operator.

## Remaining signing dependency

The license-server repository and the signing authority are not present here. Validation still consumes the
existing HTTPS JSON response and keeps it in a persisted local record; this is **not** a cryptographically signed
entitlement cache. Direct disk editing by a privileged operator, rollback to an older application release, or
replay of an old disk snapshot stays outside these gateway-only protections.

Before claiming signed-cache protection: agree an issuer envelope with exact signed bytes (schema version, key
id, product, license id, machine id, route capacity, issue/expiry timestamps, verification/offline deadline),
embed only the issuer public key, verify signature and machine binding before trusting any cache, and define
legacy migration and key rotation with the server. Never reuse the appliance update signing key for this, and do
not silently require a new envelope — that would lock out existing clients.

## Validation

```
mix test test/blackgate/license_test.exs   # 10 tests, 0 failures
mix test                                   # full suite
mix compile --warnings-as-errors
mix format --check-formatted
```

`test/blackgate/license_test.exs` locks down the decision logic with the network and the process monitor at the
boundary: trial creation cap, deactivation never re-entering trial, expiry and offline grace verdicts, restart at
the capacity limit, the reconciler's exact stop set (route-id ordered, `limit` kept), a full stop on expiry,
manual sync applying a refreshed entitlement, concurrent syncs sharing one request plus the cooldown, a failed
sync preserving the cache, and sync being refused without an activated key.

Not verified here: the real `Req` call to the license server (mocked), the actual process stop performed by
`Blackgate.stop_route/1` (recorder), and the behaviour of a physical stream when enforcement stops its route.
Those are the same boundaries before and after this change, and the C-branch runbook for them still applies.
