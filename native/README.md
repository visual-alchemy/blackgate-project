# Blackgate Rust Media Engine

`native/` contains Blackgate production media runtime. Production entry point is
`native/build/blackgate-engine`, built from Rust workspace in `native/rust/`.
It reads one route configuration from stdin, emits lifecycle messages on
stdout, accepts control commands on stdin, and sends telemetry JSON through
Blackgate Unix socket.

## Workspace

| Crate | Responsibility |
| --- | --- |
| `blackgate-engine` | Production process, IPC, lifecycle |
| `engine-config` | Route configuration and wire contract |
| `engine-gst` | GStreamer pipeline construction and bus handling |
| `engine-stats` | Source/destination SRT statistics |
| `engine-metadata` | MPEG-TS metadata parsing |
| `engine-thumbnail` | JPEG preview extraction |
| `engine-failover` | Dual-ingest switching state |
| `engine-sdi` | DeckLink mode and audio handling |

## Build and verify

```bash
make -C native
cargo fmt --manifest-path native/rust/Cargo.toml --all -- --check
cargo clippy --manifest-path native/rust/Cargo.toml --workspace --all-targets -- -D warnings
cargo test --manifest-path native/rust/Cargo.toml --workspace
python3 native/rust/scripts/ipc_smoke.py
```

Pinned compiler comes from `rust-toolchain.toml`. Ubuntu 24.04 LTS with
GStreamer 1.24 is required production baseline.

## Runtime boundary

- `native/Makefile` builds Rust only.
- `mix.exs` packages only `blackgate-engine` in OTP release.
- `scripts/check_rust_only_runtime.sh` rejects legacy executables/references.
- `native/vendor/decklink-sdk/` supplies DeckLink headers for plugin build.

## Historical benchmark oracle

Legacy C implementation is checksum-frozen under `native/archive/c-engine/`.
It exists only for migration performance comparison and must never be imported,
packaged, or used as production fallback. See archive README and
`benchmarks/migration/README.md`.

Physical DeckLink/SDI behavior requires
`docs/migration/SDI_MANUAL_SIGNOFF.md`; automated checks cannot claim hardware
completion.
