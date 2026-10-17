#!/usr/bin/env bash
# Bootstrap the pinned Elixir/OTP/Node/Rust toolchains into a private prefix.
#
# Fresh-Ubuntu path: installs Erlang/OTP 27.0.1, Elixir 1.18.2, Node 20.19.0 and
# Rust 1.96.0 from upstream tarballs into ${HOME}/.blackgate/toolchain, exports
# them on PATH, and records the export in ~/.bashrc (idempotent). No sudo: system
# packages (GStreamer, libsrt, ripgrep, ...) are installed by `make install` step 2.
#
# ponytail: amd64 only, because the production target is amd64 and only amd64
# build asset names are pinned. Add arm64 asset names + checksums when a
# non-amd64 dev host is needed. Anything already on PATH at the exact pinned
# version is reused, so brew/asdf/rustup installs are never clobbered.

set -euo pipefail

prefix="${BLACKGATE_TOOLCHAIN_PREFIX:-$HOME/.blackgate/toolchain}"
downloads="$prefix/downloads"
marker="$prefix/.install-complete"

OTP_VERSION="27.0.1"
ELIXIR_VERSION="1.18.2"
NODE_VERSION="20.19.0"
RUST_VERSION="1.96.0"

OTP_URL="https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${OTP_VERSION}.tar.gz"
OTP_SHA256="b7a558160ef2657abea72347bff64dfec7be75e4b117ed03616ee4bd92d0733f"
ELIXIR_URL="https://builds.hex.pm/builds/elixir/v${ELIXIR_VERSION}-otp-27.zip"
ELIXIR_SHA256="694e56534db9074e78a9e0b53c5f5281b60e8ea83c5abfcbdeed70c20387ddee"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
NODE_SHA256="b4e336584d62abefad31baecff7af167268be9bb7dd11f1297112e6eed3ca0d5"
RUST_URL="https://static.rust-lang.org/dist/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
RUST_SHA256="c1130e4f7976f230766ab062b105b1fb050d6a78177db2246a5878fd6a589680"

have_elixir() { command -v mix >/dev/null 2>&1 && elixir --version 2>/dev/null | grep -q "Elixir ${ELIXIR_VERSION}"; }
have_otp() {
  command -v erl >/dev/null 2>&1 &&
    erl -noshell -eval 'io:format("~s", [erlang:system_info(system_version)]), halt().' 2>/dev/null |
    grep -q "Erlang/OTP ${OTP_VERSION%%.*}\..*erts-15\.0\.1"
}
have_node() { command -v node >/dev/null 2>&1 && [[ "$(node --version 2>/dev/null)" == "v${NODE_VERSION}" ]]; }
have_rust() { command -v rustc >/dev/null 2>&1 && rustc --version 2>/dev/null | grep -q "^rustc ${RUST_VERSION} "; }

fetch() { # url sha256 filename
  local url="$1" sha="$2" name="$3"
  if [[ -f "$downloads/$name" ]] && echo "${sha}  $downloads/$name" | sha256sum -c - >/dev/null 2>&1; then
    return 0
  fi
  echo "  fetching $name"
  curl -fSL --retry 3 --retry-all-errors -o "$downloads/$name" "$url"
  echo "${sha}  $downloads/$name" | sha256sum -c -
}

install_otp() {
  echo "Installing Erlang/OTP ${OTP_VERSION} from build tarball (prebuilt erts-15.0.1)..."
  fetch "$OTP_URL" "$OTP_SHA256" "OTP-${OTP_VERSION}.tar.gz"
  rm -rf "$prefix/otp"
  mkdir -p "$prefix/otp"
  tar -xzf "$downloads/OTP-${OTP_VERSION}.tar.gz" -C "$prefix/otp" --strip-components=1
  # non-interactive: answer "n" so start_sasl is kept, matching CI's OTP build
  printf 'n\n' | "$prefix/otp/Install" -sasl "$prefix/otp"
  # keep toolchain output out of the repo tree
  rm -rf "$prefix/otp/misc/format_man_pages" 2>/dev/null || true
}

install_elixir() {
  echo "Installing Elixir ${ELIXIR_VERSION} (precompiled, OTP 27)..."
  fetch "$ELIXIR_URL" "$ELIXIR_SHA256" "elixir-${ELIXIR_VERSION}-otp-27.zip"
  rm -rf "$prefix/elixir"
  mkdir -p "$prefix/elixir"
  python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
    "$downloads/elixir-${ELIXIR_VERSION}-otp-27.zip" "$prefix/elixir"
  chmod +x "$prefix/elixir/bin/elixir" "$prefix/elixir/bin/elixirc" "$prefix/elixir/bin/iex" "$prefix/elixir/bin/mix"
}

