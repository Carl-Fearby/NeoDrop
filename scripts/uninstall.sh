#!/usr/bin/env bash
#
# Remove NeoDrop from this Mac: the app, the Finder extension, and the state it keeps about this
# machine.
#
# scripts/reset.sh takes the state away and leaves the app installed; this is the other direction —
# for somebody who is done with NeoDrop, and for a test machine that has to go back to the way it was
# before NeoDrop ever ran. "Delete the app" is not that: the state lives in Application Support, and
# a Finder Sync extension whose host app has been moved to the Trash stays registered with PlugInKit
# and goes on being loaded into Finder.
#
# What goes:
#
#   1. Every installed copy of the app, not just /Applications/NeoDrop.app. PlugInKit takes an
#      extension from *any* bundle it can see, so a second copy left behind by a packaging
#      experiment keeps NeoDrop's extension alive after the real app is gone — which is exactly why
#      `pluginkit -r` can look like it did nothing. Copies are found by bundle identifier rather than
#      by name, because a renamed build is the one that is easy to miss, and anything PlugInKit is
#      still loading the extension from is named on the way past.
#   2. The Finder extension's registration, taken away while the bundle is still on disk (that is
#      what `pluginkit -r` needs). With no copy installed, PlugInKit forgets the plug-in entirely,
#      including whether the user had switched it on, so a later install starts from the same place
#      this one did.
#   3. `~/Library/Application Scripts/ai.storyteller.neodrop.finder`, the directory macOS creates for
#      a Finder extension. It belongs to NeoDrop and is ours to remove — unlike the containers below.
#   4. This Mac's state, delegated to scripts/reset.sh so there is one definition of what that is.
#      `--trash` is passed through: state that is in the Trash can be put back.
#
# What stays, and why:
#
#   * Your folders, and the vault's `.neodrop/` on the share. reset.sh prints the folders it is not
#     touching before it removes anything, and the vault belongs to every Mac that uses it.
#   * The extension's sandbox container, `~/Library/Containers/ai.storyteller.neodrop.finder`, and
#     the group container beside it. macOS owns those: measured on macOS 26, a process outside the
#     container cannot create, delete or even list inside it — every attempt returns "Operation not
#     permitted" — and that includes Finder with its own privileges and `sudo rm -rf`. The badge index
#     in there therefore outlives the app and no script can help. It is inert once the extension is
#     unregistered, because nothing reads it any more, and macOS discards containers of apps it knows
#     are gone on its own schedule.
#   * "Launch at Login", if it was ever switched on: an SMAppService login item is registered by the
#     app and can only be taken back by the app. This script says so rather than pretending.
#
# Usage: scripts/uninstall.sh [--yes] [--keep-app] [--keep-state] [--trash] [--app path]...
#
#   --yes         carry it out. Without it this is a dry run that prints the plan.
#   --keep-app    leave the app bundles installed; remove the registration and the state
#   --keep-state  leave this Mac's state alone; remove the app and the registration
#   --trash       move the state to the Trash (through reset.sh) instead of deleting it
#   --app path    also remove that bundle, for a copy outside /Applications and ~/Applications.
#                 Repeatable.
#
# Exit status: 0 when everything asked for was removed (or the dry run printed), 1 when something
# could not be removed, 2 on bad usage.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="NeoDrop"
BUNDLE_ID="ai.storyteller.neodrop"
EXTENSION_ID="$BUNDLE_ID.finder"
EXTENSION_NAME="NeoDropFinder"
CONFIRM=0
REMOVE_APP=1
REMOVE_STATE=1
USE_TRASH=0
EXTRA_APPS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) CONFIRM=1; shift ;;
    --keep-app) REMOVE_APP=0; shift ;;
    --keep-state) REMOVE_STATE=0; shift ;;
    --trash) USE_TRASH=1; shift ;;
    --app) [ -n "${2:-}" ] || { printf 'uninstall.sh: --app needs a path\n' >&2; exit 2; }
           EXTRA_APPS+=("${2%/}"); shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'uninstall.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

note() { printf '  --      %s\n' "$1"; }
plan() { printf '  remove  %s\n' "$1"; }
keep() { printf '  keep    %s\n' "$1"; }
gone() { printf '  removed %s\n' "$1"; }
step() { printf '\n%s\n' "$1"; }
ok() { printf '  \033[32mok\033[0m      %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m    %s\n' "$1"; }

