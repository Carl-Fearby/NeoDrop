# AGENTS.md

Guidance for automated agents working in this repository.

## What this is

NeoDrop is a macOS menu bar app (Swift 6, SPM, `NeoDropCore` library + `NeoDrop` executable) with
two modes. A **replica** is a one-way mirror: local folders copied in full to mounted NAS shares,
verified by checksum and repaired. A **vault** (`VaultLink`) is a two-way Dropbox-shaped folder: one
local working copy paired with one shared tree on a share, with every machine that points at it
publishing and applying changes. Both can be configured at once and run independently. There is no
server and no cloud component.

## Commands

```bash
swift build                                        # compile everything
swift test                                         # 146 engine tests, must stay green
swift run NeoDrop                                  # run the app (menu bar icon)
swift build -c release --show-bin-path             # locate the release binary
scripts/package.sh [--arch universal] [--no-dmg]   # .app + DMG, ad-hoc signed by default
scripts/verify.sh --smoke                          # bundle, signature, DMG and a real launch
scripts/e2e.sh [--keep]                            # drive the packaged app against fake NAS folders
scripts/e2e-vault.sh [--keep]                      # two real installs, one vault: both directions
scripts/fake-nas.sh create 3 | destroy | list      # real mounted volumes to test against
swift scripts/make-icon.swift build/NeoDrop.icns --source Resources/AppIcon.png --verify
swift scripts/verify-menubar-icon.swift                        # menu bar template icon checks
swift scripts/make-dmg-artwork.swift --source Resources/dmg-background.png \
    --out build/dmg-background.png --layout-out build/dmg-layout.json   # background pair + layout
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
7. **A deletion is recorded before it happens, and the bytes outlive it by 30 days.** The file is
   moved into `.neodrop-trash/` on each replica with a record describing where it came from, and a
   restore never overwrites anything (`testDeletedFileIsRetainedInsteadOfDestroyed`,
   `testRestoreRefusesToOverwriteADifferentFile`). Records and bytes are removed together, and only
   once the window has closed (`testExpiredRecordIsPurgedWithItsBytes`).
8. **A record is data, not a command.** Every path read out of a record is checked to be inside the
   directory it belongs in before anything is deleted, written or restored
   (`testRecordThatEscapesTheTrashDirectoryIsNeverActedOn`).
9. **A two-way folder and its vault are never created, and never nested in one another.** Both must
   already exist, and they must be disjoint; overlap is refused before existence is even checked,
   because "the share is not mounted" is the wrong thing to tell someone whose vault is inside the
   folder it syncs (`testMissingLocalFolderIsRefusedRatherThanCreated`,
   `testVaultInsideTheLocalFolderIsRefused`).
10. **A conflict keeps both versions.** The vault's content keeps the original name and this
    machine's version becomes a conflicted copy, published so the other machines converge on the
    same result (`testSimultaneousEditsKeepBothVersionsOnBothMachines`).
11. **Changes on the share are never ordered by a clock alone.** Timestamps carry milliseconds and,
    when two entries share an instant, the entry written on top of the other's content wins
    (`testBackToBackEditsWithinTheSameSecondAllPropagate`). Whole-second timestamps made two edits
    compare equal and the machine-id tie-break then *reverted a real edit* — reproduced, then fixed.
12. **Bytes land on the share before the journal records them**, so a crash in between re-publishes
    a change rather than losing one. A torn final journal line is ignored; a torn middle one is
    reported as corruption (`testTornJournalLineIsIgnoredAndTheChangeIsRepublished`,
    `testBytesOnTheShareWithoutAJournalLineAreAnnouncedByTheNextSync`).
13. **The bulk-deletion guard covers remote deletions too.** A journal that would empty a folder is
    held back on the receiving machine, not applied (`testRemoteBulkDeletionIsHeldBackOnTheReceivingMachine`).
14. **A restore into a two-way folder is an undelete, and it is recorded as one.** A file put back
    through the recovery window is published as new content so every machine gets it back; a Mac that
    merely missed the deletion keeps a conflicted copy and the deletion stands
    (`testADeletionFromAnotherMachineIsRestorableAndTheUndeleteIsPublished`). `PendingUndeleteStore`
    is what distinguishes the two — they are indistinguishable in the folder itself.
15. **Paths are compared canonically** (`PathIdentity`), never as raw strings. `/var` and
    `/private/var` are the same directory, and `FileManager`'s enumerator returns the `/private`
    spelling while configuration files hold the other one — comparing them raw made a configured
    folder disagree with itself and refused a legitimate restore
    (`testTheTwoSpellingsOfVarAreOneDirectory`, and the right fix is *never* a raw
    `hasPrefix` on `URL.path`).
16. **A config file that fails to decode must never be treated as an empty configuration.**
    `AppConfig` decodes by hand with defaults for missing keys, so an older file (no `vaults`) or a
    newer key loads rather than silently forgetting every source and destination
    (`testDecodesAConfigWrittenBeforeVaultsExisted`).

## Two-way sync (`Vault.swift`, `VaultSync.swift`)

The model, in one paragraph: the share holds the canonical tree as ordinary files, plus a hidden
`.neodrop/` directory with an identity, **one append-only journal file per machine** (so writers
never contend) and content-addressed **versions** of anything overwritten or deleted. Each machine
keeps its own identity and a **cursor** locally — the content it and the vault last agreed on — and
the reconcile is a three-way merge per path: local-only change → publish; vault-only change → apply;
both → conflict; deleted locally → publish a deletion; deleted remotely and unchanged here → move
into this machine's `.neodrop-trash/` with a record.

Things that are easy to get wrong and are therefore deliberate:

* **Cursors and identities are local, never in the vault.** A machine that shared another's identity
  would be a second writer on one journal file.
* **Ordering** is `JournalEntry.precedes`: milliseconds first, then causality (`previousSha256`
  pointing at the other entry's `sha256` means "written on top of it"), then a deterministic
  machine/seq tie-break that is arbitrary but identical on every machine. Never order by mtime across
  machines, and never by whole-second timestamps — that was a real, reproduced data-reverting bug.
* **Paths are normalised** (NFC, and case-folded for the comparison key) before they are used as keys,
  because macOS hands out decomposed Unicode and SMB mostly ignores case: comparing raw spellings
  shows up as permanent phantom conflicts. `Scanner.relativePath` keeps the on-disk spelling for
  touching the filesystem; `VaultPath.key` is what everything compares.
* **Hidden files sync in vault mode.** `Scanner.scan(includeHidden:)` exists for this: a two-way tool
  that quietly skipped `.env` would be a trap. `.neodrop/` and `.neodrop-trash/` are always skipped
  (`hardSkips`), on both sides.
* **Files a person put in the vault by hand are adopted**, attributed to the machine that noticed
  them, including at a path a tombstone covers. A share that ignores what is dropped into it is not a
  share. Adoption is not a licence to lose anything: publishing over bytes that no journal mentions
  retains them first, by hash.
* **A restore is an undelete, and it has to be written down.** `PendingUndeleteStore` (local, keyed
  by link id) marks a file the user put back through “Deleted Files…”, because the reconcile cannot
  tell that from a Mac that was asleep through the deletion — and those two must resolve differently.
  Markers are dropped once published, and pruned when the path is no longer a tombstone.
* **No `pruneEmptyDirectories` on the local side.** On a replica an empty directory is leftovers; a
  person's working copy is not NeoDrop's to tidy.

## The deleted-files web view

The “Deleted Files…” menu item opens a `WKWebView` onto a loopback HTTP server in `NeoDropCore`
(`WebUIServer.swift` serves, `WebUIPage.swift` is the single self-contained page). It is deliberately
small, and the parts that make it safe are not decoration:

* it binds `127.0.0.1` only, on a port the OS picks;
* every route sits behind a random per-launch token in the path, and a request without it gets a
  plain 404 so an unrelated local process cannot even tell the server is there;
* the `Host` header must name a loopback host, and a `POST` carrying a foreign `Origin` is refused;
* the page makes no external requests, so its CSP allows nothing but its own inline style and script.

The engine owns the data (`listDeletions`, `restore`, `purgeExpiredDeletions`); the server only
formats it. Config reaches the handlers through `AppModel`, because the engine must never re-read
`config.json`. The app logs the page URL on startup (`Deleted files view ready at …`), which is how
`scripts/e2e.sh` drives it.

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

Nothing is drawn on the installer background. It is the wallpaper supplied in
`Resources/dmg-background.png`, cropped to cover the window and darkened — and that is deliberately
all. Every earlier attempt drew something (copies of the icons for the real ones to land on, the
artwork's glyphs, an arrow, a caption) and every one of those elements became something the real
icons could disagree with: doubled icons, a caption the labels crossed, art scaled until the painted
tiles no longer lined up with the icons. Do not put anything back on it.

One pass writes both the background pair and the layout, so they cannot contradict each other:
`scripts/make-dmg-artwork.swift` crops the wallpaper to a 960x458 point window, writes
`build/dmg-background.png` plus its `@2x`, and writes `build/dmg-layout.json` describing the window
and the three slots — `Read Me First.txt` on the left, NeoDrop.app in the middle, `Applications` on
the right. `make-dmg.py` then mounts the finished image, reads its `.DS_Store` back, and asserts each
icon's box and label sit inside the window and clear each other.

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
* An unsupported `icon_size` is silently clamped by Finder. The layout asks for 254 points, which is
  under the 256 `package.sh` treats as the ceiling, and refuses to build a styled image above it.
* Finder chooses the label colour from the background picture: white with a shadow over a dark one,
  dark grey over a bright one. The wallpaper is multiplied down to 55% brightness for exactly this
  reason — a brighter version drew grey labels over mid-blue wave that could barely be read. If the
  labels ever come out grey again, the background got brighter, not the fonts.
* `Read Me First.txt` is **shown in the window**, in the left slot. It was hidden for a while ("the
  instructions should not clutter the window"), which is why `verify.sh` asserts the file is not
  carrying the hidden flag. `make-dmg.py` fails if it is not in its slot, or if its icon or label
  would touch another slot.
* In bash, `"$VAR@2x.png"` expands to `dmg-background.png@2x.png`, not `dmg-background@2x.png` — it
  silently measured the master artwork and produced a layout for a window that no longer existed.
  Use `"${VAR%.*}"@2x."${VAR##*.}"`.
* A mounted image keeps serving the bytes it was opened with, so `package.sh` refuses to repackage
  while a NeoDrop DMG is mounted. Use `--force` to override. `verify.sh` instead *reuses* an existing
  mount (its checks are read-only) rather than reporting a false `Resource busy` failure.
* NeoDrop is **MIT licensed** (`LICENSE`), covering the code and the artwork. Keep that file intact
  and keep any dependency licence-compatible — the permissive choice is deliberate, and it is what
  lets somebody fork this or lift the engine into their own tool.
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
* Never compare `URL.path` strings with `hasPrefix`. Use `PathIdentity`, which resolves the existing
  prefix of a path and appends the rest, so `/var/x` and `/private/var/x` agree and a file that no
  longer exists still compares against its folder.
* Shell scripts are `set -euo pipefail` or `set -uo pipefail`, POSIX-ish, and must run under the
  system `bash` 3.2 — no `${var,,}`, no associative arrays, no `mapfile`.
* Packaged apps are ad-hoc signed by default; assume no Developer ID is available.
* The app is `LSUIElement` (menu bar only). `scripts/verify.sh` fails if that flag disappears.

## Testing notes

`Tests/NeoDropCoreTests/Support.swift` provides `Sandbox`: a temp source folder plus N fake NAS
directories. It mints stable UUIDs once — manifests and the source index are keyed by UUID, so
handing out a fresh `Replica` per call silently points the engine at a different manifest.

`VaultSyncTests.swift` has its own `VaultSandbox`: one share directory and N *machines*, each with
its own state directory, its own `MachineIdentity` and its own local folder — two installs, which is
the arrangement the feature is for. A machine is `sandbox.sync(index)`; the assertion helpers are
`localFiles`, `vaultFiles` (the live tree, hidden files included, `.neodrop/` excluded),
`retainedVersions`, `trashFiles` and `journalLines`.

Two things to know when writing these tests:

* Timestamps matter. Anything that depends on ordering has to assume two changes can land in the
  same second — `testBackToBackEditsWithinTheSameSecondAllPropagate` is the regression test for the
  bug that made this non-negotiable.
* `scripts/e2e-vault.sh` is the end-to-end counterpart: it runs two real app instances (two
  `NEODROP_HOME` state directories) against one vault, so what it proves is the product, not the
  library. It uses the SwiftPM binary rather than the packaged `.app` because LaunchServices will not
  start a second copy of the same bundle — and two machines is the point.

`XCTUnwrap` takes an autoclosure and cannot contain `await`; use the local `unwrap(_:)` helper for
async engine calls.
