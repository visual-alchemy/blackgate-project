---
name: project-memory
description: Enforces persistent session memory and journaling for the blackgate-project repository.
---

# Project Memory and Context Journaling

This skill ensures that you never start a session cold and that you leave a clear trail of accomplishments, decisions, and system constraints for the next agent session.

## Checklist

You MUST follow these steps in every session:

1. **Read Previous Context**
   - Read the 3 most recent session log files in `docs/memory/01-LOGS/` (if any exist).
   - Read all files in `docs/memory/00-INBOX/` (where the user may have left specific notes/tasks/feedback).
2. **Acknowledge and Summarize**
   - Provide a brief 2-sentence summary in your first response outlining:
     - The current state of the codebase based on the logs.
     - What the user is currently working on or stuck on.
3. **Execute Task**
   - Proceed with the user's coding/development request following standard planning and execution skills.
4. **Log the Session**
   - Before completing your work and ending the session:
     - Write a new session log file: `docs/memory/01-LOGS/YYYY-MM-DD-session-X.md` (incrementing the session number `X` if multiple logs are written in one day).
     - In the log, include:
       - **Sprint Goal & Focus**
       - **What Was Accomplished** (summarize files created/modified, commands run, tests passed)
       - **Key Decisions & System Constraints Resolved**
       - **Current Codebase State**
       - **Pending Tasks & Next Milestones**
     - Clear the files in `docs/memory/00-INBOX/` that you have fully processed.

## Troubleshooting: a newly added route will not receive

Check the stats socket before suspecting the route or the source. The Elixir node and
every Rust engine talk over a Unix socket whose path is per environment
(`Blackgate.stats_socket_path/0`: release `/tmp/hydra_unix_sock`, dev
`/tmp/blackgate_stats_dev.sock`, test a per-run path; override with
`BLACKGATE_STATS_SOCKET`). An engine that cannot reach it dies immediately with
`pipeline: connect: Connection refused (os error 111)` and its route crash-loops,
while routes whose engines connected earlier keep running — so the app looks half
healthy. Symptom: `Connection refused` in
`_build/prod/rel/blackgate/tmp/log/erlang.log.*` plus a socket file whose mtime does
not match the node boot. Starting a second node is what caused it historically, so
`make start` refuses while a node is alive and
`Blackgate.Application.assert_stats_socket_free!/1` refuses to bind a path that
already has a live listener.

Distinguish the two remaining "route looks broken" cases:

- Source really losing packets → `warning` badge, not a failed connection. Read
  `loss-window-pct` (per interval), not the cumulative loss, which keeps a startup
  burst forever.
- Source silent or a wrong URI/passphrase → route stays `reconnecting` while the
  engine itself is healthy; check with `ffprobe`/`ffmpeg` against the source URI
  first.

## Diagnostic switches in the Rust engine

Both are env vars on the engine process, so they work standalone (`printf '%s\n' "$CONFIG_JSON" | BLACKGATE_X=1 ./native/build/blackgate-engine <route-id>`) and are the
cheap way to A/B a suspect without touching code:

- `BLACKGATE_NO_THUMBNAIL=1` — skips the preview branch. A/B proved it does not affect
  SRT receive loss, so do not "fix" loss by removing the preview.
- `BLACKGATE_DUMP_PROPS=1` — prints `PROP name=value` for every readable property of the
  source element, so the Rust engine's element setup can be diffed against the C
  engine's (blackgate-lite prints the same format from `set_element_properties`; add
  that block in a throwaway `git worktree` of the C branch, never in the branch).
  Diffing them showed the `srtsrc` elements are configured identically — read the
  properties through the param spec's READABLE flag, or write-only ones like
  `passphrase` panic.
- `BLACKGATE_DUMP_STATS=1` — prints the raw `srtsrc` `stats` structure (with field types)
  plus what each typed getter returns. Use it before believing any loss figure.

## Never trust a 0% loss reading from the C engine

blackgate-lite's `build_source_stats_json` reads `packets-received-lost`,
`packets-received-dropped` and `packets-received-retransmitted` with
`gst_structure_get_int64`, but GStreamer's srtsrc stores them as **`int` (gint32)**. The
strict type check fails, the getter's FALSE return is ignored, and the variable keeps its
0 initialiser — so that engine reports 0 lost / 0 dropped / 0 retransmitted **forever**,
however much it actually loses. (`packets-received` is `gint64`, which is why that one
field always worked and made the rest look plausible.)

Measured on one host, same source and window, raw structures from both engines:
`packets-received-lost=(int)421` (C) vs `(int)416` (Rust) — the same loss. The Rust port
reads those fields correctly; a "Rust loses packets, C doesn't" report is almost always
this bug. Fix the C side with `gst_structure_get_int` (and remember the field is gint32,
so it wraps after ~2.1 billion packets ≈ 2.8 TB).

To compare engines on one host: build the C engine from a worktree of the blackgate-lite
branch (`make -C native CFLAGS="-Wall -Wextra -g $(pkg-config --cflags gstreamer-1.0 gstreamer-app-1.0)" LDFLAGS="$(pkg-config --libs gstreamer-1.0 gstreamer-app-1.0 gio-2.0) -lsrt-gnutls"`),
drop cJSON.c/cJSON.h into `src/`+`include/` (the system dev headers are absent), run both
standalone against the same source and compare the SRT counters. Both engines talk to
the live stats socket, so give them probe route ids — the release stores their stats and
you read them back with `Blackgate.RouteStatsRegistry.get_stats/1`.