printf '%s\n' "NeoDrop uninstall"
if [ "$CONFIRM" -eq 0 ]; then
  printf 'Dry run — nothing will be deleted. Add --yes to carry this out.\n'
fi
if [ "$REMOVE_APP" -eq 0 ] && [ "$REMOVE_STATE" -eq 0 ]; then
  note "--keep-app and --keep-state together: only the Finder extension registration is touched"
fi

# MARK: - Is it running?

step "Running now?"

# The app is never killed for you. It writes its state on the way out, so removing that state from
# under a running copy is how a "clean" uninstall leaves a configuration behind.
# Two ways to find it: the installed bundle, and the binary itself, which is what `swift run
# NeoDrop` starts and what a bundle-path pattern would miss.
RUNNING="$(pgrep -x "$APP_NAME" 2>/dev/null || true)"
[ -n "$RUNNING" ] || RUNNING="$(pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true)"
if [ -n "$RUNNING" ]; then
  printf 'NeoDrop is running (pid %s). Quit it from the menu bar first, then run this again.\n' \
    "$(printf '%s' "$RUNNING" | tr '\n' ' ')" >&2
  exit 1
fi
note "the app is not running"

# The extension is the one process worth killing: Finder starts it inside itself and keeps it there,
# and deregistering a plug-in that is running has no effect until it stops. Finder relaunches it from
# whatever is still installed, and that is all about to go.
EXT_RUNNING="$(pgrep -x "$EXTENSION_NAME" 2>/dev/null || true)"
if [ -n "$EXT_RUNNING" ]; then
  if [ "$CONFIRM" -eq 1 ]; then
    note "stopping the Finder extension (pid $(printf '%s' "$EXT_RUNNING" | tr '\n' ' '))"
    pkill -x "$EXTENSION_NAME" >/dev/null 2>&1 || true
    sleep 1
  else
    note "the Finder extension is running; it would be stopped before deregistering"
  fi
else
  note "the Finder extension is not running"
fi

# MARK: - Installed copies

step "Installed copies of the app"

COPY_LIST=""
add_copy() {
  case "$COPY_LIST" in *"|$1|"*) return ;; esac
  COPY_LIST="$COPY_LIST|$1|"
}

