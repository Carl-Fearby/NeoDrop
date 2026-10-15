#!/usr/bin/env bash
#
# Verify the artefacts that scripts/package.sh produced.
#
#   scripts/verify.sh            check build/NeoDrop.app and any DMG in build/
#   scripts/verify.sh --smoke    also launch the bundled app for a few seconds
#   scripts/verify.sh --dmg IMG  check that image instead of every one in build/ (repeatable). The
#                                default checks the whole directory, which is what a release run
#                                wants; this is for verifying one freshly built image while older
#                                ones are still lying around.
#
# Checks the things a successful build alone does not prove: that the bundle declares itself a
# menu bar app, that the executable actually runs, that the signature validates, that the DMG
# mounts and contains what a drag-to-Applications install needs, and that nothing unexpected is
# being linked or shipped.
#
# Exit status: 0 when every check passed, 1 when any check failed, 2 on bad usage.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD="$ROOT/build"
APP_NAME="NeoDrop"

SMOKE=0
CHOSEN_DMGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) SMOKE=1; shift ;;
    --dmg) CHOSEN_DMGS+=("${2:-}"); shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'verify.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

FAILURES=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
note() { printf '  --   %s\n' "$1"; }
check() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi }

APP="$BUILD/$APP_NAME.app"

echo "App bundle: $APP"
[ -d "$APP" ] || { fail "no app bundle; run scripts/package.sh first"; exit 1; }

PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"

check "Info.plist is valid" "plutil -lint '$PLIST'"
check "executable is present and executable" "[ -x '$EXECUTABLE' ]"
check "CFBundleIdentifier is set" "test -n \"\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '$PLIST')\""
check "CFBundleShortVersionString is set" "test -n \"\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '$PLIST')\""
check "LSUIElement is true (menu bar only, no Dock icon)" \
  "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' '$PLIST')\" = 'true' ]"
check "icon resource exists" "[ -f '$APP/Contents/Resources/$APP_NAME.icns' ]"
# The Finder service is declared in the plist and implemented in the app, and the two only work
# together: Finder looks the NSMessage selector up in the running app, so a plist naming a selector
# nobody implements gives a menu item that silently does nothing. Both halves are checked here, and
# the menu title is checked because Finder prints it verbatim under Services.
check "Finder service is declared with a menu title" \
  "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSMenuItem:default' '$PLIST')\" = 'Show NeoDrop Status' ]"
check "Finder service names the showFileStatus selector" \
  "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSMessage' '$PLIST')\" = 'showFileStatus' ]"
check "Finder service accepts files and folders" \
  "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSSendFileTypes:0' '$PLIST')\" = 'public.item' ]"
check "the app implements the selector the service names" \
  "grep -a -q 'showFileStatus' '$EXECUTABLE'"
# Resources should hold exactly what the app needs — the icon, and the three menu bar icon
# representations. A count would pass on the wrong three files and would need editing every time the
# bundle legitimately gains one, so the expected list is spelled out and compared as a set.
EXPECTED_RESOURCES="$APP_NAME.icns
MenuBarIcon.png
MenuBarIcon@2x.png
MenuBarIcon@3x.png"
ACTUAL_RESOURCES="$(ls "$APP/Contents/Resources" 2>/dev/null)"
if [ "$(printf '%s\n' "$EXPECTED_RESOURCES" | sort)" = "$(printf '%s\n' "$ACTUAL_RESOURCES" | sort)" ]; then
  pass "Resources holds exactly the expected files"
else
  fail "Resources holds: $(printf '%s' "$ACTUAL_RESOURCES" | tr '\n' ' ')"
fi

# A status item asks for 18 points; AppKit silently scales whatever it finds, so a wrong-sized file
# still works and merely looks soft. The pixel sizes are what the icon set was rendered for.
MENUBAR_HEIGHT="$(sips -g pixelHeight "$APP/Contents/Resources/MenuBarIcon.png" 2>/dev/null | awk '/pixelHeight/{print $2}')"
MENUBAR_2X="$(sips -g pixelWidth -g pixelHeight "$APP/Contents/Resources/MenuBarIcon@2x.png" 2>/dev/null | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')"
MENUBAR_3X="$(sips -g pixelWidth -g pixelHeight "$APP/Contents/Resources/MenuBarIcon@3x.png" 2>/dev/null | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}')"
if [ "$MENUBAR_HEIGHT" = "18" ] && [ "$MENUBAR_2X" = "36x36" ] && [ "$MENUBAR_3X" = "54x54" ]; then
  pass "the menu bar icon carries 1x/2x/3x at 18/36/54 px"
