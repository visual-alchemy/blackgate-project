# OS Appliance Packaging Context (`iso-builder/`)

This folder builds the Ubuntu-based Blackgate Appliance ISO installer.

## 🛠️ Technology Stack & Environment

- **Base OS:** Ubuntu 24.04.4 live-server ISO
- **Installer Mode:** Subiquity autoinstall with NoCloud user-data
- **Script:** `build.sh` (extracts, injects autoinstall and offline packages, then repacks the ISO)

## 🚀 Setup & Execution Commands

Run from `iso-builder/` folder:
- **Build Appliance ISO:**
  ```bash
  ./build.sh
  ```
  *Note: Run on Linux as an unprivileged user; the script rejects root. Check `build.sh` for required build tools and source ISO.*