# The bundle identifier is the identity, not the file name: a copy called NeoDropTest.app is NeoDrop
# as far as PlugInKit is concerned, and it is exactly the copy that keeps the extension registered
# after the real app is gone.
for DIRECTORY in /Applications "$HOME/Applications"; do
  [ -d "$DIRECTORY" ] || continue
  for CANDIDATE in "$DIRECTORY"/*.app; do
    [ -d "$CANDIDATE" ] || continue
    IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
      "$CANDIDATE/Contents/Info.plist" 2>/dev/null || true)"
    [ "$IDENTIFIER" = "$BUNDLE_ID" ] && add_copy "${CANDIDATE%/}"
  done
done
for CANDIDATE in "${EXTRA_APPS[@]:-}"; do
  [ -n "$CANDIDATE" ] || continue
  if [ -d "$CANDIDATE" ]; then
    add_copy "$CANDIDATE"
  else
    note "--app $CANDIDATE is not there (nothing to do)"
  fi
done

# The list is pipe-delimited and pipe-terminated so membership can be tested with a glob; splitting
# it back out leaves empty fields at the ends, which the guards below skip.
COPIES=()
while IFS= read -r COPY; do
  [ -n "$COPY" ] && COPIES+=("$COPY")
done <<< "$(printf '%s' "$COPY_LIST" | tr '|' '\n')"

COPY_COUNT="${#COPIES[@]}"
if [ "$COPY_COUNT" -eq 0 ]; then
  note "no NeoDrop app in /Applications or ~/Applications (a bundle in build/ is not an installation)"
fi
for COPY in "${COPIES[@]:-}"; do
  [ -n "$COPY" ] || continue
  SIZE="$(du -sh "$COPY" 2>/dev/null | awk '{print $1}')"
  if [ -d "$COPY/Contents/PlugIns/$EXTENSION_NAME.appex" ]; then
    note "$COPY  ($SIZE, with the Finder extension inside)"
  else
    note "$COPY  ($SIZE, no Finder extension inside)"
  fi
done

# Where PlugInKit is actually loading the extension from, which is the ground truth about what has to
# go for Finder to stop seeing NeoDrop. A copy in a place this script does not scan — ~/Downloads, a
# mounted disk image — shows up here and nowhere else, and it is why somebody can remove the app and
# still find the extension in System Settings.
REGISTERED_APPEXES=()
while IFS= read -r LINE; do
  [ -n "$LINE" ] || continue
  APPEX="$(printf '%s' "$LINE" | awk -F'\t' '{print $NF}')"
  # pluginkit ends with a "(1 plug-in)" summary line; only the rows that name a bundle matter.
  case "$APPEX" in *.appex) ;; *) continue ;; esac
  REGISTERED_APPEXES+=("$APPEX")
  # The leading column is the election: "+" switched on, "-" switched off, "?" neither yet.
  case "$LINE" in
    "+"*) ENABLEMENT="switched on" ;;
    "-"*) ENABLEMENT="switched off" ;;
    *) ENABLEMENT="not yet elected" ;;
  esac
  note "registered with Finder ($ENABLEMENT): $LINE"
done <<< "$(pluginkit -m -v -i "$EXTENSION_ID" 2>/dev/null || true)"
if [ "${#REGISTERED_APPEXES[@]}" -eq 0 ]; then
  note "the Finder extension is not registered"
fi

for APPEX in "${REGISTERED_APPEXES[@]:-}"; do
  [ -n "$APPEX" ] || continue
  HOST="${APPEX%%/Contents/PlugIns/*}"
  case "$COPY_LIST" in
    *"|$HOST|"*) ;;
    *) note "the extension is also loaded from $HOST — outside the standard locations: pass --app $HOST to remove that copy too" ;;
  esac
done

# MARK: - What goes

step "Removing"

if [ "$REMOVE_APP" -eq 1 ]; then
  if [ "$COPY_COUNT" -eq 0 ]; then
    note "no app bundle to remove"
  fi
  for COPY in "${COPIES[@]:-}"; do
    [ -n "$COPY" ] || continue
    plan "$COPY"
  done
else
  keep "the app bundles — run without --keep-app to remove them too"
fi

# macOS makes this one for the extension and it is NeoDrop's, so it goes with the app.
APP_SCRIPTS="$HOME/Library/Application Scripts/$EXTENSION_ID"
if [ "$REMOVE_APP" -eq 1 ] && [ -d "$APP_SCRIPTS" ]; then
  plan "$APP_SCRIPTS  (created by macOS for the Finder extension)"
fi

# MARK: - State, through reset.sh

# MARK: - State, through reset.sh

# The list of what "this Mac's state" means belongs to reset.sh, and asking for the plan here is how
# there is one definition of it instead of two that drift apart. reset.sh prints its own verdict on
# the app ("delete it by hand, or pass --app"); that is about a bundle this script removes above.
RESET_STATUS=0
if [ "$REMOVE_STATE" -eq 1 ]; then
  step "State NeoDrop keeps on this Mac (scripts/reset.sh)"
  if [ "$CONFIRM" -eq 0 ]; then
    RESET_ARGS=()
    [ "$USE_TRASH" -eq 1 ] && RESET_ARGS+=(--trash)
    if [ "${#RESET_ARGS[@]}" -eq 0 ]; then
      "$ROOT/scripts/reset.sh"
    else
      "$ROOT/scripts/reset.sh" "${RESET_ARGS[@]}"
    fi
    [ "$REMOVE_APP" -eq 1 ] && \
      note "reset.sh leaves the app alone by design; the plan above removes it"
  else
    note "removed after the app bundles, so nothing is holding it open"
  fi
else
  step "State"
  keep "this Mac's state — scripts/reset.sh removes it when you want it gone"
fi

# MARK: - What stays

step "Not touched"

# Measured, not assumed: on macOS 26 these containers answer every write, every delete and even a
# directory listing from outside with "Operation not permitted". macOS creates them for the
# extension, not NeoDrop, and they are not ours to remove.
CONTAINERS=()
for CONTAINER in "$HOME/Library/Containers/$EXTENSION_ID" "$HOME/Library/Group Containers/group.$BUNDLE_ID"; do
  [ -e "$CONTAINER" ] && CONTAINERS+=("$CONTAINER")
done
for CONTAINER in "${CONTAINERS[@]:-}"; do
  [ -n "$CONTAINER" ] || continue
  keep "$CONTAINER  (macOS's sandbox container — only macOS removes one)"
done
BADGE_INDEX="$HOME/Library/Containers/$EXTENSION_ID/Data/Library/Application Support/$APP_NAME/finder-status.json"
if [ -f "$BADGE_INDEX" ]; then
  note "↳ the badge index inside is inert once the extension is unregistered: nothing reads it, and macOS discards containers of apps it knows are gone on its own schedule"
fi

if launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; then
  keep "the login item — turn “Launch at Login” off in the app's menu first, or System Settings → General → Login Items"
fi

if [ -f "$ROOT/build/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]; then
  note "build/$APP_NAME.app  (a build, not an installation — scripts/install.sh puts it back)"
fi

# MARK: - Do it

if [ "$CONFIRM" -eq 0 ]; then
  step "Dry run"
  note "nothing was changed: re-run with --yes to carry out the plan above"
  printf '\n'
  exit 0
fi

step "Carrying it out"
FAILURES=0

# Deregister first: `pluginkit -r` talks about a bundle, so the bundle has to still be there. With
# the last copy gone PlugInKit drops the plug-in, and its on/off election goes with it.
for APPEX in "${REGISTERED_APPEXES[@]:-}"; do
  [ -n "$APPEX" ] || continue
  [ -d "$APPEX" ] || continue
  if pluginkit -r "$APPEX" >/dev/null 2>&1; then
    ok "deregistered the Finder extension from ${APPEX%%/Contents/PlugIns/*}"
  else
    note "pluginkit -r said nothing about $APPEX — removing the bundle is the other half"
  fi
done

if [ "$REMOVE_APP" -eq 1 ]; then
  for COPY in "${COPIES[@]:-}"; do
    [ -n "$COPY" ] || continue
    # Tell LaunchServices to forget it too: the bundle is about to stop existing, and an entry
    # pointing at nothing is how "Open With" keeps offering an app that is not installed.
    LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$COPY" >/dev/null 2>&1
    if rm -rf "$COPY"; then
      gone "$COPY"
    else
      fail "$COPY could not be removed (is it owned by another user?)"
      FAILURES=$((FAILURES + 1))
    fi
  done
  if [ -d "$APP_SCRIPTS" ]; then
    if rm -rf "$APP_SCRIPTS"; then
      gone "$APP_SCRIPTS"
    else
      fail "$APP_SCRIPTS could not be removed"
      FAILURES=$((FAILURES + 1))
    fi
  fi
fi

# The state goes last, after the app: nothing is running that could rewrite it, and reset.sh has the
# bundle out of its way, so its report is about state and nothing else.
if [ "$REMOVE_STATE" -eq 1 ]; then
  step "State (scripts/reset.sh)"
  RESET_ARGS=(--yes)
  [ "$USE_TRASH" -eq 1 ] && RESET_ARGS+=(--trash)
  "$ROOT/scripts/reset.sh" "${RESET_ARGS[@]}"
  RESET_STATUS=$?
  if [ "$RESET_STATUS" -ne 0 ]; then
    fail "reset.sh could not remove everything it was asked to"
    FAILURES=$((FAILURES + 1))
  fi
fi

if [ "$REMOVE_APP" -eq 1 ]; then
  STILL_REGISTERED="$(pluginkit -m -i "$EXTENSION_ID" 2>/dev/null | head -3)"
  if [ -n "$STILL_REGISTERED" ]; then
    fail "the Finder extension is still registered: $(printf '%s' "$STILL_REGISTERED" | tr '\n' ' ')"
    FAILURES=$((FAILURES + 1))
  else
    ok "Finder has no NeoDrop extension registered"
  fi
fi

if [ "$FAILURES" -eq 0 ]; then
  printf '\nDone.'
  if [ "$REMOVE_APP" -eq 1 ]; then
    printf ' NeoDrop is gone from this Mac: no app, no Finder extension, no state.'
  else
    printf ' The app is still installed, with no state and no Finder extension.'
  fi
  printf '\n'
  printf 'Rebuild and reinstall with scripts/package.sh && scripts/install.sh when you want it back.\n'
  exit 0
fi

printf '\n%s step(s) could not be completed.\n' "$FAILURES" >&2
exit 1
