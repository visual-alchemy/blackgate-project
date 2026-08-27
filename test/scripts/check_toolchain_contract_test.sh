#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/scripts/check_toolchain_contract.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

cp "$repo_root/.tool-versions" "$fixture/.tool-versions"
cp "$repo_root/Dockerfile" "$fixture/Dockerfile"
mkdir -p "$fixture/iso-builder/autoinstall" "$fixture/.github/workflows"
cp "$repo_root/iso-builder/build.sh" "$fixture/iso-builder/build.sh"
cp "$repo_root/iso-builder/autoinstall/user-data" "$fixture/iso-builder/autoinstall/user-data"
cp "$repo_root/.github/workflows/build-iso.yml" "$fixture/.github/workflows/build-iso.yml"
printf '%s\n' '[toolchain]' 'channel = "stable"' > "$fixture/rust-toolchain.toml"

if "$checker" --root "$fixture"; then
  echo "checker accepted mismatched toolchain" >&2
  exit 1
fi

printf '%s\n' \
  'elixir 1.18.2-otp-27' \
  'erlang 27.0.1' \
  'nodejs 20.19.0' > "$fixture/.tool-versions"

printf '%s\n' \
  '[toolchain]' \
  'channel = "1.96.0"' \
  'components = ["clippy", "rustfmt"]' \
  'profile = "minimal"' > "$fixture/rust-toolchain.toml"

cat > "$fixture/Dockerfile" <<'EOF'
ARG BUILDER_IMAGE="hexpm/elixir:1.18.2-erlang-27.0.1-ubuntu-noble-20260509.1"
ARG RUNNER_IMAGE="ubuntu:24.04"
ARG NODE_VERSION="20.19.0"
ARG GST_VERSION="1.24.2"
ARG REBAR_VERSION="3.22.0"
ARG REBAR_URL="https://github.com/erlang/rebar3/releases/download/3.22.0/rebar3"
ARG REBAR_SHA512="162f54857c052f63e4f13893b646ba1bb7b8aee3415f11b8da668c9d4721a5858ace6f556a5e7d011467db0e8c35aa16a8fcfea5af8b5bc9a88e980f8027f3d6"
RUN curl -fsSLo /tmp/rebar3 --retry 5 --retry-all-errors "${REBAR_URL}" \
  && echo "${REBAR_SHA512}  /tmp/rebar3" | sha512sum -c - \
  && mix local.rebar rebar3 /tmp/rebar3 --force \
  && rm /tmp/rebar3
EOF

if "$checker" --root "$fixture"; then
  echo "checker accepted fragile Hex dependency fetch settings" >&2
  exit 1
fi

cat >> "$fixture/Dockerfile" <<'EOF'
ENV HEX_HTTP_TIMEOUT="120"
ENV HEX_HTTP_CONCURRENCY="2"
RUN for attempt in 1 2 3; do \
      mix deps.get && break; \
      if [ "$attempt" = "3" ]; then exit 1; fi; \
      sleep 5; \
    done
EOF

if "$checker" --root "$fixture"; then
  echo "checker accepted mutable Hex installer" >&2
  exit 1
fi

cat >> "$fixture/Dockerfile" <<'EOF'
ARG HEX_VERSION="2.3.1"
RUN mix archive.install github hexpm/hex tag "v${HEX_VERSION}" --force
EOF

"$checker" --root "$fixture"

sed -i.bak 's/ubuntu-24\.04\.4-live-server-amd64/ubuntu-22.04.5-live-server-amd64/' \
  "$fixture/iso-builder/build.sh"
if "$checker" --root "$fixture"; then
  echo "checker accepted Jammy ISO input" >&2
  exit 1
fi
mv "$fixture/iso-builder/build.sh.bak" "$fixture/iso-builder/build.sh"

printf '%s\n' 'RUN apt-get install -y rebar3' >> "$fixture/Dockerfile"
if "$checker" --root "$fixture"; then
  echo "checker accepted distro rebar3 and its OTP dependency" >&2
  exit 1
fi
