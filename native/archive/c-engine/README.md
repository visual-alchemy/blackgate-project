# Frozen C Benchmark Oracle

This directory contains immutable C-engine source from the last pre-Rust
production baseline, `b7da650^` (`bc90a8f1b7dbd893a2b9a9198b2e011cc0adc543`).
It exists only to compare the Rust engine against known C behavior and
performance.

Production code, builds, releases, and runtime configuration must never import
or execute files from this directory. Change archived source only when fixing
the archive itself; any source change requires explicit review and a regenerated
manifest.

## Verify and build on Ubuntu 24.04

Install required packages:

```bash
apt-get update
apt-get install -y build-essential pkg-config libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev libcjson-dev libssl-dev libsrt-openssl-dev
```

Verify frozen content before every build:

```bash
make verify
make
```

Output `build/blackgate_pipeline` is benchmark-only. Do not copy it into an OTP
release, production container, ISO, or gateway installation.