else
  fail "the menu bar icon sizes are 18pt=$MENUBAR_HEIGHT 2x=$MENUBAR_2X 3x=$MENUBAR_3X"
fi

# The .icns has to carry every size macOS asks for, not just one big image: Finder, the Dock and
# Quick Look each pick a different one.
ICONSET_TMP="$(mktemp -d)"
if iconutil -c iconset "$APP/Contents/Resources/$APP_NAME.icns" -o "$ICONSET_TMP/check.iconset" >/dev/null 2>&1; then
  MISSING=""
  for size in 16x16 16x16@2x 32x32 32x32@2x 128x128 128x128@2x 256x256 256x256@2x 512x512 512x512@2x; do
    [ -f "$ICONSET_TMP/check.iconset/icon_$size.png" ] || MISSING="$MISSING $size"
  done
  if [ -z "$MISSING" ]; then
    pass "the .icns contains all ten sizes macOS looks for"
  else
    fail "the .icns is missing sizes:$MISSING"
  fi
  BIGGEST="$ICONSET_TMP/check.iconset/icon_512x512@2x.png"
  if [ -f "$BIGGEST" ] && [ "$(sips -g pixelWidth "$BIGGEST" 2>/dev/null | awk '/pixelWidth/{print $2}')" = "1024" ]; then
    pass "the largest icon is a 1024px master"
  else
    fail "the largest icon is not 1024px"
  fi
else
  fail "the .icns could not be unpacked (it is not a valid iconset)"
fi
rm -rf "$ICONSET_TMP"
check "bundle carries no source maps or build leftovers" \
  "! find '$APP' -name '*.dSYM' -o -name '.build' -o -name '*.swiftmodule' | grep -q ."
check "signature validates strictly" "codesign --verify --strict '$APP'"

# ---- the Finder extension ---------------------------------------------------------------------
# The badges next to a file's date come from a Finder Sync extension, which is a bundle inside the
# app that Finder loads. Everything here has failed silently at some point in development — the
# extension simply never appeared in `pluginkit -m -p com.apple.FinderSync`, with nothing in any log:
#
#   * an appex whose executable is a dylib or a Mach-O *bundle* is never registered, and its
#     signature cannot carry entitlements either;
#   * an extension that is not sandboxed is refused by PlugInKit ("plug-ins must be sandboxed", in
#     the system log only);
#   * a sandboxed extension cannot read the app's Application Support directory, so without a channel
#     it registers, runs and badges nothing. The channel is the extension's own container, which the
#     app writes from outside — and which macOS 14+ closes to any process outside the *team* that owns
#     it, so an ad-hoc signed app is refused ("You don't have permission to save the file …") and the
#     badges stay dark. An App Group is *not* the channel: `~/Library/Group Containers` is closed to a
#     non-sandboxed process, so an app-group entitlement makes the app look entitled while the index
#     never lands — the checks below refuse it rather than leave that to be rediscovered;
#   * a plist naming a class the binary does not export gives an extension that loads and does
#     nothing.
#
# What works is what Xcode produces: an appex executable is Mach-O *executable* (MH_EXECUTE) linked
# with `NSExtensionMain` as its entry point, which is what makes the Entitlements blob appear in the
# signature. See build_extension_arch in scripts/package.sh.
APPEX="$APP/Contents/PlugIns/NeoDropFinder.appex"
EXTENSION_PLIST="$APPEX/Contents/Info.plist"
EXTENSION_BINARY="$APPEX/Contents/MacOS/NeoDropFinder"
check "Finder extension is embedded" "[ -d '$APPEX' ]"
check "Finder extension's Info.plist is valid" "plutil -lint '$EXTENSION_PLIST'"
check "Finder extension declares the FinderSync extension point" \
  "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' '$EXTENSION_PLIST')\" = 'com.apple.FinderSync' ]"
check "Finder extension names its principal class" \
  "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' '$EXTENSION_PLIST')\" = 'NeoDropFinderExtension' ]"
