#!/usr/bin/env bash
#
# Build, package and (optionally) sign NeoDrop for macOS.
#
#   build/NeoDrop.app                                  the menu bar app
#   build/neodrop-<version>-macos-<arch>.dmg            drag-to-Applications installer
#
# Usage: scripts/package.sh [--arch arm64|x86_64|universal] [--skip-build] [--version X.Y.Z]
#                           [--no-dmg] [--force]
#
# --force  build even if a NeoDrop DMG is still mounted (see the stale-mount check below).
#
# Signing (env):
#   MACOS_SIGN_IDENTITY   codesign identity name or SHA-1.
#                         Default "-" = ad-hoc. Ad-hoc signing needs NO Apple Developer account,
#                         but the resulting app is NOT notarized: see the notice printed at the end
#                         and the "Installing the DMG" section of README.md.
#   MACOS_KEYCHAIN        keychain holding the identity (optional)
# Notarization (env; only meaningful with a real Developer ID and a paid Apple Developer account):
#   APPLE_ID, APPLE_PASSWORD (app-specific password), APPLE_TEAM_ID
#
# This script deliberately never fails just because there is no certificate: the whole point is
# that you can build and hand somebody a DMG without a developer licence.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
HERE="$ROOT/packaging"
BUILD="$ROOT/build"

APP_NAME="NeoDrop"
BUNDLE_ID="ai.storyteller.neodrop"
# Must stay in sync with LSMinimumSystemVersion in packaging/Info.plist.in.
MIN_OS="14.0"

ARCH="host"
SKIP_BUILD=0
MAKE_DMG=1
FORCE=0
VERSION=""

warn() { printf 'package.sh: %s\n' "$1" >&2; }
info() { printf '  %s\n' "$1"; }

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' |
    awk '{ line[n] = $0; n++ }
         END { while (n > 0 && line[n - 1] == "") n--
               for (i = 0; i < n; i++) print line[i] }'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --no-dmg) MAKE_DMG=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

case "$ARCH" in
  host|arm64|x86_64|universal) ;;
  *) warn "--arch must be arm64, x86_64 or universal"; exit 2 ;;
esac
if [ "$MAKE_DMG" -eq 1 ] && ! command -v diskutil >/dev/null 2>&1; then
  warn "diskutil is missing; building the .app only"
  MAKE_DMG=0
fi

case "$ARCH" in
  host) ARCH_FLAGS=(); ARCH_LABEL="$(uname -m)"; LIPO_TARGET="" ;;
  universal) ARCH_FLAGS=(--arch arm64 --arch x86_64); ARCH_LABEL="universal"; LIPO_TARGET="arm64 x86_64" ;;
  *) ARCH_FLAGS=(--arch "$ARCH"); ARCH_LABEL="$ARCH"; LIPO_TARGET="$ARCH" ;;
esac

# ---- version ----------------------------------------------------------------------------------
if [ -z "$VERSION" ]; then
  if VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null)"; then
    :
  else
    VERSION="0.1.0"
  fi
fi
# CFBundleShortVersionString has to be numeric X.Y.Z, whatever the tag looked like.
SHORT_VERSION="$(printf '%s' "$VERSION" | sed -E 's/^[vV]//; s/[^0-9.].*$//')"
[ -n "$SHORT_VERSION" ] || SHORT_VERSION="0.1.0"
[ "$(printf '%s' "$SHORT_VERSION" | awk -F. '{print NF}')" = "3" ] || SHORT_VERSION="$SHORT_VERSION.0"
SHORT_VERSION="$(printf '%s' "$SHORT_VERSION" | cut -d. -f1-3)"
BUILD_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "NeoDrop $VERSION ($SHORT_VERSION) · $ARCH_LABEL · ${BUILD_SHA}"

# ---- build ------------------------------------------------------------------------------------
if [ "$SKIP_BUILD" -eq 0 ]; then
  echo "Building…"
  ( cd "$ROOT" && swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} )
fi

BIN_PATH="$(cd "$ROOT" && swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BINARY="$BIN_PATH/$APP_NAME"
[ -x "$BINARY" ] || { warn "built binary not found at $BINARY"; exit 1; }

# ---- app bundle -------------------------------------------------------------------------------
APP="$BUILD/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@SHORT_VERSION@/$SHORT_VERSION/g" \
    -e "s/@BUILD_SHA@/$BUILD_SHA/g" \
    -e "s/@MIN_OS@/$MIN_OS/g" \
    "$HERE/Info.plist.in" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
