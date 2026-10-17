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
