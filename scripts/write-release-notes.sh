#!/usr/bin/env bash
# Write priv/release-notes.json into a built release, so the dashboard can name the deployed release and what
# changed in it.
#
#   write-release-notes.sh <release-app-dir> <version> [notes-file] [trailer]
#
# One implementation, called by BOTH packagers: scripts/package-signed-update.sh for an update package and
# iso-builder/build.sh for the appliance image. It used to exist only in the packaging script, which is exactly why
# the ISO shipped releases whose dashboard reported no notes at all.
set -euo pipefail

APP_DIR="${1:?release app dir (…/lib/blackgate-<vsn>)}"
VERSION="${2:?version}"
NOTES_FILE="${3:-iso-builder/release-notes.txt}"
TRAILER="${4:-Packaged by scripts/package-signed-update.sh}"

[ -d "$APP_DIR" ] || { echo "release app dir not found: $APP_DIR" >&2; exit 65; }

# A hand-written notes file is used when one exists; otherwise the recent commit subjects.
CHANGES="$(if [ -r "$NOTES_FILE" ]; then cat "$NOTES_FILE"; else git log --pretty='- %s' -12; fi)"

NOTES_JSON="$APP_DIR/priv/release-notes.json"
mkdir -p "$APP_DIR/priv"
{
  printf '{\n  "version": "%s",\n  "released_on": "%s",\n  "changes": [\n' "$VERSION" "$(date +%F)"
  printf '%s\n' "$CHANGES" | sed -e 's/[\\"]//g' -e 's/^- //' -e '/^[[:space:]]*$/d' | awk '{printf "    \"%s\",\n", $0}'
  printf '    "%s"\n  ]\n}\n' "$TRAILER"
} > "$NOTES_JSON"

python3 -c "import json,sys; json.load(open('$NOTES_JSON')); print('release notes valid:', '$NOTES_JSON')"

# Running under sudo writes the file as root inside a tree the operator owns, which then blocks the next non-root
# packaging run. Hand it back.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
  chown "$SUDO_USER" "$NOTES_JSON" 2>/dev/null || true
fi
