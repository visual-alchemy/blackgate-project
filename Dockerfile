ARG BUILDER_IMAGE="hexpm/elixir:1.18.2-erlang-27.0.1-ubuntu-noble-20260509.1"
ARG RUNNER_IMAGE="ubuntu:24.04"
ARG NODE_VERSION="20.19.0"
ARG NODE_SHA256="b4e336584d62abefad31baecff7af167268be9bb7dd11f1297112e6eed3ca0d5"
ARG GST_VERSION="1.24.2"
ARG HEX_VERSION="2.3.1"
ARG REBAR_VERSION="3.22.0"
ARG REBAR_URL="https://github.com/erlang/rebar3/releases/download/3.22.0/rebar3"
ARG REBAR_SHA512="162f54857c052f63e4f13893b646ba1bb7b8aee3415f11b8da668c9d4721a5858ace6f556a5e7d011467db0e8c35aa16a8fcfea5af8b5bc9a88e980f8027f3d6"

FROM ${BUILDER_IMAGE} AS builder

ARG NODE_VERSION
ARG NODE_SHA256
ARG GST_VERSION
ARG HEX_VERSION
ARG REBAR_VERSION
ARG REBAR_URL
ARG REBAR_SHA512

ENV MIX_ENV="prod" \
    DEBIAN_FRONTEND="noninteractive" \
    ERL_AFLAGS="+S 1:1 +JMsingle true"

# Install build dependencies
RUN apt-get update -y \
    && apt-get install -y build-essential git curl ca-certificates xz-utils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install checksum-pinned Node.js for required amd64 production target
RUN curl -fsSLo /tmp/node.tar.xz \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    && echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner \
    && rm /tmp/node.tar.xz \
    && node --version \
    && npm --version

# Install exact Rust toolchain used by rust-toolchain.toml
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain 1.96.0 \
        --component clippy --component rustfmt
ENV PATH="/root/.cargo/bin:$PATH"

# Install GStreamer and related libraries for the Rust engine
RUN apt-get update -y \
    && apt-get install -y \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-libav \
    libsrt-gnutls-dev \
    libglib2.0-dev \
    pkg-config \
    && apt-get clean

# =============================================================================
# Build gst-plugins-bad from source with DeckLink plugin enabled
# =============================================================================
# The Ubuntu packaged gst-plugins-bad does not use bundled proprietary headers
# because it depends on proprietary Blackmagic SDK headers.
# We compile just the decklink plugin from source and install it alongside
# the system-packaged plugins.

# Install build deps for gst-plugins-bad (meson, ninja, etc.)
RUN apt-get update -y \
    && apt-get install -y \
    meson \
    ninja-build \
    python3-pip \
    libgstreamer-plugins-bad1.0-dev \
    && apt-get clean

# Copy DeckLink SDK headers into the system include path
COPY native/vendor/decklink-sdk /usr/include/decklink

# Clone, configure, and build ONLY the decklink plugin from gst-plugins-bad
# Version pinned to match Ubuntu 24.04 GStreamer
RUN cd /tmp \
    && git clone --depth 1 --branch "${GST_VERSION}" https://gitlab.freedesktop.org/gstreamer/gstreamer.git \
    && cd gstreamer/subprojects/gst-plugins-bad \
    && meson setup builddir \
        -Ddecklink=enabled \
        --prefix=/usr \
    && ninja -C builddir -j$(nproc) sys/decklink/libgstdecklink.so \
    && cp builddir/sys/decklink/libgstdecklink.so \
        /usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/gstreamer-1.0/ \
    && rm -rf /tmp/gstreamer

# Prepare build directory
WORKDIR /app

# Copy mix dependencies
COPY mix.exs mix.lock rust-toolchain.toml ./
# Install exact Hex release from GitHub source (bypasses builds.hex.pm DNS)
RUN mix archive.install github hexpm/hex tag "v${HEX_VERSION}" --force
# Pin Rebar directly so builds do not depend on Mix's fixed download timeout.
RUN curl -fsSLo /tmp/rebar3 --retry 5 --retry-all-errors "${REBAR_URL}" \
  && echo "${REBAR_SHA512}  /tmp/rebar3" | sha512sum -c - \
  && mix local.rebar rebar3 /tmp/rebar3 --force \
  && rm /tmp/rebar3
ENV HEX_HTTP_TIMEOUT="120"
ENV HEX_HTTP_CONCURRENCY="2"
RUN for attempt in 1 2 3; do \
      mix deps.get && break; \
      if [ "$attempt" = "3" ]; then exit 1; fi; \
      sleep 5; \
    done
RUN mkdir config

# Copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy the rest of the application code
COPY priv priv
COPY lib lib
COPY native/Makefile native/Makefile
COPY native/rust native/rust
COPY web_app web_app
COPY rel rel

# Build the Rust engine
RUN cd native && make

# Build the web application
RUN cd web_app \
    && npm install \
    && npm run build

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

# Compile the Elixir application and build the release in a single layer
# Explicitly remove any existing release dir instead of using --overwrite,
RUN mix compile \
    && mix release --overwrite

# Start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV LC_ALL="en_US.UTF-8"
ENV MIX_ENV="prod"
# Use IPv4 instead of IPv6 for Erlang distribution
ENV ERL_AFLAGS="-proto_dist inet_tcp"
# Set the DATABASE_DATA_DIR environment variable to point to the mounted volume
ENV DATABASE_DATA_DIR="/app/khepri"

# Install runtime dependencies
RUN apt-get update -y && \
    apt-get install -y \
    ffmpeg \
    libstdc++6 \
    openssl \
    libssl3t64 \
    libncurses6 \
    locales \
    iptables \
    sudo \
    tini \
    curl \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-libav \
    gstreamer1.0-vaapi \
    libcjson1 \
    libsrt1.5-gnutls \
    libgstreamer1.0-0 \
    libgstreamer-plugins-base1.0-0 \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Copy the compiled DeckLink plugin from the builder stage
COPY --from=builder /usr/lib/*/gstreamer-1.0/libgstdecklink.so /usr/lib/x86_64-linux-gnu/gstreamer-1.0/

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

WORKDIR "/app"

# Create directory structure for mounted volumes
# These directories will be overridden by the volumes
RUN mkdir -p /app/khepri /app/backup && \
    chmod -R 777 /app/khepri /app/backup

# Copy the release from the builder stage
COPY --from=builder /app/_build/prod/rel/blackgate ./

# Fix Windows line endings (CRLF -> LF) for all shell scripts in the release
COPY run.sh run.sh
RUN sed -i 's/\r$//' run.sh && chmod +x run.sh && \
    find /app -name "*.sh" -type f -exec sed -i 's/\r$//' {} \; && \
    find /app/bin -type f -exec sed -i 's/\r$//' {} \; && \
    find /app/releases -type f -name "*.sh" -exec sed -i 's/\r$//' {} \; && \
    sed -i 's/\r$//' /app/releases/*/elixir && \
    sed -i 's/\r$//' /app/releases/*/iex && \
    chmod +x /app/bin/* && \
    chmod +x /app/releases/*/*.sh 2>/dev/null || true

# Set the entrypoint
ENTRYPOINT ["/usr/bin/tini", "-s", "-g", "--", "/app/run.sh"]
CMD ["/app/bin/server"]
