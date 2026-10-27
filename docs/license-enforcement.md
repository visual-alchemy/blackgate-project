# Licence enforcement

Blackgate is sold per gateway with a route capacity, so the gateway has to enforce two things on its own:
how many routes may run, and whether the licence entitles it to run at all. This is what enforces them, what
it protects against, and - just as important - what it does not.

## Where the licence lives

| State | Storage | Note |
| --- | --- | --- |
| The licence payload | Khepri `license/data` | Exactly what the licence server answered, cached so the gateway keeps working offline |
| First-boot stamp | Khepri `license/first_boot` | Written once, on the first boot of an unlicensed gateway; the trial window counts from it |
| Clock floor | Khepri `license/clock_high_water` | The furthest-forward date this gateway has ever judged a licence on |
| The live copy | ETS `:blackgate_license` (`{:license, map}`) | What `Blackgate.License.get_license/0` answers from; rebuilt at boot from Khepri |

All three Khepri keys live in the same store as the routes (`DATABASE_DATA_DIR`). **A gateway whose store is lost
loses its licence with it**: it comes back on the trial, counted from the original first-boot stamp - so an
appliance that has been in service longer than 30 days comes back with no capacity at all and stops its routes.
Boot logs `license_missing` (critical) when that happens; it does not silently look like a fresh trial.

## The licence states and what they permit

`Blackgate.License.capacity_of/1` is the single answer to "how many routes may run", and everything else is built
on it:

| State | Capacity |
| --- | --- |
| `%{status: :licensed, expired: false, max_routes: n}` | `n` |
| `%{status: :trial, expired: false}` | 2 (`trial_max_routes`) |
| Expired (dated licence past `expires_at`, or a trial whose window has passed) | 0 |
| Anything unrecognised (unlicensed, a status from a newer server, `%{}`) | 0 |

Zero is the answer for every state that is not a licence. The alternative - treating an unknown state as
"allowed" - is how a gateway ends up streaming for free the first time the licence server invents a new status.

## The two layers that enforce it

**1. Admission (fail closed).** `Blackgate.start_route/1` and `Blackgate.restart_route/1` judge the licence
before they do anything else, inside the route-admission lock
(`Blackgate.with_route_lock/1`, `:global.trans`), against the count of *live engine processes* - not the stored
`status`, which can read `started` for a route whose engine has died. A refusal is `{:error, {:license, reason}}`
and answers HTTP **402** with the sentence the licence wrote ("Route limit reached (10)...", "License expired...").

Two rules that come out of that:

- **Every start path is judged**, because the judgment lives in the function they all call. It used to live only
  in the Start action, so the dashboard's Start-all walked around it - a trial gateway (2 routes) could fill the
  box, and an expired licence could be worked around the same way.
- **A restart is not a new slot.** A route that is already running is not counted against the licence when it is
  restarted, or editing the destination of the last route the licence covers would be refused. Both judgments
  happen *before* the stop, so a refusal leaves the route running on its previous destination.

**2. Enforcement (fails open on read errors).** `Blackgate.LicenseEnforcer` is a pass, every 10 seconds and
immediately whenever the licence changes (activate, deactivate, re-verify), that stops the running routes above
the current capacity: the live engine set, sorted by route id, the first `capacity` are kept. Sorted on purpose -
a pass that picked a different set each tick would cut a different stream every tick.

Each stop is a `license_route_stopped` event (warning) naming the route and why, with guidance on the Events tab.
The record's `status` is written by the RouteHandler as the engine goes, so the dashboard does not keep claiming a
cut route is running.

An unreadable licence state (a table that is not up yet) stops nothing and logs `license_unreadable` once, not
once per tick: taking every stream down over a number this module could not read is worse than leaving a route
running that the operator can stop by hand. Strictness belongs to the admission layer, which fails closed.

## What the gateway does on its own

| Event | What happens |
| --- | --- |
| Licence expires (dated) | Capacity 0 on the date itself; the next pass stops everything running. Starts are refused from the same moment |
| Trial window passes | Same, at capacity 0 |
| Licence deactivated (dashboard) | Reverts to the trial, counted from the original first-boot stamp - so on a gateway past its trial window, capacity 0 |
| Licence replaced by a smaller plan | The pass runs immediately after activation and stops what the new capacity does not cover (newest ids go first, by id order) |
| Server unreachable at boot / heartbeat | The cached licence stays in use: `License` logs "Keeping cached license active". Nothing is stopped for being offline |
| Server reachable again (heartbeat, ≤6 h) | The fresh payload replaces the cache, and the pass runs immediately |
| Operator wants an answer now | `POST /api/license/sync` (License page → "Sync license now"). 422 with the reason when there is no key or the server cannot be reached, and the cached licence stays in use |
| Clock moved back | The clock floor (`clock_high_water`) keeps the deadline where it was: the licence cannot be extended, and an expired trial cannot be renewed, by setting the clock back |
| Licence store lost | Back on the trial counted from the original first-boot stamp; `license_missing` (critical) is logged at boot |

## What this does not protect against

- **No signing authority, and no signed cache.** The licence is an HTTPS JSON answer, cached as-is: anyone with
  root on the box can edit `license/data` in Khepri, and no signature is checked. This is deterrence, not
  tamper-proofing.
- **Activation needs the licence server** (`license_server_url`, default `http://localhost:3000`): a gateway that
  cannot reach it can keep running on a cached licence, but cannot be given a new one. Provisioning an appliance
  offline means writing the payload into the store by hand, which is the same door as above.
- **Enforcement lives in this codebase.** Disabling it means editing or replacing the release, which root can do.
- **A gateway with a valid licence is not phone-home monitored.** The heartbeat is a verification, not telemetry:
  it sends the key and the machine id, and what comes back is the entitlement.

## API

| Method | Path | Answers |
| --- | --- | --- |
| `GET` | `/api/license` | the cached licence payload the gateway is actually judging by |
| `POST` | `/api/license/activate` | `%{key: …}`: verifies against the server, caches, and enforces immediately |
| `POST` | `/api/license/sync` | re-checks the cached key now; 422 with the reason, cached licence kept |
| `DELETE` | `/api/license/deactivate` | drops the key and reverts to the trial |

## Testing enforcement

The licence is ETS plus Khepri, both readable and writable from a test:

```elixir
# The capacity the gateway judges by
:ets.insert(:blackgate_license, {:license, %{status: :licensed, expired: false, max_routes: 2}})

# The running set, as the admission gate and the pass read it (a test seam, never set in production)
:persistent_term.put({Blackgate, :running_route_ids}, ["route-a", "route-b"])
```

`test/blackgate_web/controllers/license_admission_test.exs` covers the gate (including Start-all),
`test/blackgate/license_enforcer_test.exs` the pass, `test/blackgate/license_test.exs` the capacity table and the
clock floor, and `test/blackgate_web/controllers/license_sync_test.exs` the manual re-check. Restore both the ETS
entry and any Khepri key a test touches - they are node-wide.
