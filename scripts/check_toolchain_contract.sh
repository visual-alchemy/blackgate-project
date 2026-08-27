#!/usr/bin/env bash
set -euo pipefail

root="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      root="$2"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

require_exact() {
  local file="$1"
  local expected="$2"

  if [[ ! -f "$root/$file" ]] ||
    ! rg --fixed-strings --line-regexp --quiet -- "$expected" "$root/$file"; then
    echo "$file missing required value: $expected" >&2
    return 1
  fi
}

require_exact .tool-versions 'elixir 1.18.2-otp-27'
require_exact .tool-versions 'erlang 27.0.1'
require_exact .tool-versions 'nodejs 20.19.0'
require_exact rust-toolchain.toml 'channel = "1.96.0"'
require_exact Dockerfile 'ARG BUILDER_IMAGE="hexpm/elixir:1.18.2-erlang-27.0.1-ubuntu-noble-20260509.1"'
require_exact Dockerfile 'ARG RUNNER_IMAGE="ubuntu:24.04"'
require_exact Dockerfile 'ARG NODE_VERSION="20.19.0"'
require_exact Dockerfile 'ARG GST_VERSION="1.24.2"'
require_exact Dockerfile 'ARG HEX_VERSION="2.3.1"'
require_exact Dockerfile 'ARG REBAR_VERSION="3.22.0"'
require_exact Dockerfile 'ARG REBAR_URL="https://github.com/erlang/rebar3/releases/download/3.22.0/rebar3"'
require_exact Dockerfile 'ARG REBAR_SHA512="162f54857c052f63e4f13893b646ba1bb7b8aee3415f11b8da668c9d4721a5858ace6f556a5e7d011467db0e8c35aa16a8fcfea5af8b5bc9a88e980f8027f3d6"'
require_exact Dockerfile 'ENV HEX_HTTP_TIMEOUT="120"'
require_exact Dockerfile 'ENV HEX_HTTP_CONCURRENCY="2"'
require_exact Dockerfile 'RUN mix archive.install github hexpm/hex tag "v${HEX_VERSION}" --force'
require_exact Dockerfile 'RUN curl -fsSLo /tmp/rebar3 --retry 5 --retry-all-errors "${REBAR_URL}" \'
require_exact Dockerfile '  && echo "${REBAR_SHA512}  /tmp/rebar3" | sha512sum -c - \'
require_exact Dockerfile '  && mix local.rebar rebar3 /tmp/rebar3 --force \'
require_exact Dockerfile 'RUN for attempt in 1 2 3; do \'
require_exact Dockerfile '      mix deps.get && break; \'
require_exact Dockerfile '      if [ "$attempt" = "3" ]; then exit 1; fi; \'
require_exact iso-builder/build.sh 'UBUNTU_ISO="$SCRIPT_DIR/ubuntu-24.04.4-live-server-amd64.iso"'
require_exact iso-builder/autoinstall/user-data '    - libssl3t64'
require_exact iso-builder/autoinstall/user-data '    - gstreamer1.0-plugins-bad'
require_exact iso-builder/autoinstall/user-data '    - libsrt1.5-gnutls'
require_exact .github/workflows/build-iso.yml '    runs-on: ubuntu-24.04'
require_exact .github/workflows/build-iso.yml '          otp-version: 27.0.1'
require_exact .github/workflows/build-iso.yml '          elixir-version: 1.18.2'
require_exact .github/workflows/build-iso.yml '          node-version: 20.19.0'
require_exact .github/workflows/build-iso.yml '            https://releases.ubuntu.com/24.04.4/ubuntu-24.04.4-live-server-amd64.iso'

if rg --quiet -- 'Ubuntu 22\.04|Jammy|ubuntu:jammy|/var/run/docker\.sock|Docker container|host networking' \
  "$root/iso-builder/build.sh" \
  "$root/iso-builder/autoinstall/user-data" \
  "$root/.github/workflows/build-iso.yml"; then
  echo "ISO build contract contains stale Jammy or Docker-appliance behavior" >&2
  exit 1
fi

if rg --quiet -- 'apt(-get)? install[^\n]*rebar3|^[[:space:]]*rebar3[[:space:]\\]*$' "$root/Dockerfile"; then
  echo "Dockerfile must not install distro rebar3 because it pulls another OTP" >&2
  exit 1
fi

echo "Toolchain contract passed"
