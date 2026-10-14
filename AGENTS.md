# AGENTS.md

Guidance for automated agents working in this repository.

## What this is

NeoDrop is a macOS menu bar app (Swift 6, SPM, `NeoDropCore` library + `NeoDrop` executable) that
mirrors local folders to multiple mounted NAS shares, verifies them by checksum and repairs them.
There is no server and no cloud component.

## Commands

```bash
swift build                                        # compile everything
swift test                                         # 68 engine tests, must stay green
swift run NeoDrop                                  # run the app (menu bar icon)
swift build -c release --show-bin-path             # locate the release binary
scripts/package.sh [--arch universal] [--no-dmg]   # .app + DMG, ad-hoc signed by default
scripts/verify.sh --smoke                          # bundle, signature, DMG and a real launch
scripts/e2e.sh [--keep]                            # drive the packaged app against fake NAS folders
scripts/fake-nas.sh create 3 | destroy | list      # real mounted volumes to test against
swift scripts/make-icon.swift build/NeoDrop.icns --source Resources/AppIcon.png --verify
swift scripts/verify-menubar-icon.swift                        # menu bar template icon checks
swift scripts/dmg-layout.swift Resources/dmg-background.png   # measure the master artwork
swift scripts/make-dmg-background.swift --source Resources/dmg-background.png \
    --layout build/dmg-layout.json --out build/dmg-background.png --limit 256
swift scripts/dmg-layout.swift build/dmg-background@2x.png    # re-measure the scaled pair
scripts/setup-dmg-tools.sh                                    # one-off: .venv + dmgbuild
./.venv/bin/python scripts/make-dmg.py --app build/NeoDrop.app --output build/x.dmg \
    --background build/dmg-background.png --layout build/dmg-layout.json \
    --badge-icon build/NeoDrop.icns --dump
```

## Invariants — do not weaken these

The product's entire value is that it does not destroy data. Each of these has a test; if you change
behaviour, change the test only with a written reason.

1. **Only manifest-tracked files are deleted from a replica.** Foreign files on a share are never
   touched (`testForeignFilesOnReplicaAreUntouched`).
2. **A replica root is never created by the engine.** If the share is unmounted, the path must read
   as offline — creating it would silently mirror onto the boot volume
   (`testEngineNeverCreatesAMissingReplicaRoot`, `testReplicaPathThatIsAFileIsOffline`).
3. **Deletions are refused when any source could not be read** (`testUnreadableSourceBlocksDeletions`).
4. **The bulk-deletion guard stands by default.** More than 25% of a replica, or 25 files, in one run
   requires `allowBulkDeletions` (`testBulkDeletionIsRefusedByDefault`).
5. **Copies are atomic**: temp file in the destination directory, `fsync`, then rename
   (`testAtomicCopyLeavesNoTempFilesBehind`).
6. **Verification re-hashes.** Never replace it with a size or mtime comparison
   (`testVerifyDetectsSilentCorruption`).

## The icon

`Resources/AppIcon.png` is the master artwork. `scripts/make-icon.swift` masks it into the macOS
rounded square (824px body, ~22% radius, on a 1024px canvas) and writes the ten sizes an `.iconset`
needs. `--verify` is not decoration: it asserts the transparent margin, that the corners are
rounded rather than square, that the artwork reaches every edge, and that the image is not
vertically flipped (by comparing brightness bands against the source PNG read from its own pixel
data, so a consistent flip cannot hide itself). Keep that check when editing the script — an
upside-down app icon is easy to ship and hard to notice.

## The menu bar icon

Separate artwork from the app icon: `Resources/MenuBarIcon.png` plus `@2x` and `@3x`, with
`MenuBarIcon.svg` as the vector master. Status item images are **template images** — AppKit draws
them from the alpha channel and tints them — which is why this set is a flat monochrome glyph while
the app icon is a colour render. `scripts/verify-menubar-icon.swift` runs inside `package.sh` and
stops the build on failure; `scripts/e2e.sh` asserts the packaged app loaded the artwork instead of
the fallback symbol, and that AppKit assembled all three representations — a 1x-only load would be
upscaled and would merely look soft, which is indistinguishable from badly drawn art afterwards.
The app reports both in its log line.

The checks exist because every failure here is silent, and one of them is a trap:

* An opaque background renders as a solid tinted block. Corner alpha is checked, not just file size.
* A mis-sized representation (a 512 master dropped in as the 1x) is silently scaled and looks soft.
* Assertions on the app's log line match a **prefix**: pinning the whole string made `e2e.sh` fail on
  a wording change rather than on a regression, and hard-coding the representation order that AppKit
  happens to report is the same mistake in a different costume.
* The black and white variants of this set are **identical in shape**, so comparing silhouettes — the
  obvious check, and the one this script first used — cannot detect a mixed-up deliverable at all.
  Only the ink colour separates them. Correlation of normalised glyph masks measured 0.71–0.885
  across sizes that are the same artwork, because at 18px the glyph is a 15.2×12.4 shape rounded to
  16×12; the metric was measuring rounding, not shape. Do not reintroduce it.

