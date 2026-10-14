#!/usr/bin/env bash
#
# Verify the artefacts that scripts/package.sh produced.
#
#   scripts/verify.sh            check build/NeoDrop.app and any DMG in build/
#   scripts/verify.sh --smoke    also launch the bundled app for a few seconds
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
while [ $# -gt 0 ]; do
  case "$1" in
    --smoke) SMOKE=1; shift ;;
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
DMGS=("$BUILD"/*.dmg)
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
  # Finder draws a background at its own size and does not scale it to the window, so the background
  # has to be a 1x/@2x pair whose 1x is exactly the window size; a single-resolution image larger
  # than the window shows only its top-left corner. dmgbuild only combines the pair when it finds an
  # @2x beside the 1x, so this asserts the multi-resolution result is really what shipped.
  # (make-dmg.py additionally checks the 1x representation against the recorded window bounds.)
  BACKGROUND_FILE="$(ls "$MOUNT"/.background.* 2>/dev/null | head -1)"
  BACKGROUND_RESOLUTIONS=""
  [ -n "$BACKGROUND_FILE" ] && BACKGROUND_RESOLUTIONS="$(tiffutil -info "$BACKGROUND_FILE" 2>/dev/null | grep -c 'Image Width')"
  if [ "${BACKGROUND_RESOLUTIONS:-0}" -ge 2 ]; then
    pass "dmg background is a multi-resolution (1x/@2x) image"
  else
    fail "dmg background is not a 1x/@2x pair (Finder would not scale it to the window)"
  fi

  # The drag-and-drop layout is a .DS_Store at the root of the image: icon positions, the background
  # and the window size. Without it the DMG still mounts but looks like a plain folder.
  if [ -f "$MOUNT/.DS_Store" ]; then
    pass "dmg carries a drag-and-drop layout (.DS_Store)"
  else
    fail "dmg carries a drag-and-drop layout (.DS_Store)"
  fi
  check "app inside the dmg is signed" "codesign --verify --strict '$MOUNT/$APP_NAME.app'"
  check "app inside the dmg keeps its LSUIElement flag" \
    "[ \"\$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' '$MOUNT/$APP_NAME.app/Contents/Info.plist')\" = 'true' ]"

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