if /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  info "LSUIElement set: menu bar only, no Dock icon"
else
  warn "Info.plist is missing LSUIElement; NeoDrop would appear in the Dock"
fi

# ---- icon -------------------------------------------------------------------------------------
# The supplied artwork lives in Resources/AppIcon.png. It gets masked into the macOS rounded square
# at the size Apple expects; --verify fails the build if the mask or the orientation is wrong, so a
# broken icon cannot be shipped silently. Without the artwork the generator draws a fallback.
echo "Building the icon…"
ICON_SOURCE="$ROOT/Resources/AppIcon.png"
if [ -f "$ICON_SOURCE" ]; then
  ( cd "$ROOT" && swift scripts/make-icon.swift "$BUILD/$APP_NAME.icns" --source "$ICON_SOURCE" --verify >/dev/null )
  info "icon: Resources/AppIcon.png → $(du -h "$BUILD/$APP_NAME.icns" | cut -f1) icns, mask and orientation verified"
else
  ( cd "$ROOT" && swift scripts/make-icon.swift "$BUILD/$APP_NAME.icns" >/dev/null )
  info "icon: procedural fallback (no Resources/AppIcon.png)"
fi
cp "$BUILD/$APP_NAME.icns" "$APP/Contents/Resources/$APP_NAME.icns"

# ---- menu bar icon ----------------------------------------------------------------------------
# The status item image is a template: AppKit tints it from its alpha channel and ignores the colour
# underneath, which is what lets one monochrome asset serve light and dark menu bars. It also means
# the failure modes are invisible in a file listing — an opaque background renders as a solid block,
# a mis-sized file is quietly scaled down — so the assets are verified first. A failure stops the
# build here rather than shipping an app whose only visible surface is a blank menu bar slot.
if [ -f "$ROOT/Resources/MenuBarIcon.png" ]; then
  if ! ( cd "$ROOT" && swift scripts/verify-menubar-icon.swift >"$BUILD/menubar-icon.log" 2>&1 ); then
    warn "the menu bar icon failed verification, so the build stops here:"
    grep -E "FAIL" "$BUILD/menubar-icon.log" | sed 's/^/       /' || true
    exit 1
  fi
  for SCALE_SUFFIX in "" "@2x" "@3x"; do
    cp "$ROOT/Resources/MenuBarIcon$SCALE_SUFFIX.png" "$APP/Contents/Resources/MenuBarIcon$SCALE_SUFFIX.png"
  done
  info "menu bar icon: Resources/MenuBarIcon.png (+@2x, @3x), template mask verified"
else
  info "menu bar icon: none in Resources/, so the app falls back to a system symbol"
fi

# ---- Finder extension -------------------------------------------------------------------------
# A Finder Sync extension is a bundle with a principal class and an NSExtension dictionary, which
# SwiftPM has no product type for, so it is compiled here with swiftc. It is compiled together with
# the one shared file it needs — the badge index format — rather than linked against NeoDropCore: the
# extension must keep working while the app is not running, so the less it shares at load time, the
# better. It has to be signed before the app that embeds it (see the signing step below), because
# signing the outer bundle does not reach nested code.
FINDER_EXTENSION="NeoDropFinder"
APPEX="$APP/Contents/PlugIns/$FINDER_EXTENSION.appex"
echo "Building the Finder extension…"
mkdir -p "$APPEX/Contents/MacOS"
EXT_TMP="$BUILD/finder-extension"
rm -rf "$EXT_TMP"
mkdir -p "$EXT_TMP"
EXT_SOURCES=("$ROOT/Sources/NeoDropFinder/SyncExtension.swift"
             "$ROOT/Sources/NeoDropShared/FinderStatus.swift")

