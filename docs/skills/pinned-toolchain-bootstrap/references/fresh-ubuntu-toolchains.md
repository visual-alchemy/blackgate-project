# Fresh Ubuntu 24.04 host — pinned toolchains (amd64)

Reference implementation (repo-local, keep it the single source of truth when it
exists): `blackgate-project/scripts/bootstrap_pinned_tools.sh`.

## Prefix layout

    ~/.blackgate/toolchain/          (override: BLACKGATE_TOOLCHAIN_PREFIX)
      otp/         Erlang/OTP 27.0.1, ./Install -sasl run, prebuilt erts-15.0.1
      elixir/      precompiled Elixir 1.18.2
      node/        Node 20.19.0
      rust/        rustc/cargo/rustfmt/clippy 1.96.0
      bin/         symlink farm (erl erlc escript epmd elixir elixirc iex mix
                   node npm npx cargo rustc rustfmt clippy-driver)
      downloads/   hash-verified cache; re-verify before trusting a cached file
      .install-complete   idempotence marker

## Assets, checksums, install flags

| Tool | URL | sha256 | notes |
|---|---|---|---|
| OTP 27.0.1 | https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-27.0.1.tar.gz | `b7a558160ef2657abea72347bff64dfec7be75e4b117ed03616ee4bd92d0733f` | no sidecar — hash the downloaded file yourself. Ships prebuilt erts: `printf 'n\n' \| ./Install -sasl <root>` ('n' keeps start_sasl, matching CI-built OTP). |
| Elixir 1.18.2 | https://builds.hex.pm/builds/elixir/v1.18.2-otp-27.zip | `694e56534db9074e78a9e0b53c5f5281b60e8ea83c5abfcbdeed70c20387ddee` | no sidecar. Extract with `python3 -c 'import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])'` (do not assume unzip exists). `chmod +x bin/{elixir,elixirc,iex,mix}`. |
| Node 20.19.0 | https://nodejs.org/dist/v20.19.0/node-v20.19.0-linux-x64.tar.xz | `b4e336584d62abefad31baecff7af167268be9bb7dd11f1297112e6eed3ca0d5` | official SHA in https://nodejs.org/dist/v20.19.0/SHASUMS256.txt; usually identical to the repo Dockerfile `NODE_SHA256` ARG — reuse it. |
| Rust 1.96.0 | https://static.rust-lang.org/dist/rust-1.96.0-x86_64-unknown-linux-gnu.tar.gz | `c1130e4f7976f230766ab062b105b1fb050d6a78177db2246a5878fd6a589680` | sidecar `…tar.gz.sha256` exists. Install line: `install.sh --prefix="$P/rust" --components=rustc,rust-std-x86_64-unknown-linux-gnu,cargo,rustfmt-preview,clippy-preview`. |

Confirm any asset name with `curl -sIL <url>` → 200 before pinning it; these mirrors
have no browsable listings.

## System packages (sudo; Makefile/CI step, not the bootstrap script)

apt (Ubuntu 24.04 baseline):

    build-essential pkg-config git curl ca-certificates xz-utils unzip ripgrep ffmpeg
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good
    gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-vaapi
    libsrt-gnutls-dev libglib2.0-dev libncurses6 libssl3t64

`ripgrep` is not optional when repo guard scripts (`scripts/check_*contract*.sh`)
call `rg` under `set -euo pipefail` — a missing `rg` kills the guard before any
real check runs. `cc`/`gcc` (build-essential) + the GStreamer dev packages are what
`cargo clippy` / native builds need.

dnf equivalent: `gcc gcc-c++ make pkgconfig git curl ffmpeg gstreamer1-devel
gstreamer1-plugins-base-devel gstreamer1-plugins-good gstreamer1-plugins-bad-free
gstreamer1-plugins-bad-free-devel srt-devel glib2-devel`.
macOS (dev-only): `brew install gstreamer srt glib pkg-config ffmpeg ripgrep`.

## rc lines (append idempotently, marker = `blackgate toolchain`)

    export PATH="$HOME/.blackgate/toolchain/bin:$HOME/.blackgate/toolchain/otp/bin:$HOME/.blackgate/toolchain/elixir/bin:$HOME/.blackgate/toolchain/node/bin:$HOME/.blackgate/toolchain/rust/bin:$PATH"
    export ERL_ROOT="$HOME/.blackgate/toolchain/otp"

Append to BOTH `~/.bashrc` and `~/.profile`. Login shells (`ssh host 'make build'`,
`bash -lc`) read `.profile` and never `.bashrc`; if only `.bashrc` is written, the
remote build silently uses whatever stub toolchain the host had.

## Makefile target shape

    install:
    	@set -e; \
    	export PATH="$$HOME/.blackgate/toolchain/bin:...:$$PATH"; \
    	export ERL_ROOT="$$HOME/.blackgate/toolchain/otp"; \
    cmd_one; \
    cmd_two

One shell per target (backslash continuations) so the `set -e` gate covers every
step; `@` on the first line stops make echoing the recipe; `$$` escapes shell
variables. Export PATH at the TOP of the target, before any step that may assume
it.

## Verification commands

    bash -n scripts/bootstrap_pinned_tools.sh
    BLACKGATE_FORCE_TOOLS=1 bash scripts/bootstrap_pinned_tools.sh   # real rerun
    bash scripts/bootstrap_pinned_tools.sh                          # idempotent
    grep -c '<marker>' ~/.bashrc ~/.profile                         # stays constant
    bash -lc 'mix --version; node --version; rustc --version'       # login shell
    env -i HOME="$HOME" PATH="<prefix>/bin:/usr/bin:/bin" bash -c 'elixir --version'