install_node() {
  echo "Installing Node ${NODE_VERSION}..."
  fetch "$NODE_URL" "$NODE_SHA256" "node-v${NODE_VERSION}-linux-x64.tar.xz"
  rm -rf "$prefix/node"
  mkdir -p "$prefix/node"
  tar -xJf "$downloads/node-v${NODE_VERSION}-linux-x64.tar.xz" -C "$prefix/node" --strip-components=1
}

install_rust() {
  echo "Installing Rust ${RUST_VERSION} (clippy + rustfmt) from dist tarball..."
  fetch "$RUST_URL" "$RUST_SHA256" "rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.gz"
  rm -rf "$prefix/rust-build" "$prefix/rust"
  mkdir -p "$prefix/rust-build"
  tar -xzf "$downloads/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu.tar.gz" -C "$prefix/rust-build"
  local d="$prefix/rust-build/rust-${RUST_VERSION}-x86_64-unknown-linux-gnu"
  "$d/install.sh" --prefix="$prefix/rust" \
    --components=rustc,rust-std-x86_64-unknown-linux-gnu,cargo,rustfmt-preview,clippy-preview
  rm -rf "$prefix/rust-build"
}

# --- PATH export, idempotent, survives `make install` re-runs ---

path_line='export PATH="$HOME/.blackgate/toolchain/bin:$HOME/.blackgate/toolchain/otp/bin:$HOME/.blackgate/toolchain/elixir/bin:$HOME/.blackgate/toolchain/node/bin:$HOME/.blackgate/toolchain/rust/bin:$PATH" # blackgate toolchain'
# elixir/mix are `#!/usr/bin/env elixir`; ERL must be visible to them too.
erl_line='export ERL_ROOT="$HOME/.blackgate/toolchain/otp" # blackgate toolchain'

record_path() {
  # .bashrc covers interactive shells; .profile covers login shells (`ssh host 'make build'`)
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    if [[ -f "$rc" ]] && ! grep -qF 'blackgate toolchain' "$rc"; then
      {
        echo ""
        echo "# blackgate toolchain (scripts/bootstrap_pinned_tools.sh)"
        echo "$path_line"
        echo "$erl_line"
      } >> "$rc"
      echo "  recorded toolchain PATH in $rc"
    fi
  done
}

mkdir -p "$downloads" "$prefix/bin"

# user-agnostic guard: plain `sudo make install` keeps the caller's HOME on
# Ubuntu (no always_set_home), so the toolchain lands user-local. sudo -H/-i, or
# a sudoers with always_set_home, would put everything in root's home instead.
if [[ "$(id -u)" == 0 && "$prefix" == /root/* ]]; then
  echo "warning: running as root with HOME=/root — toolchain and rc lines will land in root's home." >&2
  echo "  run as the dev user (plain 'sudo make install' preserves HOME), or set BLACKGATE_TOOLCHAIN_PREFIX." >&2
fi

# --- pinned toolchains ---

[[ ${BLACKGATE_FORCE_TOOLS:-0} == 1 ]] && rm -f "$marker"

if [[ ! -f "$marker" ]]; then
  if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "bootstrap_pinned_tools.sh: only x86_64 asset pins exist (host: $(uname -m))" >&2
    exit 1
  fi

  have_otp && echo "  Erlang/OTP ${OTP_VERSION} already on PATH" || install_otp
  install_elixir # precompiled zip is release-name-independent; always fresh
  have_node && echo "  Node v${NODE_VERSION} already on PATH" || install_node
  have_rust && echo "  Rust ${RUST_VERSION} already on PATH" || install_rust

  # expose otp + toolchain bins so `env elixir` finds erl even without .bashrc
  for b in erl erlc escript epmd; do ln -sf "$prefix/otp/bin/$b" "$prefix/bin/$b"; done
  for b in elixir elixirc iex mix; do ln -sf "$prefix/elixir/bin/$b" "$prefix/bin/$b"; done
  for b in node npm npx; do ln -sf "$prefix/node/bin/$b" "$prefix/bin/$b"; done
  for b in cargo rustc rustup clippy-driver rustfmt rust-gdb; do
    [[ -e "$prefix/rust/bin/$b" ]] && ln -sf "$prefix/rust/bin/$b" "$prefix/bin/$b"
  done
else
  echo "  toolchain already bootstrapped at $prefix"
fi

record_path # idempotent, also repairs shell rc files on re-run
touch "$marker"

echo ""
echo "Pinned toolchain ready at $prefix"
