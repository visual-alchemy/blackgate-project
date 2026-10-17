---
name: pinned-toolchain-bootstrap
description: Bootstrap pinned OTP/Elixir/Node/Rust on a fresh host.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [toolchain, bootstrap, makefile, install, linux, ubuntu]
    related_skills: [hermes-agent]
---

# Pinned toolchain bootstrap (fresh Linux host)

## When to Use

Triggers: fresh machine, `mix`/`cargo` missing, "can this target be delivered or
installed here", sudo prompts during install, toolchain version gates failing.

Make `make install` work on a host that has nothing, without hand-installing
asdf/nvm/rustup and without root beyond the package step.

## Always-on rules

- Reply in the user's language. This user writes English by default — never switch
  languages mid-session unannounced (it reads as a defect, not a feature). They may
  explicitly ask for Indonesian ("pakai bahasa indonesia") and often want it plain and
  non-technical: an explicit request overrides the default.
- When writing Indonesian for this user, keep technical terms in their original English
  form (branch, commit, push, route, source, destination, engine, stats, Dashboard).
  Do NOT translate them ("cabang", "tujuan", "mesin") — they read the English terms as
  the real names and translated ones as noise.
- Never ask the user to paste a password into chat (it lands in history and logs).
  For sudo-gated steps, hand them ONE copy-paste command for their own terminal,
  or install a narrow sudoers drop-in — `templates/sudo-dev-packages.sudoers`.
- Default prefix is user-local (`~/.blackgate/toolchain`), not root-writable
  `/opt`: no root needed, survives re-clone, portable across dev hosts.
- Keep system packages (apt/brew) in the Makefile/CI step and pinned language
  toolchains in the bootstrap script. That split keeps the script sudo-free and
  testable end-to-end on any host.
- Version-pin from the repo's own contract (`.tool-versions`, `rust-toolchain.toml`,
  Dockerfile ARGs) — never invent a version, and reuse checksums already in the repo.

## Procedure

1. Inventory before installing anything:
   `for c in mix elixir erl cargo rustc node npm pkg-config; do command -v $c; done`
   plus `uname -m` (asset pins are amd64; guard non-amd64) and `/etc/os-release`.
2. Read the pinned versions out of the repo contract files.
3. System packages (needs sudo) — full list in `references/fresh-ubuntu-toolchains.md`.
4. Bootstrap toolchains into the prefix from upstream tarballs, sha256-verified,
   with a download cache that skips re-fetch when the hash still matches.
   Recipes (URLs, checksums, install flags): `references/fresh-ubuntu-toolchains.md`.
   Before the toolchain step, guard the sudo -H case: if `id -u` is 0 and the
   prefix is under `/root`, plain `sudo make install` lost its `HOME` (sudoers
   `always_set_home` or `sudo -H/-i`) — warn and keep paths user-local.
5. Build a symlink farm `prefix/bin/*` so `#!/usr/bin/env elixir` resolves even
   with no rc file sourced (e.g. a bare CI/non-login shell).
6. Record PATH + `ERL_ROOT` in BOTH `~/.bashrc` (interactive) and `~/.profile`
   (login shells — `ssh host 'make build'` reads `.profile`, not `.bashrc`),
   guarded by a marker string so re-runs stay idempotent.
7. Verify with version gates (mix/elixir `--version`, `erl system_version`,
   `rustc --version`, `node --version`) and then actually build/test:
   `mix deps.get && mix compile && mix test`, `npm ci`, `cargo fmt --check`.

## Pitfalls

- Makefile target whose first recipe line is `set -e;` without `@` makes make echo
  the entire recipe — output looks like nothing ran and errors are buried. Use
  `@set -e;` and keep the target one shell (backslash-continued) so the gate covers
  every step; `$$` escapes shell vars in recipes.
- Export the toolchain PATH at Makefile FILE scope, not inline inside one target:
  `export PATH := <prefix>/bin:<prefix>/otp/bin:<prefix>/elixir/bin:<prefix>/node/bin:<prefix>/rust/bin:$(PATH)`
  plus `export ERL_ROOT := <prefix>/otp`. Non-interactive `make` never sources
  `~/.bashrc`/`~/.profile`, so `install` passes while every other target dies with
  `npm: No such file or directory` (exit 127). File-scope exports are inherited by all
  recipes — delete the per-target duplicates once they exist.
- `bin/mix` is `#!/usr/bin/env elixir`: put the OTP `bin` on PATH too or mix dies
  before printing anything useful. The OTP *build* tarball needs no `ERL_ROOT`.
- Rust dist `install.sh` component names are exact (`rustfmt-preview`,
  `clippy-preview`, `rust-std-<target>`): `--component=` is not a flag and
  short names abort with `unknown component: clippy`. List real names with
  `install.sh --list-components` before writing the line.
- `builds.hex.pm` has no directory listing and no `.sha256` sidecars for OTP/Elixir
  builds (they 404): confirm an asset name with `curl -sIL` (200), download it,
  hash the file yourself, then pin that hash. `nodejs.org/dist/vX/SHASUMS256.txt`
  and rust-lang `*.tar.gz.sha256` sidecars do exist.
- Repo guard scripts must not depend on `rg`: `make install` step 1 runs the
  contract check BEFORE the apt step that installs ripgrep, so on a fresh host
  it dies with `rg: command not found` and the follow-on "missing required value"
  errors are misleading (nothing is checked). Use POSIX `grep` in guards that run
  before package install (`grep -Fqx` for exact lines, `grep -Eq` for scans,
  `grep -rnE` where `rg` was recursive — plain `grep -n E dir/` skips directories
  and silently passes). Re-run the guard self-tests under
  `env -i PATH=/usr/bin:/bin` to prove zero external deps.
- Before answering "does this target need root?" for a repo, enumerate every
  branch — `git for-each-ref` then `git show <branch>:Makefile` — branches drift
  and the checked-out one is not representative.
- `npm ci` rewrites `yarn.lock` in repos carrying both lockfiles; `git checkout`
  it afterwards or the diff claims a dependency change you never made.
- Do not clobber existing brew/asdf/rustup installs: skip a tool when the exact
  pinned version is already on PATH; install only what is missing or mismatched.
- A build that dies with `No space left on device` after a VM disk resize means the
  resize never reached the filesystem — clippy/tests are the usual victims because
  they need GBs the release build does not. `lsblk` showing a partition larger than
  the LV is the tell; fix with `sudo pvresize <part>`,
  `sudo lvextend -l +100%FREE /dev/<vg>/<lv>`, `sudo resize2fs /dev/<vg>/<lv>`.

## Verify checklist

Run the gates above, then report per-item pass/fail. `cc`/`gcc`, GStreamer dev
headers and `pkg-config` come from the sudo package step, so `cargo clippy` and
native builds stay UNVERIFIED until that step ran — say so explicitly rather than
calling it failed or passed.

## Support files

- `references/fresh-ubuntu-toolchains.md` — exact URLs, checksums, install flags,
  apt list, rc lines for Ubuntu 24.04 amd64.
- `templates/sudo-dev-packages.sudoers` — narrow NOPASSWD drop-in so a dev user can
  run the package step unattended.
