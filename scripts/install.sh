#!/usr/bin/env bash
#
# Install NeoDrop into /Applications and switch its Finder extension on.
#
# Two steps macOS does not do for you, and both matter:
#
#   1. The app has to be in /Applications (or ~/Applications). PlugInKit only considers extensions
#      belonging to an app it finds in a standard location, so a NeoDrop.app sitting in build/ has an
#      extension that is embedded, signed and completely invisible to Finder.
#   2. The Finder extension has to be enabled. Unlike most app extensions this one is off until the
#      user turns it on — System Settings → General → Login Items & Extensions → Finder Extensions —
#      which is also where it can be switched off again. `pluginkit -e use` does the same thing from
#      the command line, and it is what this script tries first.
#
# Usage: scripts/install.sh [--app path/to/NeoDrop.app] [--no-enable] [--dry-run]
#
#   --app        install that bundle instead of build/NeoDrop.app (point it at the copy inside a
#                mounted DMG to install the artefact that ships)
#   --no-enable  copy the app but leave the extension for the user to enable by hand
#   --dry-run    print what would happen; change nothing
#
# Exit status: 0 when the app is installed and the extension is enabled, 1 when the app is installed
# but the extension still needs a human, 2 on bad usage or a missing app.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="NeoDrop"
EXTENSION_ID="ai.storyteller.neodrop.finder"
SOURCE_APP="$ROOT/build/$APP_NAME.app"
DESTINATION="/Applications/$APP_NAME.app"
ENABLE=1
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) SOURCE_APP="${2:-}"; shift 2 ;;
    --no-enable) ENABLE=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'install.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

note() { printf '  --   %s\n' "$1"; }
ok() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

[ -d "$SOURCE_APP" ] || { printf 'install.sh: no app at %s (build one with scripts/package.sh)\n' "$SOURCE_APP" >&2; exit 2; }
[ -x "$SOURCE_APP/Contents/MacOS/$APP_NAME" ] || { printf 'install.sh: %s does not look like a NeoDrop bundle\n' "$SOURCE_APP" >&2; exit 2; }

printf 'Installing %s → %s\n' "$SOURCE_APP" "$DESTINATION"

if [ "$DRY_RUN" -eq 1 ]; then
  note "would copy the bundle, register it with LaunchServices, and enable $EXTENSION_ID"
  exit 0
fi

# Quit a running copy first: replacing the bundle under a running process is how people end up with
# two menu bar icons and a confusing afternoon.
if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
  note "NeoDrop is running; quitting it first"
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null 2>&1
  sleep 1
fi

if [ -d "$DESTINATION" ]; then
  note "replacing the installed copy"
  rm -rf "$DESTINATION" || { fail "could not remove $DESTINATION (is it owned by another user?)"; exit 1; }
fi
# ditto, not cp: it preserves the bundle's metadata, which codesign will verify afterwards.
if ! ditto "$SOURCE_APP" "$DESTINATION"; then
  fail "could not copy into /Applications"
  exit 1
fi
ok "installed at $DESTINATION"

# The download quarantine flag would block the app on first launch and confuse the extension checks.
xattr -dr com.apple.quarantine "$DESTINATION" >/dev/null 2>&1 || true

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$DESTINATION" >/dev/null 2>&1 || note "LaunchServices registration was not needed (or failed quietly)"

APPEX="$DESTINATION/Contents/PlugIns/NeoDropFinder.appex"
if [ ! -d "$APPEX" ]; then
  fail "the installed app has no Finder extension; rebuild with scripts/package.sh"
  exit 1
fi

pluginkit -a "$APPEX" >/dev/null 2>&1 || note "pluginkit -a said nothing useful"

if [ "$ENABLE" -eq 0 ]; then
  note "leaving the extension disabled (--no-enable): turn it on in System Settings → General → Login Items & Extensions → Finder Extensions"
  exit 1
fi

pluginkit -e use -i "$EXTENSION_ID" >/dev/null 2>&1
sleep 1
STATUS="$(pluginkit -m -v -i "$EXTENSION_ID" 2>/dev/null | head -1)"

# The badges are the quiet casualty of an ad-hoc signature: macOS 14+ protects an app's data container
# from processes outside the team that owns it, and ad-hoc carries no team, so the app is refused when
# it publishes the badge index into the extension's container. The app logs it and syncs on, so the
# only symptom is badges that never appear — which is worth saying out loud here, where somebody has
# just enabled the extension and is about to go looking for them.
TEAM="$(codesign -dvv "$DESTINATION" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
if printf '%s' "$STATUS" | grep -q '^+'; then
  ok "Finder extension enabled: $STATUS"
  if [ "$TEAM" = "not set" ]; then
    note "signed ad-hoc, so no badge can reach the extension: build with MACOS_SIGN_IDENTITY set to an Apple Development or Developer ID identity, then reinstall"
  else
    note "app and extension are signed by team $TEAM, so the badge index reaches the extension"
  fi
  printf '\nBadges appear next to the date in Finder for the folders NeoDrop protects. Nothing to do\nuntil at least one folder is set up: the app offers the setup wizard on first launch.\n'
  exit 0
fi

if [ -n "$STATUS" ]; then
  fail "the extension is registered but not enabled: $STATUS"
else
  fail "Finder has not picked the extension up at all"
fi
cat <<'MANUAL'

Enable it by hand:

  1. Open NeoDrop once from /Applications, so macOS has seen the app.
  2. System Settings → General → Login Items & Extensions → Finder Extensions → turn on NeoDrop.
  3. If it is not listed there, this build's ad-hoc signature is the reason: an extension has to be
     signed, and macOS only trusts an ad-hoc signature for an app on the same Mac it was built on.
     Copy the app to /Applications on the Mac that built it, or sign it with a Developer ID.

Without the extension the app still syncs and still shows status in its own windows; the badges are
the thing that will be missing.
MANUAL
exit 1