check "Finder extension binary is a Mach-O executable (PlugInKit ignores a dylib or a bundle)" \
  "file -b '$EXTENSION_BINARY' | grep -q 'Mach-O 64-bit executable'"
check "Finder extension is a single architecture or fat, never empty" \
  "[ \"\$(lipo -archs '$EXTENSION_BINARY' 2>/dev/null | tr -d ' ')\" != '' ]"
# `strings … | grep -q` is not used here on purpose: `grep -q` exits at the first match, `strings` is
# then killed by SIGPIPE, and with `pipefail` set the pipeline reports 141 — a check that fails or
# passes depending on where in the file the match happens to be. Comparing the whole output is a
# little wasteful and never flaky.
check "the extension exports the class the plist names" \
  "[[ \"\$(strings -a '$EXTENSION_BINARY')\" == *NeoDropFinderExtension* ]]"
check "Finder extension is signed" "codesign --verify --strict '$APPEX'"
# One team, or no badges. A container is protected from processes outside the team that owns it, so
# the app and the extension have to carry the *same* team identifier for anything the app publishes to
# reach the extension. Both ad-hoc (no team at all) is the supported build for somebody without an
# Apple account and is reported as a note with its consequence; two different teams is a failure,
# because that combination builds, launches, syncs — and can never publish a badge.
APP_TEAM="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
EXTENSION_TEAM="$(codesign -dvv "$APPEX" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
if [ "$APP_TEAM" = "not set" ] && [ "$EXTENSION_TEAM" = "not set" ]; then
  note "signed ad-hoc: no team, so macOS 14+ refuses the app's writes into the extension's container and the badges stay dark (build with MACOS_SIGN_IDENTITY to switch them on)"
elif [ "$APP_TEAM" = "$EXTENSION_TEAM" ]; then
  pass "app and extension share a team ($APP_TEAM), so the badge index can reach the extension"
else
  fail "app is signed by '$APP_TEAM' and the extension by '$EXTENSION_TEAM': a container is closed to another team, so no badge can ever be published"
fi
# Entitlements in the signature are what PlugInKit reads before it will register the extension.
# They only land there for an MH_EXECUTE, which is why the shape of the binary above matters.
check "Finder extension carries the App Sandbox entitlement PlugInKit requires" \
  "codesign -d --entitlements - --xml '$APPEX' 2>/dev/null | plutil -p - | grep -q 'com.apple.security.app-sandbox'"
# An App Group cannot carry the badge index to the extension: the app is not sandboxed (it mirrors to
# /Volumes), and `~/Library/Group Containers` refuses an unsandboxed writer. Declaring one again would
# silently break every badge, so it is a failed check rather than a warning.
check "neither bundle declares an App Group (it cannot be written by a non-sandboxed app)" \
  "! codesign -d --entitlements - --xml '$APPEX' 2>/dev/null | grep -q 'application-groups' \
     && ! codesign -d --entitlements - --xml '$APP' 2>/dev/null | grep -q 'application-groups'"
# The app publishes into the container named after the extension's bundle identifier, so the two have
# to be the same string on the built artefact, not just in the source. Renaming the extension in its
# Info.plist without the constant in FinderStatus.swift would leave badges silently dead.
check "the app publishes into the container of the extension it ships" \
  "[[ \"\$(strings -a '$EXECUTABLE')\" == *\"\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' '$EXTENSION_PLIST')\"* ]]"
check "the app declares the neodrop:// scheme the extension uses" \
  "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' '$PLIST')\" = 'neodrop' ]"

# Gatekeeper: a failure here is expected for an ad-hoc build and must not fail the run.
if spctl --assess --type execute "$APP" >/dev/null 2>&1; then
  pass "Gatekeeper accepts the app (notarized or locally trusted)"
else
  note "Gatekeeper would reject the app on another Mac (expected without a Developer ID + notarization)"
fi

# The Swift runtime is in /usr/lib/swift on this OS version, so only system paths should appear.
UNEXPECTED_LIBS="$(otool -L "$EXECUTABLE" | tail -n +2 | awk '{print $1}' \
  | grep -vE '^(/usr/lib|/System/Library|@rpath|@loader_path)' || true)"
