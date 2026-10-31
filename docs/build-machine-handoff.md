# Build Machine Handoff — cutting `.bgupdate` and `.iso` on a fresh box

Written while moving development to a second machine (planned base: Ubuntu 26.04
LTS). The session database is **not** carried over; readable context is the two
memory files plus `docs/memory/01-LOGS/`. This document is the build-side
inventory: what a fresh box needs before it can produce a signed update package
and a bootable image.

---

## 1. Not in git — carry by hand

| Item | Path | Size | Why it matters | Replaceable? |
|------|------|------|----------------|--------------|
| Update signing key | `/etc/blackgate/update-private-key.pem` (0600 root) | 119 B | Signs every `.bgupdate`. Appliances verify with the paired public key, so regenerating it makes **every deployed box reject all future updates**. | No |
| Gateway env | `/etc/blackgate/blackgate.env` (0600 root) | small | License server URL + token; appliance activation and heartbeat | Only via the license server account |
| Desktop Video deb | `iso-builder/files/blackmagic-desktopvideo.deb` | 250 MB | Without it the gateway runs but no frames reach the SDI card. `16.4a1` is the version verified with our DKMS setup. | Download from Blackmagic — pin the same version |
| Base ISO | `iso-builder/ubuntu-24.04.5-live-server-amd64.iso` | 3.9 GB | `build.sh` extracts it with xorriso and repacks it | Download — must match the release string in `autoinstall/user-data` and `packages.list` |
| DeckLink GStreamer plugin | `iso-builder/files/libgstdecklink.so` | ~1 MB | DeckLink sinks | Yes — rebuilt by `build.sh` step 1 (GStreamer clone + vendored SDK) |
| Release notes | `iso-builder/release-notes.txt` | small | `build.sh` bakes it into the image when present; it is absent today, so an appliance installed from the ISO reports no release notes | Yes |
| Hermes gateway state | `~/.hermes/.env`, `~/.ssh`, `gh auth` | small | Only needed if the gateway and repo pushes move to the new box too | Yes — re-authorize |

Copy the signing key as root, mode `600`, on physical media. Never through chat
or a shared clipboard.

---

## 2. From the repo, with network

- **Toolchain**: `scripts/bootstrap_pinned_tools.sh` → OTP 27.0.1, Elixir 1.18.2,
  Node 20.19.0, Rust 1.96.0 into `~/.blackgate/toolchain`.
- **Host packages**: `sudo make install` → `build-essential pkg-config git curl
  ca-certificates xz-utils unzip ripgrep ffmpeg procps`.
- **ISO extras** (checked by `build.sh` pre-flight, all required):
  `xorriso`, `mkfs.vfat` (dosfstools), `fdisk`, `git`, `meson`, `ninja`, `mix`,
  `npm`, `dpkg-scanpackages` (dpkg-dev).
- **Network during the build**: `mix deps.get`, `npm --prefix web_app ci`,
  `apt-get update` before the pool is resolved (deliberately against an empty
  dpkg status, so the pool is complete for a fresh machine), and a `git clone`
  of GStreamer for `libgstdecklink.so`. The **appliance** is offline; the build
  machine is not.
- The DeckLink SDK is vendored in the repo (`native/vendor/decklink-sdk`), so
  nothing to download from Blackmagic for the plugin itself.

---

## 3. Environment the build reads

`config/runtime.exs` reads `LICENSE_SERVER_URL`, `SECRET_KEY_BASE`, `PHX_HOST`,
`PORT`, `API_AUTH_USERNAME`, `API_AUTH_PASSWORD`, `BLACKGATE_STATS_SOCKET`,
`DNS_CLUSTER_QUERY`, `VICTORIOMETRICS_HOST`, `VICTORIOMETRICS_PORT`.

`LICENSE_SERVER_URL` matters most: `build.sh` takes it from the environment and
otherwise greps the `Makefile`. If neither has it, the image falls back to
`http://localhost:3000` and **license activation never works on the appliance**.
Set it explicitly on the new box (env var is enough).

---

## 4. When the base becomes 26.04

- `build.sh` clones GStreamer **tag 1.24.2** to build the DeckLink plugin. On a
  26.04 base (GStreamer 1.28.x) that tag has to move with it, otherwise a 1.24
  plugin is installed against a 1.28 runtime.
- `iso-builder/packages.list` and the apt pool follow the new distro's index.
- `autoinstall/user-data` carries the release string (currently `24.04.5`).
- `iso-builder/release-version` and `release-notes.txt` are inputs, not outputs.
- **Why the move**: `gst-libav` 1.24.1 (Ubuntu 24.04) leaks ~233 bytes per
  decoded frame — 20 MB/h for a bare realtime decode chain, ~47 MB/h per live
  SDI route. 1.26.6 measured flat over two hours. Debian 13 ships 1.26.**2**,
  older than the verified version; Ubuntu 26.04 ships 1.28.x. Details and all
  the disproved hypotheses: `docs/memory/01-LOGS/2026-10-28-session-2.md`.

---

## 5. Disk budget and first-run order

Budget ~15 GB free: base ISO 3.9 GB, its extraction, the apt pool, plus
`web_app/node_modules` (207 MB), `deps` (19 MB), `_build` (123 MB) and the
output image.

Order that keeps failures cheap:

1. bootstrap the pinned toolchain, `sudo make install`, install the ISO extras
2. `git clone` the repo (`rust-decklink-duo2`) and restore the two memory files
3. place the four non-git inputs: signing key, gateway env, Desktop Video deb, base ISO
4. `MIX_ENV=prod mix release` + native engine build, then the full test suite
5. package a `.bgupdate` and verify its signature, test-install it on the dev box
6. only then build and boot the ISO
