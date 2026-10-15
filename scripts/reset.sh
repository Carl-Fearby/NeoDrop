#!/usr/bin/env bash
#
# The clean-install path: remove everything NeoDrop keeps about this Mac, and nothing else.
#
# "Delete the app and reinstall" does not reset NeoDrop, and that surprises people. The app's state
# — config.json, the source index, the per-replica manifests, the deletion records, the vault
# cursors and this machine's identity — lives in Application Support, so a fresh copy of the app
# finds the old configuration and carries on. This script removes exactly that state, plus the small
# amount macOS keeps alongside it, and reports what it is *not* touching, which is the part that
# matters: your folders and the copies on the NAS are yours, and a reset must never be a way to lose
# them.
#
# Usage: scripts/reset.sh [--yes] [--app] [--keep-machine-name] [--trash]
#
#   --yes                actually delete. Without it this is a dry run that prints the plan.
#   --app                also remove /Applications/NeoDrop.app (needs write access to it)
#   --keep-machine-name  keep the machine identity, so this Mac is still "Alex's MacBook" to the
#                        others. Removes everything else.
#   --trash              move the state directory to the Trash instead of deleting it, so a reset
#                        made by mistake can be undone.
#
# Exit status: 0 when the plan ran (or the reset completed), 1 when something could not be removed,
# 2 on bad usage.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUNDLE_ID="ai.storyteller.neodrop"
APP_NAME="NeoDrop"
CONFIRM=0
REMOVE_APP=0
KEEP_IDENTITY=0
USE_TRASH=0

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) CONFIRM=1; shift ;;
    --app) REMOVE_APP=1; shift ;;
    --keep-machine-name) KEEP_IDENTITY=1; shift ;;
    --trash) USE_TRASH=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'reset.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

note() { printf '  --      %s\n' "$1"; }
plan() { printf '  remove  %s\n' "$1"; }
keep() { printf '  keep    %s\n' "$1"; }
step() { printf '\n%s\n' "$1"; }

# NEODROP_HOME is the same override the app and the end-to-end scripts use. Honouring it here means
# a test installation can be reset without touching the real one — and that has to include the part
# macOS keeps beside it: when NEODROP_HOME is set, the real installation's preferences and saved
# state belong to a *different* installation and are left alone. (They once were not, and a test run
# of this script removed the real preferences file.)
STATE="$HOME/Library/Application Support/$APP_NAME"
REAL_INSTALL=1
if [ -n "${NEODROP_HOME:-}" ]; then
  STATE="$(cd -- "$NEODROP_HOME" 2>/dev/null && pwd -P || printf '%s' "$NEODROP_HOME")"
  REAL_INSTALL=0
  note "NEODROP_HOME is set, so this resets that installation only: $STATE"
fi
PREFS=""
SAVED_STATE=""
BADGE_INDEX=""
if [ "$REAL_INSTALL" -eq 1 ]; then
  PREFS="$HOME/Library/Preferences/$BUNDLE_ID.plist"
  SAVED_STATE="$HOME/Library/Saved Application State/$BUNDLE_ID.savedState"
  # The badge index the Finder extension reads, which the app publishes into the extension's own
  # container (the extension is sandboxed, so that container is the only place both processes can
  # reach — see AGENTS.md). It is derived from the configuration, so it belongs in a reset: left
  # behind, the Finder would go on badging folders NeoDrop has just forgotten about, and a green tick
  # on a folder nobody is protecting any more is worse than no tick at all. Only the file is removed,
  # not the container directory: macOS owns that, and the next publish recreates the directory.
  BADGE_INDEX="$HOME/Library/Containers/$BUNDLE_ID.finder/Data/Library/Application Support/$APP_NAME/finder-status.json"
fi
INSTALLED_APP="/Applications/$APP_NAME.app"

printf '%s\n' "NeoDrop reset"
if [ "$CONFIRM" -eq 0 ]; then
  printf 'Dry run — nothing will be deleted. Add --yes to carry this out.\n'
fi

# MARK: - Is it running?

step "Running now?"
RUNNING="$(pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true)"
if [ -n "$RUNNING" ]; then
  if [ "$CONFIRM" -eq 1 ]; then
    printf 'NeoDrop is running (pid %s). Quit it from the menu bar first, then run this again.\n' "$(printf '%s' "$RUNNING" | tr '\n' ' ')" >&2
    exit 1
  fi
  note "NeoDrop is running (pid $(printf '%s' "$RUNNING" | tr '\n' ' ')) — quit it before deleting state"
else
  note "not running"
fi

# MARK: - What goes

step "State NeoDrop keeps on this Mac"

REMOVALS=()
if [ -d "$STATE" ]; then
  SIZE="$(du -sh "$STATE" 2>/dev/null | awk '{print $1}')"
  if [ "$USE_TRASH" -eq 1 ]; then
    printf '  trash   %s  (%s)\n' "$STATE" "$SIZE"
  else
    plan "$STATE  ($SIZE)"
  fi
  REMOVALS+=("$STATE")
else
  note "no state directory at $STATE"
fi

