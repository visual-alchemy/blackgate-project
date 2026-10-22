# Rust Streaming Engine Context (`native/`)

Production engine is Rust workspace under `native/rust/`. Required platform is
Ubuntu 24.04 LTS with GStreamer 1.24 and Rust 1.96.0.

## Rules

- Build through `make -C native`; output must be `native/build/blackgate-engine`.
- Preserve stdin/stdout/Unix-socket wire contract with Elixir `RouteHandler`.
- Run rustfmt, Clippy with `-D warnings`, workspace tests, and IPC smoke after
  behavior changes.
- Never add production references to `native/archive/c-engine/`.
- Delivery is SRT/UDP only: there is no SDI crate, no DeckLink SDK, and an
  `sdisink` element is rejected at config parse time.
- The wire contract with Elixir is TCP/TS in, SRT/UDP out; verify a real route
  before claiming a change works.

## Commands

```bash
make -C native
cargo fmt --manifest-path native/rust/Cargo.toml --all -- --check
cargo clippy --manifest-path native/rust/Cargo.toml --workspace --all-targets -- -D warnings
cargo test --manifest-path native/rust/Cargo.toml --workspace
python3 native/rust/scripts/ipc_smoke.py --engine native/build/blackgate-engine
```

Archived C engine is immutable migration oracle only. Verify it with
`make -C native/archive/c-engine verify`; build it only inside benchmark image.
