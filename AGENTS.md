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
swift test                                         # 193 engine tests, all green
swift run NeoDrop                                  # run the app (menu bar icon)
swift build -c release --show-bin-path             # locate the release binary
scripts/package.sh [--arch universal] [--no-dmg]   # .app + DMG, ad-hoc signed by default
scripts/verify.sh --smoke                          # bundle, signature, DMG and a real launch
scripts/e2e.sh [--keep]                            # drive the packaged app against fake NAS folders
scripts/e2e-vault.sh [--keep]                      # two real installs, one vault: both directions
scripts/install.sh [--app path] [--no-enable]      # into /Applications + enable the Finder extension
scripts/reset.sh [--yes] [--trash] [--app]         # clean-install: state only, dry run by default
scripts/uninstall.sh [--yes] [--keep-app|--keep-state] [--trash] [--app path]
                                                   # the other direction: app + Finder extension + state
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
    (`testDecodesAConfigWrittenBeforeVaultsExisted`). `Manifest` does the same for the same reason:
    `ManifestStore.load` turns a decode failure into an empty manifest, which on a share means
    uploading every file again (`testAManifestFromAnOlderBuildKeepsItsEntries`).
17. **A file NeoDrop did not write is never replaced.** Something else at a path the mirror wants is
    left exactly as it is — byte for byte — reported in the run's summary, and recorded in
    `Manifest.foreignPaths` so the Finder extension can badge it as `foreign`
    (`testAFileNeoDropDidNotWriteIsNeverReplaced`, `testAFileNeoDropDidNotWriteIsBadgedAsForeign`).
    This is the one copy that could destroy a file existing nowhere else, so the mirror gives up the
    path instead, and the next sync takes it once the file is out of the way. The same check is where
    a *lost manifest* is noticed: a file already carrying the source's exact bytes is **adopted** into
    the manifest rather than uploaded again — same size first, and only then a hash
    (`testAFileAlreadyOnTheShareWithTheSourcesBytesIsAdoptedInsteadOfUploaded`). That is what makes the
    clean-install instructions true, and what stops a fresh install from re-uploading a whole library.
    `scripts/e2e.sh` stages the real thing: a file put on NAS1 by hand at a path the source then gains,
    checked byte for byte after the app's own sync.

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

## The first-run wizard (`SetupWizard.swift`)

A pristine configuration — no sources, no replicas, no vaults — is a fresh install or a cleared
state directory, and the app used to meet it with an empty Settings window whose tabs each assumed
you already knew what a source, a destination and a vault were. The wizard asks the one question a
person can answer (which folder matters most) and then how it should be protected, so the two modes
are explained rather than discovered.

Two rules keep it from becoming a nuisance or a liar:

* **It is offered once.** `AppConfig.didOfferSetup` is set the moment it is shown, so somebody who
  deliberately closes it is not asked again on every launch; “Set Up NeoDrop…” in the menu brings it
  back. Without that flag a pristine-but-intentional configuration would be nagged on every start.
* **It configures through the model**, not by writing `config.json`: `addVault`, `addSource`,
  `addReplica` and `setMachineName` are the same calls the Settings tabs make, so the wizard cannot
  create a combination the rest of the app would refuse. When the model refuses one it says why
  through `banner`, and the wizard shows that instead of closing on a setup that did not happen.

## File status, and the Finder helper

`FileStatus.swift` answers the question a person actually has about a file: *is this safe?* It
names every place the file exists — each source, this Mac's half of each two-way folder, each
destination, the shared copy in each vault, and anything a trash or a vault is retaining — plus the
record NeoDrop has for each copy (source index, manifest, journal, deletion) and the vault's history
for the path, newest first.

**It never hashes the file.** That is a decision, not an omission: the menu item and the Finder
service run on whatever the user selected, including a multi-gigabyte video, and re-reading it would
turn a click into a wait. So a copy is reported as matching when its size and date agree with what
was recorded, and the report says exactly that — "run Verify & Repair to check the bytes" — rather
than implying a digest check. If a *faster* answer is ever wanted, cache a digest; do not weaken the
wording. `testLargeFilesAreNotHashedToAnswerTheQuestion` holds the cost as a property: asking about
an 8 MB file must not cost more than asking about a small one.

The two UI surfaces are the **File Status…** menu item (asks which file) and the Finder service
(gets the selection), and both open the same page over the same loopback server:

