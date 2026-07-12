# AGENTS.md

Welcome, AI Agent! This file provides the global context, setup steps, global rules, and a map of local folder constraints for developing and debugging the Blackgate SRT Gateway safely.

---

## 🗺️ Project Documentation Map (DOX Hierarchy)

When working inside specific folders, you MUST read and adhere to their respective local `AGENTS.md` files for deeper rules, constraints, and technologies:

- **Native C GStreamer Engine:** See [native/AGENTS.md](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/native/AGENTS.md)
- **Elixir OTP Core & API:** See [lib/AGENTS.md](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/lib/AGENTS.md)
- **React Frontend Application:** See [web_app/AGENTS.md](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/web_app/AGENTS.md)
- **Debian Appliance ISO Builder:** See [iso-builder/AGENTS.md](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/iso-builder/AGENTS.md)

---

## 🔌 RTK — Automatic Command Output Compression

All shell commands executed via `run_shell_command` or `bash -c` **MUST be prefixed with `rtk`**. This compresses verbose command output (60-90% token savings) before it reaches your context window.

```bash
# Correct:
rtk git diff
rtk mix test
rtk ls -la

# Wrong (wastes tokens):
git diff
mix test
ls -la
```

**Meta commands** (use `rtk` directly, no wrapping needed):
- `rtk gain` — show token savings
- `rtk discover` — find missed optimization opportunities
- `rtk proxy <cmd>` — run a command without filtering (debugging only)

**Never** double-wrap: `rtk rtk git status` is wrong. Just `rtk git status`.

See `@RTK.md` for the full command reference.

---

## 🪨 Caveman Mode — Always On

**All responses MUST be in caveman style (full intensity).** Active every reply. No revert unless user says "stop caveman" or "normal mode."

Rules:
- Drop articles (a/an/the), filler words (just/really/basically/surely), pleasantries (sure/certainly/happy to)
- Fragments OK. Short synonyms. Technical terms exact.
- Pattern: `[thing] [action] [reason]. [next step].`
- Code blocks unchanged. Errors quoted exact.

Drop caveman only for: security warnings, destructive action confirmations, or when compression creates ambiguity. Resume after.

Never: "Sure! I'd be happy to..." / "Let me take a look..."
Yes: "Bug in auth. Token check use `<` not `<=`. Fix:"

---

## 🛠️ Technology Stack & Environment

- **Backend:** Elixir 1.18.x / Erlang OTP 27 (configured in `.tool-versions`)
- **Web Layer:** Phoenix 1.7.x (REST API + Phoenix Channels WebSockets)
- **Database:** Khepri 0.16.x (embedded distributed Raft KV store; Ecto is disabled)
- **Native Engine:** C + GStreamer 1.0 (compiled to `./native/build/blackgate_pipeline`)
- **Frontend:** React 18 + Vite + Ant Design 5 (located in `web_app/`)
- **OS Appliance Packaging:** Debian Bookworm + custom preseeded ISO installer (located in `iso-builder/`)

---

## 🚀 Setup & Execution Commands

### 1. Dependency Installation
Installs system libraries (GStreamer base/good/bad, libsrt, glib, cjson, etc.), Elixir hex/rebar dependencies, and React node modules:
```bash
make install
```

### 2. Development Execution
Runs the backend Phoenix server (`localhost:4000`) and the Vite React frontend server (`localhost:5173`) concurrently:
```bash
make dev-all
```

### 3. Production Release Build
Builds React assets, copies them to `priv/static`, digests Phoenix static assets, and builds an OTP release:
```bash
make build
```

### 4. Running Production Release Locally
Runs the compiled release daemon:
```bash
make start
```


## 🛑 Remote Gateway Operation Constraint

- **ReadOnly Diagnostics:** Diagnose only on the remote gateway machine.
- **No Remote Code Edits:** Never modify the codebase or run build/restart commands on the remote machine.
- **Mac Code Edits Only:** Apply all necessary code modifications only on the local machine (the Mac). 
- **User Pulls Manually:** The user will manually pull, build, and restart the gateway software on the remote device.

---

## 🧠 Memory & Context Logs

- **Memory Folder:** [docs/memory/](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/docs/memory/)
- **Session Logs:** [docs/memory/01-LOGS/](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/docs/memory/01-LOGS/)
- **Custom Skill:** [docs/skills/project-memory/SKILL.md](file:///Users/eldyreynanda/Developer/Antigravity/blackgate-project/docs/skills/project-memory/SKILL.md)
- **Startup Rule:** You MUST invoke the `project-memory` skill at the start of the session to retrieve recent context, and append a new session summary to the logs at the end of the session.