build_extension_arch() {
  local arch="$1" out="$2" objects="$EXT_TMP/objects-$1"
  mkdir -p "$objects"
  # Compiled then linked by hand, and linked as a *executable* with `NSExtensionMain` as its entry
  # point — which is what Xcode produces for an app extension, and the only shape that works here.
  #
  # The alternatives were all tried and all fail in ways worth writing down, because each costs an
  # afternoon to rediscover:
  #
  #   * `swiftc -emit-library` (a dylib): PlugInKit never registers it, and the only diagnosis is a
  #     line in the system log — "plug-ins must be sandboxed" — because a dylib signature cannot carry
  #     the App Sandbox entitlement either;
  #   * `ld -bundle` (a real MH_BUNDLE): still no entitlement blob in the signature. Verified by
  #     parsing the superblob: an MH_BUNDLE signed ad-hoc *or* with an Apple Development certificate
  #     ends up with only CodeDirectory and Requirements. An MH_EXECUTE gets the Entitlements and
  #     DEREntitlements blobs. Dropbox's own Finder extension (…/garcon.appex/Contents/MacOS/garcon)
  #     is an MH_EXECUTE with LC_MAIN for exactly this reason.
  #
  # `ld` alone knows nothing about the Swift runtime, so it is handed the SDK and the runtime library
  # path; LC_LINKER_OPTION in the object files pulls in the rest.
  ( cd "$objects" && xcrun swiftc -O -parse-as-library -c \
      -module-name "$FINDER_EXTENSION" \
      -target "$arch-apple-macos$MIN_OS" \
      "${EXT_SOURCES[@]}" )
  xcrun ld -o "$out" "$objects"/*.o \
    -e _NSExtensionMain \
    -syslibroot "$(xcrun --show-sdk-path)" \
    -platform_version macos "$MIN_OS" "$MIN_OS" \
    -L/usr/lib/swift \
    -framework AppKit -framework FinderSync -framework Foundation -lSystem
}

if [ -n "$LIPO_TARGET" ]; then
  for ARCH_NAME in $LIPO_TARGET; do
    build_extension_arch "$ARCH_NAME" "$EXT_TMP/$ARCH_NAME"
  done
  lipo -create -output "$APPEX/Contents/MacOS/$FINDER_EXTENSION" "$EXT_TMP"/arm64 "$EXT_TMP"/x86_64
else
  build_extension_arch "$ARCH_LABEL" "$APPEX/Contents/MacOS/$FINDER_EXTENSION"
fi
chmod +x "$APPEX/Contents/MacOS/$FINDER_EXTENSION"
rm -rf "$EXT_TMP"

sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@SHORT_VERSION@/$SHORT_VERSION/g" \
    -e "s/@BUILD_SHA@/$BUILD_SHA/g" \
    -e "s/@MIN_OS@/$MIN_OS/g" \
    "$HERE/FinderExtension-Info.plist.in" > "$APPEX/Contents/Info.plist"
plutil -lint "$APPEX/Contents/Info.plist" >/dev/null
info "Finder extension: $APPEX ($ARCH_LABEL)"

# ---- entitlements sanity ----------------------------------------------------------------------
# A non-empty entitlement file is worth a second look: it means somebody added a capability.
if grep -q '<key>' "$HERE/entitlements.plist"; then
  warn "entitlements.plist declares capabilities; make sure each one is justified in a comment"
fi

# ---- sign -------------------------------------------------------------------------------------
IDENTITY="${MACOS_SIGN_IDENTITY:--}"
KEYCHAIN_ARG=()
if [ -n "${MACOS_KEYCHAIN:-}" ]; then
  KEYCHAIN_ARG=(--keychain "$MACOS_KEYCHAIN")
fi

echo "Signing with identity: $IDENTITY"
# Nested code first: the extension is its own bundle and Gatekeeper validates it on its own, because
# Finder is what loads it. `--force` on the outer bundle would not reach it. It gets its own
# entitlements file — the App Sandbox, and nothing else — because PlugInKit refuses to register an
# extension that is not sandboxed. The badge index reaches it through its own container, which the
# app writes from outside; an App Group cannot do that job and is not declared (see
# packaging/entitlements.plist).
codesign --force --options runtime --timestamp=none \
  --entitlements "$HERE/FinderExtension-entitlements.plist" \
  --sign "$IDENTITY" \
  ${KEYCHAIN_ARG[@]+"${KEYCHAIN_ARG[@]}"} \
  "$APPEX"
codesign --verify --strict "$APPEX"

codesign --force --options runtime --timestamp=none \
  --entitlements "$HERE/entitlements.plist" \
  --sign "$IDENTITY" \
  ${KEYCHAIN_ARG[@]+"${KEYCHAIN_ARG[@]}"} \
  "$APP"
codesign --verify --strict --verbose=1 "$APP"

if [ "$IDENTITY" = "-" ]; then
  info "ad-hoc signature: fine for this Mac, NOT accepted by Gatekeeper on other Macs"
fi

# ---- optional notarization --------------------------------------------------------------------
if [ "${IDENTITY}" != "-" ] && [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_PASSWORD:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  echo "Notarizing…"
  ZIP="$BUILD/$APP_NAME-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
else
  info "skipping notarization (needs a Developer ID identity plus APPLE_ID/APPLE_PASSWORD/APPLE_TEAM_ID)"
fi

# ---- dmg --------------------------------------------------------------------------------------
DMG=""
if [ "$MAKE_DMG" -eq 1 ]; then
  # An attached disk image keeps serving the bytes it was opened with, so replacing the .dmg while
  # it is mounted leaves a stale volume behind and the next mount is named "NeoDrop 1" — which then
  # silently contains the previous build. Refuse rather than create that confusion.
  # Only mount points count: `hdiutil info` also lists the underlying device chain
  # (partition scheme, APFS container), which must never be handed to `diskutil eject`.
  MOUNTED_VOLUMES="$(hdiutil info 2>/dev/null | awk -v dir="$(cd "$BUILD" && pwd -P)" '
    /^image-path/ { current = $3 }
    /^\/dev\// && index(current, dir "/neodrop-") == 1 && $NF ~ /^\/Volumes\// { print $NF }
  ' | sort -u)"

  if [ -n "$MOUNTED_VOLUMES" ] && [ "$FORCE" -eq 0 ]; then
    warn "a NeoDrop DMG is currently mounted: $MOUNTED_VOLUMES"
    warn "an attached image keeps its old contents, so repackaging now would leave a stale volume behind"
    warn "eject it first, then re-run:"
    for volume in $MOUNTED_VOLUMES; do warn "  diskutil eject \"$volume\""; done
    warn "or re-run with --force to build anyway"
    exit 1
  fi

  # Lowercase by hand: macOS ships bash 3.2, which has no ${var,,} expansion.
  APP_SLUG="$(printf '%s' "$APP_NAME" | tr '[:upper:]' '[:lower:]')"
  DMG="$BUILD/$APP_SLUG-$VERSION-macos-$ARCH_LABEL.dmg"
  rm -f "$DMG"

  # Both layouts need the first-launch instructions, so they are written once here.
  README_FILE="$BUILD/Read Me First.txt"
  cat > "$README_FILE" <<'NOTE'
NeoDrop — first launch
======================

NeoDrop is not notarized by Apple (that needs a paid Apple Developer account), so macOS will
refuse to open it the first time with "Apple could not verify NeoDrop is free of malware".

The Control-click → Open shortcut no longer works on macOS 15 and later. To allow it once:

  System Settings → Privacy & Security → scroll down → "Open Anyway" → enter your password.

Alternatively, in Terminal:

  xattr -dr com.apple.quarantine /Applications/NeoDrop.app

NeoDrop has no Dock icon. After launching, look for the drive icon in the menu bar.

It will not sync anything until you choose a source folder and at least one destination in
Settings… — both start empty on purpose.
NOTE

  # ---- preferred: the drag-and-drop installer ---------------------------------------------------
  # The layout, the background and the icon positions all live in the image's .DS_Store, which is
  # written by dmgbuild (scripts/make-dmg.py). AppleScript driving Finder would need Automation
  # permission and a GUI session; dmgbuild works headlessly and verifies its own output.
  # The largest icon size this build will ask for. Nothing documented pins the ceiling down, so it
  # stays conservative: measured on macOS 26 by capturing a mounted window, Finder honours 320 and 384
  # exactly, and the size the layout asks for is 254. Keeping the ask below 256 means an over-large
  # value is never silently clamped, which would leave the window at some size other than the one its
  # background was drawn for.
  MAX_ICON_SIZE=256

  if [ -x "$ROOT/.venv/bin/python" ] && [ -f "$ROOT/Resources/dmg-background.png" ]; then
    echo "Building the drag-and-drop installer…"
    LAYOUT="$BUILD/dmg-layout.json"
    ARTWORK="$ROOT/Resources/dmg-background.png"  # the master art, as supplied
    BACKGROUND="$BUILD/dmg-background.png"        # 1x; make-dmg.py's dmgbuild finds the @2x beside it

    # The background is the supplied wallpaper, cropped to cover the window and darkened so Finder
    # draws white labels on it. Nothing is drawn on top: every element an earlier artwork drew (copies
    # of the icons, an arrow, a caption) was something the real icons could disagree with.
    BACKGROUND_JSON="$BUILD/dmg-background.json"
    : > "$BACKGROUND_JSON"
    # The crops describe themselves: the same run writes the layout the icons are placed from, so the
    # background and the positions can never be measured from different images.
    swift "$ROOT/scripts/make-dmg-artwork.swift" --source "$ARTWORK" \
      --out "$BACKGROUND" --layout-out "$LAYOUT" --json > "$BACKGROUND_JSON" \
      || warn "could not draw the installer background"
    BACKGROUND_2X="${BACKGROUND%.*}"@2x."${BACKGROUND##*.}"
    # Read back the numbers it recorded; a layout whose icon size exceeds the limit would ship the
    # doubled-icon artefact, so that case refuses rather than warns.
    ICON_SIZE="$("$ROOT/.venv/bin/python" -c "import json;print(json.load(open('$LAYOUT'))['iconSize'])" 2>/dev/null || echo 0)"
    WINDOW_WIDTH="$("$ROOT/.venv/bin/python" -c "import json;print(json.load(open('$LAYOUT'))['window']['width'])" 2>/dev/null || echo 0)"
    info "installer window ${WINDOW_WIDTH}pt wide, icon size ${ICON_SIZE}pt (limit $MAX_ICON_SIZE)"
    if [ "$ICON_SIZE" -gt "$MAX_ICON_SIZE" ]; then
      warn "the layout asks for an icon size above $MAX_ICON_SIZE, which Finder may clamp"
      warn "that would leave the icons somewhere other than where the background expects them"
      LAYOUT="/nonexistent"
    fi
    if [ -f "$LAYOUT" ] && "$ROOT/.venv/bin/python" "$ROOT/scripts/make-dmg.py" \
        --app "$APP" \
        --output "$DMG" \
        --background "$BACKGROUND" \
        --layout "$LAYOUT" \
        --badge-icon "$BUILD/$APP_NAME.icns" \
        --readme "$README_FILE" \
        --volume-name "$APP_NAME"; then
      info "drag-and-drop layout verified"
    else
      warn "the drag-and-drop DMG failed; falling back to a plain image"
      rm -f "$DMG"
    fi
  else
    info "dmgbuild is not set up, so the installer will be a plain window"
    info "run scripts/setup-dmg-tools.sh for the drag-and-drop layout"
  fi

  # ---- fallback: a plain image with the same payload -------------------------------------------
  if [ ! -f "$DMG" ]; then
    STAGE="$BUILD/dmg-stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp "$README_FILE" "$STAGE/"

    # Give the mounted DMG the app's icon in Finder. The custom-icon bit has to be set on the
    # folder before the image is created, so use SetFile here rather than after diskutil.
    cp "$APP/Contents/Resources/$APP_NAME.icns" "$STAGE/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
      SetFile -a C "$STAGE" && info "dmg volume icon set"
    elif xcrun -f SetFile >/dev/null 2>&1; then
      "$(xcrun -f SetFile)" -a C "$STAGE" && info "dmg volume icon set"
    else
      warn "SetFile not found (install the Xcode command line tools); the DMG will show a generic disk icon"
    fi

    # `diskutil image create` rather than `hdiutil create`, which macOS 27 deprecates.
    # UDZO is the compressed read-only format that stays small and mounts anywhere.
    diskutil image create from --format UDZO --volumeName "$APP_NAME" "$STAGE" "$DMG" >/dev/null
    rm -rf "$STAGE"
  fi

  info "dmg: $DMG ($(du -h "$DMG" | cut -f1))"
fi

echo
echo "Done."
echo "  app: $APP"
[ -n "$DMG" ] && echo "  dmg: $DMG"
echo
if [ "$IDENTITY" = "-" ]; then
  cat <<'NOTE'
Gatekeeper, honestly
====================
This build is ad-hoc signed and not notarized. That is fine for:
  * running it from this folder on this Mac;
but on any other Mac the user must approve it once via
  System Settings → Privacy & Security → "Open Anyway"
(the old Control-click → Open bypass was removed in macOS 15).

If you want a DMG that just opens everywhere, you need a paid Apple Developer account
(99 USD/year) for a Developer ID certificate, then set MACOS_SIGN_IDENTITY plus
APPLE_ID/APPLE_PASSWORD/APPLE_TEAM_ID and re-run this script: it will notarize and staple.
NOTE
fi