if [ -z "$UNEXPECTED_LIBS" ]; then
  pass "links only system libraries"
else
  fail "unexpected linked libraries: $UNEXPECTED_LIBS"
fi

ARCHS="$(lipo -archs "$EXECUTABLE" 2>/dev/null || echo unknown)"
note "architectures: $ARCHS"

if [ "$SMOKE" -eq 1 ]; then
  # Run the real binary for a few seconds: a build that links but cannot start is not a build.
  #
  # NEODROP_HOME is pointed at a scratch directory, which is the whole reason this is safe to run.
  # Without it the app starts against the *real* state directory — reading the developer's config,
  # appending to their log, and running with their folder watchers live, so a smoke test could
  # mirror files for real. This also makes the check mean what it claims: a fresh install starting
  # up, rather than "whatever is configured on this machine still runs".
  SMOKE_STATE="$(mktemp -d)"
  LOG="$BUILD/smoke.log"
  NEODROP_HOME="$SMOKE_STATE" "$EXECUTABLE" >"$LOG" 2>&1 &
  PID=$!
  sleep 4
  if kill -0 "$PID" 2>/dev/null; then
    pass "app launches and stays running (pid $PID)"
    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
  else
    fail "app exited within 4s; see $LOG"
    sed 's/^/       /' "$LOG" | head -20
  fi
  rm -rf "$SMOKE_STATE"
fi

# ---- DMG --------------------------------------------------------------------------------------
shopt -s nullglob
if [ "${#CHOSEN_DMGS[@]}" -gt 0 ]; then
  DMGS=("${CHOSEN_DMGS[@]}")
