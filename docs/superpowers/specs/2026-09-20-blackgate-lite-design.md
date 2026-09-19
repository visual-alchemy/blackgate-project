# Blackgate Lite Design

## Goal

Create Blackgate Lite as a fresh-install IP gateway product derived from the
current `feat/decklink-duo2` baseline. Lite runs on separate gateway hardware
or a separate VM. It supports the existing IP workflow while containing no SDI
or DeckLink output capability.

Lite uses the existing license server, key format, route limits, expiry,
offline grace, revocation, extension, and manual license sync. Product edition
is a deployment decision, not a license entitlement decision.

## Product boundary

Blackgate Full and Blackgate Lite are separate appliance and update product
lines:

| Concern | Full | Lite |
| --- | --- | --- |
| Installer product marker | `blackgate` | `blackgate-lite` |
| Update manifest product | `blackgate` | `blackgate-lite` |
| Hardware target | Gateway with optional DeckLink SDI | Gateway or VM without DeckLink SDI |
| Destinations | SRT, UDP, SDI | SRT, UDP |
| License model | Shared | Shared |

The appliance writes its product marker to `/etc/blackgate/product`. The
updater reads that marker after verifying the package signature and requires
the signed manifest's `product` value to match. The check occurs before release
extraction or symlink changes. This stops Full and Lite `.bgupdate` packages
from crossing product lines even if both use the same update signing key.

The existing Full installer and package script gain the explicit `blackgate`
marker. Lite equivalents use `blackgate-lite`. Each product line retains its
own signed ISO and update artifact names.

## Code and appliance shape

`blackgate-lite` becomes a long-lived release branch rebuilt from the current
`feat/decklink-duo2` tip. The initial Lite change removes only SDI/DeckLink
support from that baseline while preserving all other current capabilities:

- license enforcement, expiry, revocation, offline grace, reminders, and Sync
  License Now;
- signed appliance updates, system controls, roles, dashboard, events,
  previews, telemetry, and supported IP sources;
- SRT and UDP destinations, including route capacity enforcement and normal
  route health checks.

Lite removes:

- DeckLink SDK sources, Blackmagic Desktop Video installer/dependencies, and
  DeckLink GStreamer build stages;
- SDI sink construction, mode tables, SDI audio upmixing, SDI detection and
  recovery, SDI metrics, and SDI-specific events in the native and Elixir
  layers;
- SDI destination controls, labels, playout stats, and hardware-specific
  dashboard messaging in the React application;
- documentation and ISO text that promise SDI or DeckLink output.

The Lite API keeps server-side validation. A manually submitted `SDI`
destination must return HTTP 422 with a clear unsupported-output message. A
fresh Lite appliance has an empty Khepri route database, so no route migration
or SDI cleanup flow is required.

## License behavior

License server schema and API stay unchanged. Admin users distinguish product
deployment through their own client naming convention, such as `Acme — Lite`
or `Acme — Full`. A valid license key can activate either edition. Its signed
route limit applies the same way in either product.

This intentionally does not prevent a customer who possesses both installer
types from using a key on either product. The product boundary is enforced at
the installer and signed-update layer, not by the license entitlement.

## Release flow

1. Build Lite ISO from the Lite branch without DeckLink assets or packages.
2. Build a Lite release with product marker `blackgate-lite`.
3. Package the release into a signed `.bgupdate` manifest containing
   `product=blackgate-lite`.
4. Lite gateway uploads and deploys only matching Lite packages.
5. Full gateway continues accepting only `product=blackgate` packages.

Lite versions may jump directly to newer Lite versions when the signed package,
platform, and product marker pass verification. Existing Full releases and
their installed data are untouched.

## Error handling

- Wrong product package: updater records `failed: manifest rejected` and makes
  no release-directory, symlink, or service change.
- Invalid signature, checksum, platform, or version: existing rejection and
  rollback behavior remains unchanged.
- SDI API request: API returns 422; no route or destination is persisted.
- Native route receives an unsupported destination from corrupted state: route
  start fails safely with an invalid-destination error rather than constructing
  a DeckLink pipeline.

## Validation

- Native Lite build succeeds without the DeckLink SDK and produces no SDI or
  DeckLink symbols/strings that represent executable capability.
- Backend tests cover rejected SDI route creation, route update, destination
  creation, and destination update; SRT and UDP continue to pass.
- Route handler tests cover rejection of an SDI record received outside normal
  API validation.
- Frontend build passes and exposes only SRT/UDP output choices.
- Update-script tests cover matching Full and Lite products plus both
  cross-product rejection paths.
- Existing license enforcement and manual Sync License Now tests pass
  unchanged on Lite.

## Maintenance rule

Shared security, licensing, updater, and IP-routing changes land on Full first
and are then brought into Lite intentionally. SDI/DeckLink changes remain
Full-only. This keeps Lite current without reintroducing hardware output code.
