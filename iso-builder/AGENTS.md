# OS Appliance Packaging Context (`iso-builder/`)

Welcome! This folder contains the scripts and preseed configuration to build the custom Debian-based Blackgate Appliance ISO installer.

## 🛠️ Technology Stack & Environment

- **Base OS:** Debian 12 (Bookworm) Netinst ISO
- **Installer Mode:** Preseeded Debian Auto-install / Unattended Installer
- **Script:** `build.sh` (extracts, preseeds, repacks, and generates target ISO)

## 🚀 Setup & Execution Commands

Run from `iso-builder/` folder:
- **Build Appliance ISO:**
  ```bash
  sudo ./build.sh
  ```
  *Note: Building requires system packages `xorriso`, `squashfs-tools`, and `cpio` installed, and must be executed on a Linux environment with root permissions.*
