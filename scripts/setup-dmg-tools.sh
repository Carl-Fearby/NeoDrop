#!/usr/bin/env bash
#
# Install the one build-time tool that is not part of macOS: dmgbuild.
#
# A DMG's icon positions and background live in a binary .DS_Store inside the image. Writing that
# file is what dmgbuild does; the alternative is AppleScript driving Finder, which needs Automation
# permission and a logged-in GUI session, so it cannot run in a build script or CI.
#
# This creates .venv/ in the repository root (gitignored) and installs dmgbuild into it.
# scripts/package.sh then produces the drag-and-drop DMG. Without it, package.sh still builds a
# plain DMG, so this stays optional.
#
# Usage: scripts/setup-dmg-tools.sh [--force]
#
# Exit status: 0 on success, 1 on failure, 2 on bad usage.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
VENV="$ROOT/.venv"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'setup-dmg-tools.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ -x "$VENV/bin/python" ] && [ "$FORCE" -eq 0 ]; then
  if "$VENV/bin/python" -c 'import dmgbuild' >/dev/null 2>&1; then
    printf 'dmgbuild is already installed in %s\n' "$VENV"
    exit 0
  fi
fi

command -v python3 >/dev/null 2>&1 || { printf 'python3 is required\n' >&2; exit 1; }

printf 'Creating %s…\n' "$VENV"
python3 -m venv "$VENV"

printf 'Installing dmgbuild…\n'
"$VENV/bin/python" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || true
"$VENV/bin/python" -m pip install --quiet dmgbuild

"$VENV/bin/python" -c 'import dmgbuild, ds_store' \
  || { printf 'dmgbuild installed but cannot be imported\n' >&2; exit 1; }

printf '\nDone. scripts/package.sh will now build the drag-and-drop DMG.\n'
printf 'Note: this venv is a build-time tool only; the app itself has no Python dependency.\n'