```
Finder → right-click → Services → “Show NeoDrop Status”
        ↳ AppDelegate.showFileStatus(_:userData:error:)   the selector, named in packaging/Info.plist.in
        ↳ AppModel.fileStatus(path:) → FileStatusQuery    reads manifests, index, records, journals
        ↳ /<token>/status?path=…  → WebUIPage.statusHTML   one document, every value escaped
```

The plist and the selector only work as a pair, and `scripts/verify.sh` checks both halves — a
service naming a selector nobody implements is a menu item that silently does nothing. Two details
worth keeping:

* `NSServices` accepts `public.item`, so the service also appears for files outside NeoDrop's folders.
  That is deliberate: "not in any NeoDrop folder" is a useful answer, and a service that vanishes for
  the wrong selection teaches people it is broken.
* The status page is rendered on the server rather than fetched by script (unlike the deleted-files
  page, which acts on the user's behalf). There is nothing to act on, so there is no `fetch` and no
  script — and everything it prints is user data, so `WebUIPage.escape` is not optional.

## The web views (deleted files, file status)

The “Deleted Files…” and “File Status…” windows open a `WKWebView` onto a loopback HTTP server in
`NeoDropCore` (`WebUIServer.swift` serves, `WebUIPage.swift` holds both self-contained documents).
It is deliberately small, and the parts that make it safe are not decoration:

* it binds `127.0.0.1` only, on a port the OS picks;
* every route sits behind a random per-launch token in the path, and a request without it gets a
  plain 404 so an unrelated local process cannot even tell the server is there;
* the `Host` header must name a loopback host, and a `POST` carrying a foreign `Origin` is refused;
* the page makes no external requests, so its CSP allows nothing but its own inline style and script.

The engine owns the data (`listDeletions`, `restore`, `purgeExpiredDeletions`, and the read-only
`FileStatusQuery`); the server only formats it. Config reaches the handlers through `AppModel`,
because the engine must never re-read `config.json`. The app logs the page URL on startup
(`Deleted files view ready at …`), which is how `scripts/e2e.sh` drives it. The status route is
optional in the initialiser so the deleted-files half can be built and tested on its own, and it
answers 404 until a handler is supplied.

One subtlety in the query string: `HTTPRequest.query` does **not** decode `+` as a space, unlike a
form submission. A file name may contain a literal `+`, and form-style decoding would silently
answer about a different file. Spaces arrive percent-encoded, which is what the app sends.

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

## The Finder badges (`Sources/NeoDropFinder`, `Sources/NeoDropShared`)

The icons next to a file's date come from a **Finder Sync extension** (`com.apple.FinderSync`), not
from a menu item and not from the FileProvider framework. Finder Sync is the right tool because
NeoDrop's files are always fully local — there is no online-only state to report, which is what
FileProvider decorations are for — while a badge is exactly "does this look right?".

Four separate things had to be true before Finder showed anything, and every one of them fails
silently: `pluginkit -m -p com.apple.FinderSync` simply does not list the extension and no error is
logged anywhere obvious. They are worth knowing before touching `scripts/package.sh`:

1. **The bundle** needs `CFBundlePackageType XPC!`, `NSExtension` with the FinderSync extension
   point and a principal class, and the three platform keys an Xcode-built appex always carries
   (`CFBundleSupportedPlatforms`, `DTPlatformName`, `DTSDKName`). See
   `packaging/FinderExtension-Info.plist.in`.
2. **The executable must be a Mach-O `MH_EXECUTE` linked with `NSExtensionMain`** — what Xcode
   produces. `swiftc -emit-library` (a dylib) and `ld -bundle` are both ignored by PlugInKit, and
   neither can carry entitlements in its signature: parsing the superblob of an MH_BUNDLE signed
   ad-hoc *or* with an Apple Development certificate shows only CodeDirectory and Requirements,
   while an MH_EXECUTE gets the Entitlements and DEREntitlements blobs. Dropbox's own Finder
   extension (`…/garcon.appex/Contents/MacOS/garcon`) is an MH_EXECUTE with `LC_MAIN` for the same
   reason. `scripts/verify.sh` asserts the shape, because a regression here is invisible.
3. **The extension must be sandboxed.** PlugInKit refuses one that is not ("plug-ins must be
   sandboxed", in the system log only). It therefore also has to live in `/Applications` — PlugInKit
   only considers extensions of an app it finds in a standard location — which is what
   `scripts/install.sh` is for, and what makes `build/NeoDrop.app` alone insufficient for testing
   badges by hand.
4. **The badge index has to reach it**, and this is the part that had to be measured. It is published
   into the extension's *own container*, and an App Group cannot do the job: `~/Library/Group
   Containers` is closed to the unsandboxed app (EPERM writing into one, with an ad-hoc signature and
   with an Apple Development certificate alike — "You don't have permission to save the file … in the
   folder group.…"), and a sandboxed process is refused too when the container was created by another
   bundle. A container is where the two processes meet, but only when both bundles carry the same team
   identity — that is the second half of this, measured below, and it is why an ad-hoc build badges
   nothing. `FinderStatusIndex` spells both sides out (`extensionIndexURL` for the extension,
   `extensionContainerIndexURL` for the app), a unit test holds them together, `scripts/verify.sh`
   refuses an App Group in either entitlement file, checks the app names the container of the extension
   it ships and compares the two team identifiers, and `scripts/e2e.sh` asserts the packaged app
   actually publishes there when LaunchServices starts it.

Inside, everything is a lookup: `FinderStatusIndex` is a small JSON file of *exceptions* — paths
whose badge is not "in sync" — plus the roots NeoDrop protects. `requestBadgeIdentifier` answers
from a dictionary, so Finder's scroll path never walks a tree or hashes anything, and a library of a
million files costs the same as an empty one. The extension never opens a user's file at all; Finder
hands it URLs and the index hands it badge identifiers.

`NEODROP_HOME` is deliberately **not** honoured: the extension is registered once for the installed
app, and a scratch installation is not what the Finder showing the user's files should be about.

### Status: the badge channel works, and needs a team signature

**Measured on macOS 26, and the channel was never the problem: the signature decides.** The app
publishes the index into the extension's own container because that is the only path a sandboxed
extension can read. Since macOS 14 that container is protected from processes outside the *team* that
owns it — macOS asks before an app reaches another developer's data container, and apps signed by one
Team ID may reach each other's by default — and an ad-hoc signature carries no team at all:

* **ad-hoc** (this repo's default build, and everything `swift run` produces): every write is refused,
  logged as `Finder badges could not be updated: You don't have permission to save the file
  “.finder-status.json.tmp-…” in the folder “NeoDrop”` (NSCocoaErrorDomain 513). The app carries on —
  `publishFinderStatus` catches and logs it, because a stale badge must never stop a sync — so the only
  symptom is badges that never appear, which is what made this look like a channel problem.
* **one team for both bundles** (`Apple Development: Carl Fearby`, team `JE22Z4DD8L`): `Finder badges
  updated: 0 folder(s), 0 needing attention`, and the container's `finder-status.json` is rewritten at
  launch (mtime == the launch second). `scripts/verify.sh` compares the two team identifiers and fails
  a build where they differ; an ad-hoc build is a note, because building without an Apple account is
  deliberate.

The **launch path** is the second half, and it is easy to miss: the same binary publishes when
LaunchServices starts it (`open -a`) and is refused when a shell starts it
(`NEODROP_HOME=… build/NeoDrop.app/Contents/MacOS/NeoDrop`), because the responsible process for a
shell-started run is the shell, which carries no team. `swift run NeoDrop` therefore never badges
anything even with a team signature: install it and let Finder start it. `scripts/e2e.sh` checks the
container half that way — its own instance is shell-launched, so it asserts the refusal there, and its
last section starts the installed app through `open` and asserts the publish.

Containers themselves are containermanagerd's, and nothing else removes one: `rm`, `mv`, Finder and
even `sudo rm -rf` are all refused (`Operation not permitted` on
`.com.apple.containermanagerd.metadata.plist`). That is why `reset.sh` reports the badge index as
*kept* and `uninstall.sh` leaves the container behind with its reason printed.

What a sandboxed extension can read, measured by logging from inside the extension itself:

| Path | Read |
| --- | --- |
| its own container | ✅ |
| `/tmp/…` | ❌ |
| `/Users/Shared/…` | ❌ |
| the app's `~/Library/Application Support/NeoDrop/` | ❌ |
| **a file inside the very folder it monitors** | ❌ |
| `~/Library/Group Containers/<group>` (as the unsandboxed app) | ❌ EPERM |

It also does not receive a distributed notification posted by an unsandboxed process (measured:
observer installed, notification posted, nothing delivered). So there is currently **no** file-based
channel from the app to a Finder Sync extension: the extension must be sandboxed, the app cannot be
(that is its whole job), and every readable location is either sealed or denied.

The marker test is gone, deliberately, and the reason is the point. It was left failing while the
refusal looked like a platform wall with no way through. It is not a wall — it is a signature — so the
test was asserting the wall rather than the rule, and keeping it would have gone on blaming macOS for
something `MACOS_SIGN_IDENTITY` fixes. What replaced it asserts whichever case the machine is in:
`FinderStatusTests.testTheContainerChannelWorksForTheOwningTeamAndIsRefusedOtherwise` publishes into
the real container and, when that is refused, requires the refusal to be a clean
`NSFileWriteNoPermissionError` rather than a crash, because the app has to keep syncing either way.
The other half of the old test — the app publishing *before* the extension has ever run, which needs
`save` to create the directory it needs — now runs against a scratch path in
`testPublishingCreatesTheDirectoryItNeeds`, where it can be asserted rather than hoped for.

What is still not built, and is the next real improvement:

1. **An XPC Mach service.** The app registers `NSXPCListener(machServiceName:)` and the extension
   connects with `com.apple.security.temporary-exception.mach-lookup.global-name` (Apple DTS: fine for
   direct distribution, awkward on the App Store). No shared file at all, live updates, and it works
   regardless of signatures — the entitlement lives on the extension, not on a team identity.
2. **A loopback HTTP channel.** The app already serves a page on loopback; with
   `com.apple.security.network.client` on the extension and a port it can find, the extension could
   pull the index. Apple DTS says local-network privacy does not apply to loopback. Untested here.
3. **A sandboxed app.** With the app sandboxed too, a team-signed App Group works properly — but the
   app would then need user-selected bookmarks for every share, which changes the product.

Do not go back to "it works on a fresh install and dies at the first update": that was the ad-hoc
signature all along. A channel is not what has to be right here — a signature is.

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

`scripts/reset.sh` is the clean-install path and is a dry run unless given `--yes`. It removes the
state directory, the preferences plist, the saved application state and the Finder badge index — and,
with `NEODROP_HOME` set, only that installation's state directory, never the real one's preferences.
It lists the folders in `config.json` as *not touched* before it does anything, and `--trash` moves
the state to the Trash so a reset made by mistake can be undone. Any change that would let it delete
a user's folder, or the vault's `.neodrop/` on a share, is a bug: the vault belongs to every machine.

`scripts/uninstall.sh` is the other direction: the app, the Finder extension and the state, for
somebody who is done with NeoDrop. It exists because none of those three go away together — the state
is in Application Support, and PlugInKit goes on loading the extension into Finder after the bundle
is in the Trash, from *any* copy it can see. Measured: with `/Applications/NeoDrop.app` removed and a
second `/Applications/NeoDropTest.app` installed, `pluginkit -r` appeared to do nothing because the
registration simply moved to the other copy. So it finds every bundle whose `CFBundleIdentifier` is
NeoDrop's instead of trusting one path, prints the copies PlugInKit is loading from even when they are
outside the locations it scans, deregisters while the bundle is still on disk (that is what
`pluginkit -r` needs), unregisters the bundle with `lsregister -u`, removes the app and the
`~/Library/Application Scripts/ai.storyteller.neodrop.finder/` directory macOS creates for the
extension, and then hands the state to `reset.sh` rather than keeping a second list of it. Dry run
unless given `--yes`, like the reset; exit 1 when something could not be removed.

The extension's sandbox container is deliberately left behind, and the reason is in the measurements:
on macOS 26 a process outside `~/Library/Containers/ai.storyteller.neodrop.finder` cannot create,
delete or even list inside it — `Operation not permitted` for the app as well, which is what its log
says at launch ("Finder badges could not be updated … You don't have permission to save the file").
So the badge index survives an uninstall, and `reset.sh` reports it as *kept* rather than as a failure
it cannot fix: it probes the directory with `[ -w ]`, which asks the kernel the same question the
removal would without changing anything, so a dry run never promises a deletion that cannot happen.
That sealing is the same one behind the badge limitation — see
`FinderStatusTests.testPublishingCreatesTheContainerDirectoryWhenTheExtensionHasNeverRun`.

`XCTUnwrap` takes an autoclosure and cannot contain `await`; use the local `unwrap(_:)` helper for
async engine calls.
