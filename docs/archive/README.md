# Archived documents

> **Scope note (branch `rust-gateway`).** This document describes the SDI-capable product line
> (`rust-decklink-duo2`). On `rust-gateway` there is no SDI path: no `engine-sdi` crate, no
> DeckLink SDK, no Blackmagic driver in the image, and an SDI destination is refused by the API
> and the engine. Kept as history; do not use it as a build instruction here.

Files here describe earlier states of the project. They are kept for history and are **not**
current: the C media engine no longer builds or runs in production — it is the frozen,
manifest-verified benchmark oracle under `native/archive/c-engine/` — and the runtime is the
Rust engine only.

| File | What it was | Current authority |
| --- | --- | --- |
| `Rustroadmap.md` | The v2 migration roadmap written when the C engine was still in place. Its "authoritative" claim is withdrawn. | `docs/superpowers/plans/2026-08-27-rust-migration-completion.md` |
| `IMPLEMENTATION_PLAN.md` | Function-by-function companion to the above. | Same, plus `docs/migration/BAREMETAL_VERDICT_RUNBOOK.md` |
| `SDI_FIXES.md` | SDI output notes from the C-engine era. | `native/rust/engine-sdi`, `docs/migration/SDI_MANUAL_SIGNOFF.md` |

Current status lives in `docs/migration/RUST_MIGRATION_STATUS.md`; session history lives in
`docs/memory/01-LOGS/`.