# The machine identity is part of the state directory, so "--keep-machine-name" has to carve it out
# of the removal rather than treat the directory as one unit.
IDENTITY=""
if [ "$KEEP_IDENTITY" -eq 1 ] && [ -f "$STATE/machine.json" ]; then
  IDENTITY="$(cat "$STATE/machine.json")"
  note "keeping the machine identity in $STATE/machine.json"
fi

if [ -z "$PREFS" ]; then
  note "the real installation's preferences and saved state (this is a NEODROP_HOME installation)"
elif [ -f "$PREFS" ]; then
  plan "$PREFS"
  REMOVALS+=("$PREFS")
else
  note "no preferences file (nothing has been saved yet)"
fi

if [ -n "$SAVED_STATE" ] && [ -d "$SAVED_STATE" ]; then
  plan "$SAVED_STATE"
  REMOVALS+=("$SAVED_STATE")
else
  note "no saved application state"
fi

if [ -z "$BADGE_INDEX" ]; then
  note "the real installation's Finder badge index (this is a NEODROP_HOME installation)"
elif [ -f "$BADGE_INDEX" ]; then
  # It sits inside the extension's sandbox container, which is macOS's, not ours: measured on
  # macOS 26, a process outside that container cannot create, delete or even list inside it — every
  # attempt comes back "Operation not permitted". `[ -w ]` asks the kernel the same question the
  # removal would, without changing anything, which is what a dry run has to do; without it this
  # script would promise a removal it cannot make and then report a failure that is not one.
  if [ -w "$(dirname "$BADGE_INDEX")" ]; then
    plan "$BADGE_INDEX  (what Finder badges, from the folders above)"
    REMOVALS+=("$BADGE_INDEX")
  else
    keep "$BADGE_INDEX  — inside the extension's sandbox container, which macOS refuses writes from outside: it survives this reset, and Finder can keep badging the old folders until the app publishes again"
  fi
else
  note "no Finder badge index (nothing is badged yet)"
fi

if [ -d "$INSTALLED_APP" ]; then
  if [ "$REMOVE_APP" -eq 1 ]; then
    plan "$INSTALLED_APP  (the drag-and-drop copy in Applications)"
    REMOVALS+=("$INSTALLED_APP")
  else
    keep "$INSTALLED_APP  — delete it by hand, or pass --app"
  fi
fi

LOGIN_ITEM="$(launchctl print "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null | head -1 || true)"
if launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; then
  note "registered as a login item — turn off “Launch at Login” in the app's menu, or System Settings → General → Login Items"
  [ -n "$LOGIN_ITEM" ] || true
fi

# MARK: - What stays

step "Not touched"

if [ -f "$STATE/config.json" ]; then
  # The configured folders are the user's own data and the whole point of the app. A reset that
  # deleted them would be a data-loss bug wearing a maintenance script's clothes.
  python3 - "$STATE/config.json" <<'PY' || note "config.json could not be read; the folders listed there are still untouched"
import json, sys
try:
    config = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
roots = [s.get("path", "") for s in config.get("sources", [])]
roots += [r.get("path", "") for r in config.get("replicas", [])]
roots += [v.get("localPath", "") for v in config.get("vaults", [])]
roots += [v.get("vaultPath", "") for v in config.get("vaults", [])]
for path in [p for p in roots if p]:
    print("  keep    %s" % path)
PY
else
  note "no configuration, so no folders to list"
fi
note "the vault's .neodrop/ directory on the share (journals and retained versions belong to every Mac)"

# MARK: - Do it

step "Carrying it out"

if [ "$CONFIRM" -eq 0 ]; then
  note "dry run: re-run with --yes to delete the paths above"
  printf '\n'
  exit 0
fi

FAILURES=0
TRASHED=""
for path in "${REMOVALS[@]:-}"; do
  [ -n "$path" ] || continue
  # `--trash` moves the state directory aside rather than deleting it. Everything else is a file
  # macOS recreates (a preferences plist), so only the state directory is worth the round trip.
  if [ "$USE_TRASH" -eq 1 ] && [ "$path" = "$STATE" ]; then
    TRASHED="$HOME/.Trash/neodrop-reset-$(date +%Y%m%d-%H%M%S)"
    if mkdir -p "$TRASHED" && mv "$path" "$TRASHED/state"; then
      printf '  trashed %s\n' "$TRASHED/state"
      continue
    fi
    printf '  NOTE    could not move the state to the Trash; deleting it instead\n' >&2
  fi
  if rm -rf "$path"; then
    printf '  removed %s\n' "$path"
  else
    printf '  FAILED  %s\n' "$path" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

if [ "$KEEP_IDENTITY" -eq 1 ] && [ -n "$IDENTITY" ] && [ ! -d "$STATE" ]; then
  mkdir -p "$STATE"
  printf '%s' "$IDENTITY" > "$STATE/machine.json"
  printf '  kept    %s\n' "$STATE/machine.json"
fi

if [ "$FAILURES" -eq 0 ]; then
  printf '\nDone. NeoDrop will start as a fresh install: no folders, no destinations, and the setup wizard will offer itself on the next launch.\n'
  if [ -n "$TRASHED" ]; then
    printf 'The previous state is in the Trash at %s if you need it back.\n' "$TRASHED"
  fi
  exit 0
fi
printf '\n%s path(s) could not be removed.\n' "$FAILURES" >&2
exit 1
