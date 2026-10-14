<p align="center">
  <b>NeoDrop — a menu bar app that keeps a full copy of your folders on every NAS you own.</b><br>
  <sub>Verified with SHA-256, repaired from whichever copy is still healthy. macOS 14+. Native Swift, no Electron, no cloud.</sub>
</p>

NeoDrop lives in the title bar. You point it at one or more local folders and at every mounted NAS
share; it mirrors the folders in full to each share, checks the copies against their checksums, and
rebuilds any copy that has rotted, been truncated, or disappeared. Dropbox gives you *a* copy you
don't control. NeoDrop gives you *the same folder on three machines in your own house*.

## Why it exists

A single NAS is a single point of failure, and RAID is not a backup. Copying to two NAS boxes by
hand works right up until the day you forget. NeoDrop is the boring, always-on version of that
habit:

* **Full mirror, not sync-with-a-server.** Every destination holds a complete, browsable copy. If
  this app dies tomorrow, your data is still just files on a share.
* **Checksums, not timestamps.** Verification re-reads and re-hashes. A file that is the right
  size and the wrong bytes is *not* healthy — see `testVerifyDetectsSilentCorruption`.
* **Repair from anywhere.** A bad copy is rewritten from the source, or from another replica when
  the source no longer has the file. A wiped NAS is rebuilt from the survivors.
* **No credentials, ever.** NeoDrop never sees a NAS password. It mounts shares by asking Finder,
  which uses the credentials already in your Keychain.
* **Nothing leaves the machine.** No account, no telemetry, no server.

## How it works

```
source folders ──► scan + SHA-256 ──► plan ──► per-replica diff ──► atomic copy ──► manifest
                                                                    (temp file + rename)
         FSEvents watcher ─┘                                              │
                                                                          ▼
                                              verify: re-hash every file vs manifest
                                              repair: rewrite what fails, from the best copy
```

One Swift package, two targets: `NeoDropCore` (engine, no AppKit, fully testable) and `NeoDrop`
(status item + SwiftUI settings).

### The five rules that keep it safe

These are the things that decide whether a tool like this protects data or destroys it, so they are
all enforced in code and covered by tests:

| Rule | Why |
|---|---|
| Only files NeoDrop wrote are ever deleted (tracked in a per-replica manifest) | A replica can share a volume with other data; foreign files are never touched |
| A replica root must already exist — it is never created | An unmounted share would otherwise make `/Volumes/NAS2/NeoDrop` resolve to the boot disk, and you'd "mirror" onto your own SSD |
| Deletions are refused when a source could not be read | A renamed or unplugged source folder must never be interpreted as "everything was deleted" |
| More than 25% of a replica (or 25 files) deleted in one run is refused unless explicitly allowed | Stops the signature mirroring disaster: one bad sync empties the NAS |
| Every copy goes through a temp file plus a rename in the destination folder | A dropped SMB connection leaves the old file, not a truncated new one |

A missing source folder, an offline share, or a failed write never stops the other replicas from
being brought up to date; it is reported and shown as degraded instead.

## Build and run from source

```bash
swift build                 # library + app
swift test                  # 68 engine tests
swift run NeoDrop           # menu bar icon appears immediately (reads/writes ~/Library/Application Support/NeoDrop)
```

## Create an installer DMG

```bash
scripts/setup-dmg-tools.sh              # one-off: installs dmgbuild into .venv (for the layout)
scripts/package.sh                      # host architecture, ad-hoc signed
scripts/package.sh --arch universal     # Intel + Apple Silicon
scripts/verify.sh --smoke               # structural checks plus a real 4-second launch
scripts/e2e.sh                          # drives the built app against simulated NAS folders
```

Output: `build/NeoDrop.app` and `build/neodrop-<version>-macos-<arch>.dmg`.

### The drag-and-drop installer window

Opening the DMG shows the artwork in `Resources/dmg-background.png` with the real NeoDrop.app on
the left, a real `Applications` drop target on the right, and the painted arrow and caption
between them.

The layout lives in a binary `.DS_Store` at the root of the image, which Finder reads for icon
positions, the background picture and the window size. Two ways to write it exist:

* AppleScript driving Finder — needs Automation permission and a logged-in GUI session, so it
  cannot run in a build script. Verify this for yourself with `osascript -e 'tell application
  "Finder" to get name of startup disk'`; it hangs on the permission prompt.
* `dmgbuild` — writes the `.DS_Store` directly, works headlessly. This is what `scripts/make-dmg.py`
  uses. It is the only non-Apple build dependency, it is optional, and the app itself has no Python
  dependency. Without `.venv/`, `package.sh` still produces a working (plain) DMG.

The artwork already has a NeoDrop icon and an Applications folder *painted into it*, so the real
icons have to land exactly on top of those or you get four icons in the window. Their positions are
measured from the image rather than guessed: `scripts/dmg-layout.swift` thresholds the artwork,
finds the two icon-shaped regions, and reports their centres and sizes. `make-dmg.py` then mounts
the finished DMG, reads the `.DS_Store` back, and asserts that each real icon covers its painted
twin and that neither covers the arrow or the caption.

