# Blackgate Native Pipeline

The `native/` directory contains the C codebase for Blackgate's high-performance video streaming pipeline. This component handles the actual SRT/UDP packet processing using GStreamer, and communicates with the Elixir backend via Unix Domain Sockets.

## Architecture

```
Elixir (RouteHandler)
    │
    ├── stdin  →  JSON config (pipeline definition)
    ├── stdout ←  status messages
    └── Unix Socket (/tmp/hydra_unix_sock)
            ↕
        blackgate_pipeline (C process)
            │
            ├── GStreamer srtsrc/udpsrc  (source)
            ├── tee                     (splitter)
            └── srtsink/udpsink × N     (destinations)
```

## Key Files

| File | Purpose |
|------|---------|
| `src/main.c` | Entry point — reads JSON config from stdin, builds GStreamer pipeline |
| `src/pipeline.c` | GStreamer pipeline construction and lifecycle |
| `src/unix_socket.c` | Unix Domain Socket client for stats reporting |
| `src/stats.c` | SRT statistics collection and JSON serialization |
| `Makefile` | Build configuration |

## Building

The native binary is compiled automatically during `make build` or `mix compile`. It requires:
- GStreamer 1.0 development libraries
- libsrt (with OpenSSL)
- libcjson
- libcmocka (for tests)
- pkg-config

## Debug Input Examples

Paste these JSON payloads into stdin when running `blackgate_pipeline` manually:

**SRT Listener → SRT Listener + UDP:**
```json
{"source":{"type":"srtsrc","localaddress":"127.0.0.1","localport":8000,"auto-reconnect":true,"keep-listening":false,"mode":"listener"},"sinks":[{"type":"srtsink","localaddress":"127.0.0.1","localport":8002,"mode":"listener"},{"type":"udpsink","host":"127.0.0.1","port":8003}]}
```

**With authentication (passphrase + key length):**
```json
{"source":{"type":"srtsrc","localaddress":"127.0.0.1","localport":8000,"auto-reconnect":true,"keep-listening":false,"mode":"listener","streamid":"test1","passphrase":"secure_pass_123","pbkeylen":16},"sinks":[{"type":"srtsink","localaddress":"127.0.0.1","localport":8002,"mode":"listener"},{"type":"udpsink","host":"127.0.0.1","port":8003}]}
```