State is not drawn into the icon. The template is a single flat colour, so a badge composited over
it is the same ink as the chassis body and disappears into it; the tooltip and the menu carry state
instead. Adding a badge would mean knocking a transparent gap around it.

Without the PNGs in the bundle — `swift run`, or a packaging slip — `MenuController` falls back to
an SF Symbol so the menu bar is never empty, and logs that it did.

## The installer DMG

A DMG's icon positions and background live in a binary `.DS_Store` at the root of the image.
Writing it by hand is error-prone, and AppleScript driving Finder needs Automation permission plus
a GUI session (it hangs in a headless build), so `scripts/make-dmg.py` uses `dmgbuild`, installed
into `.venv/` by `scripts/setup-dmg-tools.sh`. That is the only non-Apple build dependency and it
is optional: without it `package.sh` builds a plain DMG.

The installer artwork has a NeoDrop icon and an Applications folder *painted into it*, so the real
icons must be placed exactly on top of the painted ones. Never hard-code those coordinates:
`scripts/dmg-layout.swift` measures them from the image, and `make-dmg.py` verifies the finished
`.DS_Store` — each real icon must cover its painted twin and must not cover the arrow or the
caption. Finder draws icons square, so the icon size comes from the taller axis of the painted app
icon, not its width, and it only fills ~80% of the box it is given (Apple's 1024 canvas has an 824
body), so the requested `icon_size` is the painted tile divided by 824/1024. Comparing the nominal
box against the painted tile instead — which reads as the obvious check — passes on an image that
visibly shows the painted icon around every edge.

The background is built, not shipped raw: `scripts/make-dmg-background.swift` writes a 1x/@2x pair
and `package.sh` measures the master, scales it, then measures the pair again, because scaling
rounds to whole points and the final icon size drifts a point or two from the predicted one. Pass 3
is what `make-dmg.py` consumes.

Gotchas worth keeping:

* `ds_store` returns record codes as bytes and mixed case (`b'Iloc'`, `b'icvp'`); normalise them.
* dmgbuild's `badge_icon` option is dead in 1.6.5 (`badge` is hard-coded `None` and the module
  imports Quartz/pyobjc). Use its `icon` option, then `SetFile -a C` on the mounted image — which
  is why the image is built read-write (UDRW) and compressed afterwards.
* Finder does **not** scale a window background to fit: it draws the image at its own size, so a
  single-resolution background larger than the window shows only its top-left corner. dmgbuild only
  combines a 1x/@2x pair when the `@2x` sits beside the 1x and produces `.background.tiff`; given
  one image it silently copies it. Both `make-dmg.py` and `verify.sh` assert the multi-resolution
  result, and `make-dmg.py` asserts the 1x representation equals the recorded window bounds.
* An unsupported `icon_size` is silently clamped by Finder, so an over-large value reintroduces the
  doubled icon rather than failing. The artwork is scaled to keep the implied size ≤ 256; `package.sh`
  refuses to build a styled image if it is not.
* In bash, `"$VAR@2x.png"` expands to `dmg-background.png@2x.png`, not `dmg-background@2x.png` — it
  silently measured the master artwork and produced a layout for a window that no longer existed.
  Use `"${VAR%.*}"@2x."${VAR##*.}"`.
* A mounted image keeps serving the bytes it was opened with, so `package.sh` refuses to repackage
  while a NeoDrop DMG is mounted. Use `--force` to override. `verify.sh` instead *reuses* an existing
  mount (its checks are read-only) rather than reporting a false `Resource busy` failure.
* The layout and background checks in `verify.sh` are conditional on the same thing `package.sh`
  tests for — `.venv/bin/python` plus `Resources/dmg-background.png`. Demanding them
  unconditionally made a fresh clone with no `dmgbuild` fail its own suite with two FAILs that were
  the documented plain-installer fallback working as designed. The condition still fails loudly when
  the tooling *is* present and the image came out plain, which is the regression worth catching.
* `verify.sh --smoke` launches the app with `NEODROP_HOME` pointed at a scratch directory. Without
  that it runs against the developer's real config and log, with their folder watchers live — a
  "smoke test" that could mirror files for real.

## Conventions

* `NeoDropCore` must not import AppKit or SwiftUI; it has to stay testable headlessly.
* The engine takes configuration as a parameter and must never re-read `config.json` from disk to
  interpret its own arguments.
* Home-grown state files are JSON written through `JSONFile.save` (temp + atomic replace).
* Shell scripts are `set -euo pipefail` or `set -uo pipefail`, POSIX-ish, and must run under the
  system `bash` 3.2 — no `${var,,}`, no associative arrays, no `mapfile`.
* Packaged apps are ad-hoc signed by default; assume no Developer ID is available.
* The app is `LSUIElement` (menu bar only). `scripts/verify.sh` fails if that flag disappears.

## Testing notes

`Tests/NeoDropCoreTests/Support.swift` provides `Sandbox`: a temp source folder plus N fake NAS
directories. It mints stable UUIDs once — manifests and the source index are keyed by UUID, so
handing out a fresh `Replica` per call silently points the engine at a different manifest.

`XCTUnwrap` takes an autoclosure and cannot contain `await`; use the local `unwrap(_:)` helper for
async engine calls.
