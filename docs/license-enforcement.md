# License enforcement and rollout

## Gateway behavior

- Named license capacity limits live route supervisors (including reconnects), not saved configurations. The built-in trial additionally limits saved routes to two.
- All normal, bulk, restart and edit-triggered starts pass through the same serialized admission gate. User-editable database status is not a capacity counter.
- Expired, revoked, deactivated, unavailable or offline-grace-expired entitlements admit no routes. The independent worker checks every second and stops existing routes. Shutdown duration can extend the observed cutoff beyond the polling interval.
- Reconnect and native pipeline initialization also check local validity. Renewal permits manual restart; it does not unexpectedly resume previously stopped streams.
- Capacity reduction retains routes in stable route-ID order and stops the remainder. All saved configurations remain.
- Named license deactivation never creates another built-in trial.

## Time and offline behavior

Full ISO timestamps are enforced at second resolution. Legacy date-only expiry retains its previous meaning: valid through the end of that UTC date. A null expiry still denotes lifetime, subject to online verification requirements.

Successful server validation grants the configured offline grace (default 30 days). Explicit license expiry always wins if sooner. The deadline is persisted; failed requests and process restarts do not renew it. Server revocation is persisted too.

The clock advances from a monotonic anchor while running. A high-water mark is saved every minute and on entitlement changes, and used after restart. This prevents rollback behind recorded time, but is not a tamper-proof hardware clock: repeated offline power cycles or root-level clock/storage manipulation require stronger trusted-time controls.

Existing legacy cached licenses receive one persisted 24-hour migration window, capped by their original expiration. Boot starts asynchronous server verification immediately. Reboot cannot renew that window. Existing trial first-boot timestamps are retained. Unreadable state fails closed.

## Manual synchronization

Dashboard Admins can use **Sync license now** to request the latest entitlement without restarting the gateway or waiting for the six-hour heartbeat. The Admin-only `POST /api/license/sync` endpoint reuses the heartbeat validator. Concurrent callers join one upstream request, and completed manual requests have a 30-second cooldown.

A successful refresh updates expiry, plan and route capacity before notifying the license enforcer. Revocation, expiry and capacity reduction therefore use the same serialized enforcement path as scheduled verification. Reactivation updates the entitlement but does not start stopped routes. Network and server failures return HTTP 503 while preserving the cached entitlement, last verification time and original offline deadline. API responses and logs omit license keys, machine IDs and upstream response bodies.

## Backup changes

Binary configuration backups contain only routes, destinations and interface aliases. Legacy full backups are filtered on import. License records, validation deadlines, trial history, accounts and unknown namespaces cannot be replaced through restore. Restore requires Admin, stops running routes and restores their saved status as stopped. Trial restore cannot exceed two saved routes.

## Remaining signing dependency

The license-server repository and signing authority are not present here. Current validation still consumes the existing HTTPS JSON response, with a protected in-process cache and persisted local record. **This is not a cryptographically signed entitlement cache.** Direct disk editing by a privileged operator, rollback to old application releases, or replay of old disk snapshots remains outside these gateway-only protections.

Before claiming signed-cache protection, implement and deploy an agreed issuer envelope carrying exact signed bytes, schema version, key ID, product, license ID, machine ID, route capacity, issue/expiry timestamps and verification/offline deadline. Embed only the issuer public key in Blackgate, verify signature and machine binding before trusting any cache, and define legacy migration and key rotation together with the server. Never reuse or expose the appliance update private key on gateways.

Do not silently require a new envelope from the current server; that would lock out existing clients. No client deployment, ISO rebuild or production update package is part of this unfinished signing integration.

## Validation

`test/blackgate/license_enforcement_test.exs` uses actual route supervisors, Khepri and an injectable clock, with hardware/network boundaries mocked. It exercises concurrent admission and creation, restart capacity, forged status, expiry/cutoff/renewal, offline restarts, durable revocation, backup protection, downgrade, migration, restore authorization, manual refresh deduplication, cooldown, offline preservation and Admin-only API access.

Run tests against isolated storage and socket. Both standard and named-node test startup were verified (117 tests, zero failures); the authorization fixture starts Cachex when needed. Do not reuse a running appliance's database or socket. Frontend production build passed. Physical stream shutdown and client migration must also be tested on spare hardware before client rollout.