Three measured passes feed each other, and `package.sh` runs all of them:

```
Resources/dmg-background.png ──measure──▶ the icon size the painted icons imply
                             ──scale────▶ build/dmg-background.png + @2x  (the 1x/@2x pair)
                             ──measure──▶ build/dmg-layout.json           (window + icon positions)
```

Two details decide whether the window looks like the artwork, and both are easy to get wrong:

**The background is a 1x/@2x pair, and the 1x is exactly the window size.** Finder draws a window
background at its own size instead of scaling it, so handing it the master artwork left it showing
only the top-left corner of the picture. The window is therefore 611x458 points with a 611x458
background and a 1222x916 `@2x` partner; dmgbuild finds the pair and combines them into a
multi-resolution TIFF (611x458 at 72 dpi, 1222x916 at 144 dpi) exactly as `tiffutil -cathidpicheck`
does for AppKit.

**The icon size has to account for the icon body grid.** A drawn app icon only fills about 80% of
the box it is asked for (Apple's canvas is 1024 with an 824 body), so asking for the painted tile's
own size would leave that tile peeking out all the way round the real icon — a doubled icon. The
requested size is the painted tile divided by 0.8047 (235x239 painted, so from the taller axis).
That works out to ~300 points for the master artwork, which is past the largest icon size Finder is
known to honour (256 — the icon-view slider is described as reaching 512, but an unsupported value
is *silently clamped*, which would put the doubling back). So `make-dmg-background.swift` scales the
artwork down by 15% until the implied size fits, which is where 611x458 comes from.

```bash
swift scripts/dmg-layout.swift Resources/dmg-background.png           # human-readable layout
swift scripts/make-dmg-background.swift --source Resources/dmg-background.png \
    --layout build/dmg-layout.json --out build/dmg-background.png --limit 256
swift scripts/dmg-layout.swift build/dmg-background@2x.png            # re-measure the scaled pair
scripts/package.sh --force                                            # rebuild while the DMG is mounted
```

**No Apple Developer account is needed to build, sign or ship the DMG.** `package.sh` defaults to
`-` (ad-hoc signing), which is a complete, valid signature that macOS accepts on the machine that
built it.

### The honest part: Gatekeeper

Ad-hoc signing cannot satisfy Gatekeeper on *someone else's* Mac, and notarization requires a paid
Apple Developer account (99 USD/year). Since macOS 15 there is no Control-click → Open bypass
either — Apple removed it. So a DMG you hand to a friend behaves like this:

1. They drag NeoDrop into Applications (the DMG includes the `/Applications` drop target).
2. First launch shows *"Apple could not verify NeoDrop is free of malware."*
3. They approve it once: **System Settings → Privacy & Security → scroll down → Open Anyway**.
   The DMG includes a `Read Me First.txt` with exactly this instruction.

To skip that step, either:

```bash
xattr -dr com.apple.quarantine /Applications/NeoDrop.app   # after installing
```

or get a Developer ID and make the DMG just work:

```bash
export MACOS_SIGN_IDENTITY="Developer ID Application: You (TEAMID)"
export APPLE_ID="you@example.com" APPLE_PASSWORD="app-specific-password" APPLE_TEAM_ID="TEAMID"
scripts/package.sh
```

`package.sh` then notarizes and staples automatically. The same DMG command, one set of
environment variables, no script changes.

## The icon

`Resources/AppIcon.png` is the master artwork (the NAS render). `scripts/make-icon.swift` masks it
into the macOS rounded square — an 824px body with a ~22% corner radius inside a 1024px canvas —
and writes every size macOS asks for.

```bash
swift scripts/make-icon.swift build/NeoDrop.icns --source Resources/AppIcon.png --verify
swift scripts/make-icon.swift build/NeoDrop.icns        # procedural fallback, no artwork needed
```

`package.sh` always passes `--verify`, which fails the build rather than shipping a bad icon. It
checks that the margin is transparent, that the corners are actually rounded (not a hard square),
that the artwork reaches every edge, and that the image did not come out vertically flipped — the
last one by comparing brightness bands of the written icon against the source file read straight
from its own pixels, so a flip cannot cancel itself out.

That icon is the *Finder and Dock* icon. The **menu bar has its own artwork**, a monochrome NAS
chassis: menu bar images are template images that macOS tints to match the bar, so the full-colour
3D render would be an illegible smudge at 18px. `Resources/MenuBarIcon.png` (with `@2x` and `@3x`
beside it, and the `MenuBarIcon.svg` vector master) is drawn from its alpha channel alone, which is
what makes one asset work in light mode, dark mode and with reduced transparency.

```bash
swift scripts/verify-menubar-icon.swift        # template mask, sizes, centring, ink polarity
```

`package.sh` runs that check first and refuses to build if it fails, then copies the three
representations into the bundle. The failures it looks for are all silent: an opaque background
renders as a solid tinted block, a mis-sized file is quietly scaled and looks soft, and the black
and white variants of this set are **identical in shape**, so silhouette comparison cannot tell them
apart — only the ink colour separates a mixed-up set. `scripts/e2e.sh` then asserts the packaged app
actually loaded the artwork rather than falling back: the app logs which it used.

**State is not drawn into the menu bar icon.** The artwork is a flat single-colour mask, so a badge
composited over it would be the same ink as the chassis body it sits on and would vanish into it;
doing it properly needs a knocked-out transparent gap around an 8-point badge on an 18-point canvas.
The tooltip carries the state instead, along with the menu, whose first line is the status and which
lists any issues. Without the artwork in the bundle (`swift run`) the app falls back to an SF Symbol
and says so in its log.

## Using it

NeoDrop refuses to guess, so it starts with nothing configured.

1. **Settings…** in the menu → **Sources** → *Add Folder…* — pick the folder to protect.
2. **Destinations** → *Add Destination…* — pick the folder on the mounted NAS. Create a `NeoDrop`
   folder inside the share first if you like; each destination holds a complete copy.
3. Repeat for every NAS. **Two destinations on separate NAS boxes is the point** — NeoDrop warns you
   when two replicas land on the same volume, because they would fail together.
4. Save an optional `smb://nas.local/share` address per destination; the menu then offers
   *Mount …*, which asks Finder to connect (using your Keychain) and syncs once it appears.

The menu shows each replica's status, file count, last sync and last verify, plus **Sync Now**,
**Verify & Repair All**, a per-replica verify, and an activity log.

### Trying it without a NAS

```bash
scripts/fake-nas.sh create 3     # mounts three real volumes: /Volumes/NeoDropNAS1..3
scripts/fake-nas.sh destroy      # unmount and delete them
```

They are genuine mounted APFS volumes, so the app treats them exactly like NAS shares — including
the warning when two replicas share a volume.

## Layout

```
Sources/NeoDropCore/     engine: scanning, hashing, mirroring, verification, repair
  MirrorEngine.swift     sync / verify / repair, plus the deletion guard
  Scanner.swift          enumeration, excludes, cached source hashes
  Hashing.swift          streaming SHA-256, durable atomic writes
  Storage.swift          config, manifests, source index, runtime state (JSON)
  Volumes.swift          volume identity, SMB mount requests, boot-volume detection
  ConfigValidator.swift  "this configuration does not actually protect anything" checks
  FolderWatcher.swift    FSEvents with debounce
Sources/NeoDrop/         menu bar app: status item, menu, SwiftUI settings
Tests/NeoDropCoreTests/  68 tests, including one per safety rule above
Resources/AppIcon.png    master app-icon artwork, masked by scripts/make-icon.swift
Resources/MenuBarIcon*.png  menu bar template icon at 1x/2x/3x, plus the .svg master
Resources/dmg-background.png  installer window artwork, as supplied (the master)
scripts/                 build, icon generation, packaging, verification, e2e, fake NAS
  make-icon.swift        app icon: masking, all ten sizes, mask + orientation checks
  verify-menubar-icon.swift  menu bar icon: template mask, sizes, centring, ink polarity
  dmg-layout.swift       measures the installer artwork to place the real icons
  make-dmg-background.swift  scales the artwork into the 1x/@2x background pair
  make-dmg.py            builds the drag-and-drop DMG and verifies the written layout
  setup-dmg-tools.sh     installs dmgbuild into .venv (optional, for the layout)
packaging/               Info.plist template, entitlements
build/                   generated: NeoDrop.app, .icns, .dmg
```

State lives in `~/Library/Application Support/NeoDrop/`: `config.json`, a manifest per replica, the
source hash index, `runtime-state.json` and a rolling `neodrop.log`. Delete that folder and NeoDrop
forgets everything — your data is unaffected.

Set `NEODROP_HOME` to run the app against a different state directory (used by `scripts/e2e.sh`).

## Not built yet

Deliberate omissions, roughly in order of value:

* **File history / versioning.** Right now a mirrored deletion is a real deletion. Keeping the last
  N versions per replica would remove the remaining way to lose data.
* **Erasure coding.** Full mirrors cost N× the storage. Sharding files so any K of N replicas can
  rebuild them would make large libraries practical, at the cost of "your data is still just files".
* **Restoring a source from a replica.** Repair can rebuild a replica from the source or another
  replica, but there is no "the source was lost, put it back" button yet.
* **Bandwidth and time windows.** No throttling and no "only sync overnight" yet.
* **Per-file progress UI.** The menu shows counts and the current path, not a list of queued files.
* **Art direction for small sizes.** The icon is one image scaled to every size, as macOS does by
  default. Real icon sets simplify at 16–32px, where a detailed render turns to mush.

## Licence

MIT — see [LICENSE](LICENSE). It covers the code and the artwork, so you are free to fork it, strip
it down to the parts you want, or ship your own version.

What it does not change: the app is ad-hoc signed, not notarized, so a build from this source still
needs the one-time Gatekeeper approval described above unless you sign it with your own Apple
Developer account.