else
  DMGS=("$BUILD"/*.dmg)
fi
shopt -u nullglob

# A copy of the image may already be attached — the user looking at it, or an interrupted run.
# hdiutil then refuses with "Resource busy" and this script would report a false FAIL that has
# nothing to do with the DMG, so reuse that mount: everything below is read-only anyway.
mountpoint_of_attached() {
  hdiutil info 2>/dev/null | awk -v img="$1" '
    /^image-path/ { cur = $3 }
    cur == img && $1 ~ /^\/dev\// && $3 ~ /^\// { found = $3 }
    END { if (found) print found }
  '
}

# A suite that passes with nothing to verify is worse than one that fails: after a build that never
# produced an image (a --no-dmg run, or a build that stopped early) every DMG check silently does not
# run, and "All checks passed" then says nothing about the installer at all.
if [ "${#DMGS[@]}" -eq 0 ]; then
  echo
  note "no DMG in build/ to verify — the installer checks did not run"
  note "build one with scripts/package.sh (a --no-dmg build has no image to check)"
fi

for DMG in ${DMGS[@]+"${DMGS[@]}"}; do
  echo
  echo "DMG: $DMG"
  DETACH_AFTER=""
  MOUNT="$(mountpoint_of_attached "$DMG")"
  if [ -n "$MOUNT" ]; then
    note "reusing the copy of this image already mounted at $MOUNT"
  else
    MOUNT="$(mktemp -d)"
    if ! hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null 2>&1; then
      fail "dmg mounts"
      rmdir "$MOUNT" 2>/dev/null
      continue
    fi
    DETACH_AFTER="yes"
  fi
  pass "dmg mounts"

  [ -d "$MOUNT/$APP_NAME.app" ] && pass "dmg contains $APP_NAME.app" || fail "dmg contains $APP_NAME.app"
  [ -L "$MOUNT/Applications" ] && pass "dmg has an /Applications drop target" || fail "dmg has an /Applications drop target"
  [ -f "$MOUNT/Read Me First.txt" ] && pass "dmg includes first-launch instructions" \
    || fail "dmg includes first-launch instructions"
  # Present is not the same as shown: Finder hides the file when it carries the hidden flag, and that
  # flag lives on the file itself rather than in the .DS_Store. The instructions sat hidden for a
  # while, so this asserts the state the window is supposed to be in.
  if ls -lO "$MOUNT/Read Me First.txt" 2>/dev/null | grep -q hidden; then
    fail "Read Me First.txt is hidden, so it would not appear in the window"
  else
    pass "Read Me First.txt is visible in the window"
  fi
  # Whether Finder actually draws it needs a human eye; presence plus the custom-icon bit is what
  # this can prove. That bit is byte 8 of com.apple.FinderInfo (kHasCustomIcon = 0x04); without it
  # Finder ignores .VolumeIcon.icns and falls back to the generic disk icon, so checking only for
  # the file would pass on an image that looks unstyled.
  if [ -f "$MOUNT/.VolumeIcon.icns" ] \
    && [ "$(xattr -px com.apple.FinderInfo "$MOUNT" 2>/dev/null | head -1 | awk '{print $9}')" = "04" ]; then
    pass "dmg carries a volume icon (custom-icon bit set)"
  else
    fail "dmg carries a volume icon (custom-icon bit set)"
  fi
  # The two checks below only apply to the styled installer. package.sh builds that one when the
  # optional dmgbuild tooling is installed, and a plain window otherwise — so demanding the layout
  # unconditionally meant a fresh clone with no .venv failed its own verification suite, with two
  # FAILs that looked like regressions but were the documented fallback working as designed.
  #
  # The condition mirrors package.sh's exactly, so this still fails loudly when the tooling *is*
  # present and the styled image nevertheless came out plain — which is the case worth catching.
  if [ -x "$ROOT/.venv/bin/python" ] && [ -f "$ROOT/Resources/dmg-background.png" ]; then
    # Finder draws a background at its own size and does not scale it to the window, so the
    # background has to be a 1x/@2x pair whose 1x is exactly the window size; a single-resolution
    # image larger than the window shows only its top-left corner. dmgbuild only combines the pair
    # when it finds an @2x beside the 1x, so this asserts the multi-resolution result really shipped.
    # (make-dmg.py additionally checks the 1x representation against the recorded window bounds.)
    BACKGROUND_FILE="$(ls "$MOUNT"/.background.* 2>/dev/null | head -1)"
    BACKGROUND_RESOLUTIONS=""
    [ -n "$BACKGROUND_FILE" ] && BACKGROUND_RESOLUTIONS="$(tiffutil -info "$BACKGROUND_FILE" 2>/dev/null | grep -c 'Image Width')"
    if [ "${BACKGROUND_RESOLUTIONS:-0}" -ge 2 ]; then
      pass "dmg background is a multi-resolution (1x/@2x) image"
    else
      fail "dmg background is not a 1x/@2x pair (Finder would not scale it to the window)"
    fi

    # The drag-and-drop layout is a .DS_Store at the root of the image: icon positions, the
    # background and the window size. Without it the DMG still mounts but looks like a plain folder.
    if [ -f "$MOUNT/.DS_Store" ]; then
      pass "dmg carries a drag-and-drop layout (.DS_Store)"
    else
      fail "dmg carries a drag-and-drop layout (.DS_Store)"
    fi
  else
    note "no .venv with dmgbuild, so package.sh built the plain installer: skipping the layout and background checks"
    note "run scripts/setup-dmg-tools.sh for the drag-and-drop window"
  fi
  check "app inside the dmg is signed" "codesign --verify --strict '$MOUNT/$APP_NAME.app'"
  check "app inside the dmg keeps its LSUIElement flag" \
    "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' '$MOUNT/$APP_NAME.app/Contents/Info.plist')\" = 'true' ]"
  check "app inside the dmg still declares the Finder service" \
    "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :NSServices:0:NSMessage' '$MOUNT/$APP_NAME.app/Contents/Info.plist')\" = 'showFileStatus' ]"
  check "app inside the dmg still carries the Finder extension" \
    "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' '$MOUNT/$APP_NAME.app/Contents/PlugIns/NeoDropFinder.appex/Contents/Info.plist')\" = 'com.apple.FinderSync' ]"

  # The quarantine story only works if the app itself is not already flagged.
  if xattr -p com.apple.quarantine "$MOUNT/$APP_NAME.app" >/dev/null 2>&1; then
    note "the app inside the dmg carries a quarantine flag"
  else
    pass "app inside the dmg is not quarantined"
  fi

  if [ -n "$DETACH_AFTER" ]; then
    hdiutil detach "$MOUNT" >/dev/null 2>&1
    rmdir "$MOUNT" 2>/dev/null
  else
    note "left the pre-existing mount in place at $MOUNT"
  fi
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
fi
echo "$FAILURES check(s) failed."
exit 1
