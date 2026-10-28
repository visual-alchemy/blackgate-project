#!/usr/bin/env bash
# Write priv/release-notes.json into a built release, so the dashboard can name the deployed release and what
# changed in it.
#
#   write-release-notes.sh <release-app-dir> <version> [notes-file] [trailer] [base-ref]
#
# One implementation, called by BOTH packagers: scripts/package-signed-update.sh for an update package and
# iso-builder/build.sh for the appliance image. It used to exist only in the packaging script, which is exactly why
# the ISO shipped releases whose dashboard reported no notes at all.
#
# The changes it writes are the DELTA from a base commit (the release already deployed, else the previous
# release-version stamp), and the base it used is recorded in the file, so a later build can diff against THIS
# release exactly. It is never "the last 12 commits", which described work the release did not carry.
set -euo pipefail

APP_DIR="${1:?release app dir (…/lib/blackgate-<vsn>)}"
VERSION="${2:?version}"
NOTES_FILE="${3:-iso-builder/release-notes.txt}"
TRAILER="${4:-Packaged by scripts/package-signed-update.sh}"

[ -d "$APP_DIR" ] || { echo "release app dir not found: $APP_DIR" >&2; exit 65; }

# Which commits belong IN this release. This used to be `git log -12`, which lists whatever was committed last
# whether or not the release carries it: a build once shipped a changelog whose lines came from the previous
# release, and one named two commits the attached release had not changed at all. The notes are therefore the
# delta from a BASE commit, resolved in this order and recorded in the file so the NEXT build can diff against
# this release exactly instead of guessing:
#   1. explicit -- 5th argument, or $RELEASE_NOTES_BASE
#   2. the release currently deployed under $BLACKGATE_ROOT/current (its notes carry "commit")
#   3. the previous stamp of iso-builder/release-version (the boundary of the release before this one)
#   4. none -- then the notes SAY they are not a delta rather than presenting 12 commits as the release's content.
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

deployed_commit() {
  local root cur notes
  root="${BLACKGATE_ROOT:-/opt/blackgate}"
  cur="$(readlink -f "$root/current" 2>/dev/null)" || return 0
  [ -n "$cur" ] || return 0
  notes="$(ls "$cur"/lib/blackgate-*/priv/release-notes.json 2>/dev/null | head -1)"
  [ -n "$notes" ] || return 0
  sed -n 's/.*"commit": *"\([0-9a-f]\{7,40\}\)".*/\1/p' "$notes" | head -1
  return 0
}

# The most recent commit at which release-version held a DIFFERENT value than the release being built: that is
# where the previous release started, so the commits after it are the ones this release adds.
previous_stamp() {
  local c v
  while read -r c; do
    v="$(git show "$c:iso-builder/release-version" 2>/dev/null | tr -d '\r\n')" || continue
    [ -n "$v" ] || continue
    if [ "$v" != "$VERSION" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done < <(git log --format=%H -- iso-builder/release-version 2>/dev/null | head -20)
  return 0
}

BASE_REF="${5-${RELEASE_NOTES_BASE:-}}"
BASE=""
BASE_SOURCE=""

if [ -n "$BASE_REF" ]; then
  BASE="$BASE_REF"
  BASE_SOURCE="given"
elif BASE="$(deployed_commit)" && [ -n "$BASE" ]; then
  BASE_SOURCE="the deployed release"
elif BASE="$(previous_stamp)" && [ -n "$BASE" ]; then
  BASE_SOURCE="the previous release stamp"
else
  BASE=""
fi

# A hand-written notes file still wins: it is the one place an operator can say what shoppers should read.
if [ -r "$NOTES_FILE" ]; then
  CHANGES="$(cat "$NOTES_FILE")"
  RANGE="hand-written $(basename "$NOTES_FILE")"
elif [ -n "$BASE" ] && git cat-file -e "$BASE^{commit}" 2>/dev/null; then
  # docs/chore/style/test/ci commits are not what an operator reads on the dashboard, and listing them is how a
  # notes file starts describing the tree instead of the release. Both subject styles count: `chore(x):` and the
  # `chore: ...` this repo also uses.
  CHANGES="$(git log --pretty='- %s' "$BASE"..HEAD 2>/dev/null | grep -vE '^- (docs|chore|style|test|ci)(\(|:)' || true)"
  if [ -z "$CHANGES" ]; then
    CHANGES="- nothing operator-facing changed between $(git rev-parse --short "$BASE" 2>/dev/null) and $(git rev-parse --short HEAD 2>/dev/null)"
  fi
  RANGE="$(git rev-parse --short "$BASE" 2>/dev/null)..$(git rev-parse --short HEAD 2>/dev/null) (base: $BASE_SOURCE)"
else
  CHANGES="$(git log --pretty='- %s' -12 2>/dev/null | grep -vE '^- (docs|chore|style|test|ci)(\(|:)' || true)"
  RANGE="last 12 commits - NOT a delta: no base release could be resolved"
fi

NOTES_JSON="$APP_DIR/priv/release-notes.json"
mkdir -p "$APP_DIR/priv"
{
  printf '{\n  "version": "%s",\n  "released_on": "%s",\n  "commit": "%s",\n  "range": "%s",\n  "changes": [\n' \
    "$VERSION" "$(date +%F)" "$COMMIT" "$(printf '%s' "$RANGE" | sed -e 's/["\\]//g')"
  printf '%s\n' "$CHANGES" | sed -e 's/[\\"]//g' -e 's/^- //' -e '/^[[:space:]]*$/d' | awk '{printf "    \"%s\",\n", $0}'
  printf '    "%s"\n  ]\n}\n' "$TRAILER"
} > "$NOTES_JSON"

python3 -c "import json,sys; json.load(open('$NOTES_JSON')); print('release notes valid:', '$NOTES_JSON')"

# Running under sudo writes the file as root inside a tree the operator owns, which then blocks the next non-root
# packaging run. Hand it back.
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && id "$SUDO_USER" >/dev/null 2>&1; then
  chown "$SUDO_USER" "$NOTES_JSON" 2>/dev/null || true
fi
