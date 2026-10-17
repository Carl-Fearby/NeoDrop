<p align="center">
  <b>NeoDrop — a menu bar app that keeps a full copy of your folders on every NAS you own.</b><br>
  <sub>Verified with SHA-256, repaired from whichever copy is still healthy. macOS 14+. Native Swift, no Electron, no cloud.</sub>
</p>

NeoDrop lives in the title bar, with two modes that can run side by side.

**Mirror** — the original job. Point it at one or more local folders and at every mounted NAS share;
it copies the folders in full to each share, verifies the copies against their checksums, and rebuilds
any copy that has rotted, been truncated or disappeared. One writer per share: an excellent backup.

**Two-way folders** — the Dropbox-shaped job. Point two or more Macs at the same vault on a share
and each one keeps the whole tree: change a file on any of them and it appears on the others, delete
one and it is gone everywhere (and recoverable for 30 days), and a Mac joining later pulls the whole
thing down on its first sync. The share is still just a folder of ordinary files you can browse and
open — Dropbox gives you *a* copy you don't control; NeoDrop gives you *the same folder on three
machines in your own house*.

They are different jobs and the app says so out loud rather than conflating them: a mirror is
one-way and single-writer, and pointing two machines at one mirror folder is how a file gets silently
overwritten. If you want edits on both machines, that is a two-way folder.

## Why it exists

A single NAS is a single point of failure, and RAID is not a backup. Copying to two NAS boxes by
hand works right up until the day you forget. NeoDrop is the boring, always-on version of that
habit:

* **Full mirror, not sync-with-a-server.** Every destination holds a complete, browsable copy. If
  this app dies tomorrow, your data is still just files on a share. That holds in two-way mode too:
  the vault is a real folder on the share, and NeoDrop's bookkeeping lives in a hidden `.neodrop/`
  directory inside it.
* **Checksums, not timestamps.** Verification re-reads and re-hashes. A file that is the right
  size and the wrong bytes is *not* healthy — see `testVerifyDetectsSilentCorruption`.
* **Repair from anywhere.** A bad copy is rewritten from the source, or from another replica when
  the source no longer has the file. A wiped NAS is rebuilt from the survivors.
* **A delete is a 30-day undo.** Delete a file in a protected folder and it does not vanish: each
  share keeps the bytes under `.neodrop-trash/`, and the menu's **Deleted Files…** window lists
  what is recoverable and puts it back. **An edit is a 30-day undo too:** the version a copy
  replaces is kept the same way, from the same window.
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

One Swift package: `NeoDropCore` (engine, no AppKit, fully testable), `NeoDropShared` (the badge
format, so the app and the Finder extension cannot disagree about what a badge means), `NeoDrop`
(status item + SwiftUI settings) and the tests. The Finder Sync extension is not an SPM target —
SwiftPM has no app-extension product type — so `scripts/package.sh` compiles it into
`NeoDrop.app/Contents/PlugIns/`.

### Deleted files

When a file disappears from every source folder, NeoDrop does not delete it. On each share the copy
is *renamed* into `.neodrop-trash/` at the same relative path — a rename, so nothing is re-uploaded —
and a record says where it came from, its size and its checksum. The bytes stay for **30 days**.

The same window holds the version a copy **replaced**. A mirror has no version control, so an edit
would otherwise be the end of the previous contents. Instead, before a sync copies over a file it
wrote itself, it moves the copy that is about to be lost into the same trash directory and records it
the same way — one rename inside the share, nothing re-uploaded. One version per file is kept: the
newest one, and the list says which entries were *deleted* and which were *replaced*.

**Deleted Files…** in the menu opens the recovery window: everything currently recoverable, which
destinations still hold a copy, how long each entry has left, and a Restore button. Restoring writes
the version back to its original folder (verified against the record's checksum first), gives the
retained copies back, and re-mirrors it to every share immediately.

Restoring a *deleted* file never overwrites: if a file already sits at the path, the restore refuses
unless it is byte-identical. Restoring a *replaced* version is the opposite instruction — put the
earlier version back — so it does write over the newer file, but only when that newer version is
verifiably on a mounted destination already, where it can be brought back. If it is not (an edit no
sync has published yet, or a share that is unmounted), the restore refuses and says why rather than
destroying the only copy of your newest work. **Verify & Repair** also retains the bytes it repairs
over, including a share-edited copy, so repair does not make those bytes disappear without recovery.

Recovery is how deletions are *meant* to work, not a side channel: files that come back to the source
are dropped from the list, and entries are purged — bytes and record together — only after their
window closes. Turning `mirrorDeletions` off still makes a destination an archive that keeps
everything; such a destination records nothing because it deletes nothing.

### Two-way folders

A two-way folder is one local folder paired with one **vault** on a share. The vault holds the
canonical tree — the live files where you would expect them, browsable in Finder — plus a hidden
`.neodrop/` directory holding the identity and one append-only journal per machine:

```
/Volumes/NAS/Shared/            the vault: ordinary files, one folder, every machine sees the same tree
  Documents/report.txt
  Photos/…
  .neodrop/
    vault.json                  the vault's identity, adopted by every machine that points at it
    journals/<machine-id>.jsonl  one file per machine, append-only: what that machine did, in order
    versions/<sha256>            content that was overwritten or deleted, kept against a mistake
```

One journal per machine is what makes concurrent writers safe without locks: a machine only ever
appends to its own file, and every machine reads all of them. Each machine keeps its own identity
and a **cursor** — the content it and the vault last agreed on — in local state, which is the merge
base for every path:

* only this machine changed it → publish it to the vault;
* only the vault changed it → take the vault's copy;
* both changed it → a **conflict**, and both versions are kept rather than one being picked;
* this machine deleted it → publish the deletion, which no machine then undoes;
* deleted elsewhere and unchanged here → move it into that machine's `.neodrop-trash/`, recoverable
  for 30 days through the same **Deleted Files…** window;
* deleted elsewhere and *restored here* through that window → published as new content, so the file
  is back on every Mac rather than only on this one.

The last pair is why a restore is recorded rather than inferred: a Mac that was asleep through a
deletion and a Mac whose user just pressed Restore look exactly alike — a file sitting at a path the
journal calls deleted. The deletion has to win in the first case (that is what makes deleting on one
Mac stick) and lose in the second, so NeoDrop writes down which one it is.

**Joining a new Mac is one step.** Point it at the same vault with its own local folder: the first
sync reads the journals, pulls every file down, and starts publishing that machine's own changes.
If the folder it is given already holds files, those are published too — and any path that differs
from the vault becomes a conflicted copy rather than a silent overwrite.

**A sync with nothing to do costs next to nothing.** Walking the tree in pages bounds *work*, but a
folder that already agrees with the vault has none, and re-walking it every fifteen minutes was the
expensive part. When this Mac's folder, the vault's tree and the journals all still line up, the sync
settles in a single pass — and it knows they line up *exactly* rather than by guessing, because the
journals are append-only and their byte sizes prove that no other Mac has published since the last
pass. Settling is not looking away: retention still runs (its window closes on the clock), a file
dropped into the vault by hand is still noticed and adopted, and a share file that is missing or the
wrong size is still put back from this Mac's copy. Any of those, or a change published elsewhere or
made here, brings the full walk straight back.

**And it reads only what is new.** A journal is append-only and grows for the life of the vault, so
decoding all of it on every pass would cost the vault's *history* rather than its size — a folder in
use for a year would get slower every sync while nothing changed. Instead this Mac keeps, beside its
cursor, how far into each journal it has read and what that produced; a pass reads the lines written
since, and a sync with nothing to do reads none at all. Both are committed together, so a pass that
fails re-reads what it missed rather than skipping it, and a journal that was rewritten, truncated or
removed is read again from the start rather than trusted.

**Nothing is decided by a clock alone.** Ordering is by timestamp with millisecond precision, and
when two entries share an instant the one written *on top of* the other's content wins — causality
rather than a guess, so machines with skewed clocks still agree. A conflict never loses data: the
loser is kept as `<name> (<machine>'s conflicted copy <date>).<ext>` and published, and the bytes
that were replaced are retained in `.neodrop/versions/` as well.

**The vault is a folder, so files dropped into it count.** Put a file into the vault with Finder and
the next sync adopts it and hands it to every machine — including at a path the journal says was
deleted, because a file that is physically there is content, not a tombstone. Bytes already at a
path that a machine is about to overwrite are retained first, so a hand-placed file is never lost.

### The rules that keep it safe

These are the things that decide whether a tool like this protects data or destroys it, so they are
all enforced in code and covered by tests:

| Rule | Why |
|---|---|
| Only files NeoDrop wrote are ever deleted (tracked in a per-replica manifest) | A replica can share a volume with other data; foreign files are never touched |
| A file NeoDrop did not write is never replaced, only refused and reported | A name collision in a shared folder is no reason to lose somebody's file: the copy on the share may exist nowhere else. A file that is already there with the source's exact bytes is *adopted* instead, which is what makes a clean install cheap |
| A copy on a share that is not the version NeoDrop recorded is left alone by sync | An edit made straight on the share, a partial upload, or a folder where a file belongs exists nowhere else either — it is named in the run's report and the next sync takes the path once it is moved aside. **Verify & Repair** is explicit permission to replace a bad copy, but it retains the bytes first |
| A replica root must already exist — it is never created | An unmounted share would otherwise make `/Volumes/NAS2/NeoDrop` resolve to the boot disk, and you'd "mirror" onto your own SSD |
| Deletions are refused when a source could not be read | A renamed or unplugged source folder must never be interpreted as "everything was deleted" |
| More than 25% of a replica (or 25 files) deleted in one run is refused unless explicitly allowed | Stops the signature mirroring disaster: one bad sync empties the NAS |
| Every copy goes through a temp file plus a rename in the destination folder | A dropped SMB connection leaves the old file, not a truncated new one |
| A deletion, and the version a copy is about to replace, are recorded before the bytes move, and kept for 30 days | "Undo" is the difference between a mirror and a shredder: a mistaken delete *and* an overwritten edit stay recoverable on every share. Records are written first because a record without bytes self-heals while bytes with no record are unreachable forever |
| Restoring a replaced version overwrites the newer file only when it is verifiably on a mounted destination | Putting an earlier version back is the one restore that must write over something, and doing it blind would destroy the only copy of the newer one |
| A restore never overwrites a deleted file, and never deletes ahead of its window | The copy in the trash is often the only copy left of a file the user deleted deliberately, so nothing may be destroyed early or clobbered |
| Paths read out of a record are checked against the directory they belong in | Records are editable JSON; a corrupt one must not be able to point a delete or a restore anywhere else |
| A two-way folder's local side and its vault must be separate folders, and both must already exist | A vault nested in the folder it syncs copies files into themselves; creating either one would sync onto the boot volume when a disk is unplugged |
| Nothing is ever destroyed to resolve a conflict | The losing version is kept beside the original and in `.neodrop/versions/` — the one part of a sync tool users never forgive getting wrong |
| A change is on the share before the journal records it | A crash between the two leaves a change that is simply re-published, never a file nobody knows about |
| A torn last journal line is ignored, a torn middle one is reported, and the next append trims the tear away | A pulled cable during an append is normal; damage in the middle of a file is corruption and must be said out loud. Writing straight after a tear would join the two into one line nobody can read, and the entry would be lost while its bytes sat on the share — so the tear is trimmed and the change is simply published again |
| Deletions arriving from another machine face the same bulk guard as a mirror's | A corrupt or hand-edited journal must not be able to empty a folder in one sync |
| `.neodrop/` and `.neodrop-trash/` are never published or applied | A sync tool that syncs its own bookkeeping feeds on its own output |

A missing source folder, an offline share, or a failed write never stops the other replicas from
being brought up to date; it is reported and shown as degraded instead. The same is true across
modes: a one-way mirror and a two-way folder each run on their own, so a share that cannot be
reached for one does not stop the other.

## Build and run from source

```bash
swift build                 # library + app
swift test                  # 268 engine tests, all green (the badge-container one asserts whichever case this Mac is in)
swift run NeoDrop           # menu bar icon appears immediately (reads/writes ~/Library/Application Support/NeoDrop)
```

`swift run` builds the app and nothing else. The Finder extension is a separate bundle that SwiftPM
has no product type for, so `scripts/package.sh` compiles and embeds it — a source run syncs fine and
simply shows no badges.

## Create an installer DMG

```bash
scripts/setup-dmg-tools.sh              # one-off: installs dmgbuild into .venv (for the layout)
scripts/package.sh                      # host architecture, ad-hoc signed
scripts/package.sh --arch universal     # Intel + Apple Silicon
scripts/verify.sh --smoke               # structural checks plus a real 4-second launch
scripts/e2e.sh                          # drives the packaged app against simulated NAS folders
scripts/e2e-vault.sh                    # two real installs, one vault: edits both ways, a Mac joining, a deletion
scripts/install.sh                      # after building: into /Applications, Finder extension switched on
```

Output: `build/NeoDrop.app` and `build/neodrop-<version>-macos-<arch>.dmg` — for this checkout,
`build/neodrop-1.0.0-macos-arm64.dmg`. Drag-installing the DMG does the first half of what
`install.sh` does; the second half — turning the Finder extension on — is done by hand in System
Settings unless you run the script.

The version in that name is one you chose, not a commit hash: `--version X.Y.Z` if you pass it,
otherwise an exact git tag on `HEAD` (`v1.2.3`), otherwise `packaging/VERSION` — the one file to edit
when you bump it, and the same value Finder shows in Get Info. A build from a tree with uncommitted
changes is named `…-dirty-…`, so two installers with the same name are always the same build. The
commit itself is still recorded, in `CFBundleVersion` and `NeoDropBuildCommit`, where something can
go and read it instead of a file name.

### The drag-and-drop installer window

Opening the DMG shows the wallpaper in `Resources/dmg-background.png` with three evenly spaced
icons across a 960x458 point window: `Read Me First.txt`, the real NeoDrop.app, and a real
`Applications` drop target. Nothing is drawn on the wallpaper — the only thing on it is the
wallpaper itself, cropped to cover.

The layout lives in a binary `.DS_Store` at the root of the image, which Finder reads for icon
positions, the background picture and the window size. Two ways to write it exist:

* AppleScript driving Finder — needs Automation permission and a logged-in GUI session, so it
  cannot run in a build script. Verify this for yourself with `osascript -e 'tell application
  "Finder" to get name of startup disk'`; it hangs on the permission prompt.
* `dmgbuild` — writes the `.DS_Store` directly, works headlessly. This is what `scripts/make-dmg.py`
  uses. It is the only non-Apple build dependency, it is optional, and the app itself has no Python
  dependency. Without `.venv/`, `package.sh` still produces a working (plain) DMG.

Earlier versions used an artwork that had a NeoDrop icon, an Applications folder and an arrow
*painted into it*, and placed the real icons on top of their painted twins. Every element the
background draws is something the icons can disagree with, and each one did: doubled icons, a
caption the labels crossed, a scaled-down art whose icons no longer lined up. That is all gone —
there is no measuring pass left to disagree with anything.

One pass writes both halves of what the window needs, so they cannot drift apart:

```
Resources/dmg-background.png ──crop to cover──▶ build/dmg-background.png + @2x   (the 1x/@2x pair)
                             ──describe──────▶ build/dmg-layout.json            (window + 3 slots)
```

Three details decide whether the window looks right, and all three are easy to get wrong:

**The background is a 1x/@2x pair, and the 1x is exactly the window size.** Finder draws a window
background at its own size instead of scaling it, so handing it the master wallpaper left it showing
only the top-left corner of the picture. The window is therefore 960x458 points with a 960x458
background and a 1920x916 `@2x` partner; dmgbuild finds the pair and combines them into a
multi-resolution TIFF (960x458 at 72 dpi, 1920x916 at 144 dpi) exactly as `tiffutil -cathidpicheck`
does for AppKit.

**The wallpaper is darkened, and that is what makes the labels white.** Finder picks the label
colour from the background: dark text over a bright picture, white with a shadow over a dark one.
On the undarkened wallpaper the labels came out dark grey over mid-blue wave and were hard to read,
so the composition multiplies the picture down to 55% brightness. That keeps the waves and the hue
and puts Finder back on white labels.

**The icon size has to account for the icon body grid.** A drawn app icon only fills about 80% of
the box it is asked for (Apple's canvas is 1024 with an 824 body), so the size asked for is the
190pt paint slot divided by 0.8047, which is 254 points — under the largest icon size Finder is
known to honour (256; the icon-view slider is described as reaching 512, but an unsupported value
is *silently clamped*).

```bash
swift scripts/make-dmg-artwork.swift --source Resources/dmg-background.png \
    --out build/dmg-background.png --layout-out build/dmg-layout.json --json
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
   The window shows a `Read Me First.txt` with exactly this instruction — the leftmost of the three
   icons, beside NeoDrop.app and the `Applications` drop target.

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

The first launch opens **Set Up NeoDrop**, a short wizard that asks the one question everything else
depends on — which folder matters most — and then how it should be protected: **the same folder on
every Mac** (a two-way folder pointed at a vault on a share) or **a copy on a NAS** (a one-way
mirror). It ends by creating exactly that arrangement and syncing once. It introduces itself on a
fresh install and never nags again: **Set Up NeoDrop…** in the menu brings it back whenever you want
it, and everything it does can also be done by hand in Settings.

A fresh install means *no state directory*, not a freshly copied app — see
[Clean install](#clean-install) below.

By hand, the same two kinds of destination:

1. **Settings…** in the menu → **Sources** → *Add Folder…* — pick the folder to protect.
2. **Destinations** → *Add Destination…* — pick the folder on the mounted NAS. Create a `NeoDrop`
   folder inside the share first if you like; each destination holds a complete copy.
3. Repeat for every NAS. **Two destinations on separate NAS boxes is the point** — NeoDrop warns you
   when two replicas land on the same volume, because they would fail together.
4. Save an optional `smb://nas.local/share` address per destination; the menu then offers
   *Mount …*, which asks Finder to connect (using your Keychain) and syncs once it appears.

The menu shows each replica's status, file count, last sync and last verify, plus **Sync Now**,
**Verify & Repair All**, **Deleted Files…**, a per-replica verify, and an activity log.

### Setting up two-way folders

1. **Two-Way** → *Add Two-Way Folder…* — pick the folder on this Mac, then the vault on the mounted
   share. Repeat on the other Macs, pointing them at the *same* vault folder and their own local
   folder. Each Mac syncs immediately; the one that arrives first creates the vault.
2. Give each Mac a name in the same tab. That name is what appears on a conflicted copy, so it is
   worth making it recognisable — the first machine to write a copy keeps it.
3. Macs pick up each other's changes within seconds (the share is watched), and at the scheduled
   sync interval as a backstop. A share's filesystem events are best effort, so the schedule matters.
4. To stop syncing, turn the folder off or remove it — nothing is deleted on either side.

A two-way setup needs no source and no replica: it is a complete configuration on its own, and the
app will not claim otherwise.

### Is this file safe? — the Finder helper

Select a file or folder in Finder → right-click → **Services** → **Show NeoDrop Status** (give it a
keyboard shortcut in System Settings → Keyboard → Keyboard Shortcuts → Services). The window that
opens answers in plain sentences: the verdict, every place the file exists — this Mac, each
destination, the shared copy in a vault, anything the trash is holding — what NeoDrop recorded for
each copy, and, for a two-way folder, the history of that path including which Mac published the
newest version. **File Status…** in the menu does the same for a file you choose, and both open the
same one-document page served over loopback.

What it does *not* do is read the file: the report stats each copy and compares it with what NeoDrop
recorded, so it answers instantly for a video of any size. "Size and date match the record" is
therefore the strongest claim it makes; **Verify & Repair** is what re-hashes the bytes, and the page
says so rather than implying more.

### At a glance: the badges in Finder

Dropbox-shaped: in Finder, a folder or file NeoDrop protects carries a small icon next to its date,
so the state is visible without opening anything.

| Icon | Meaning | When you actually see it |
| --- | --- | --- |
| Green tick | Here, and copied to every destination NeoDrop recorded | The default, everywhere inside a protected folder |
| Clock | Here, but not everywhere yet — new or edited since the last sync, or a destination was away when it ran (**Sync Now** is the fix) | Every file you edit, until the next sync |
| Spinning arrows | NeoDrop is reading or writing this file right now | Only while a sync is running and the app has republished the index mid-run |
| Orange triangle | A destination copy is missing or no longer matches the record — run **Verify & Repair** | A copy that was deleted or replaced by hand |
| Trash | Bytes NeoDrop is deliberately holding — a deletion, or a version a copy replaced — recoverable from **Deleted Files…** | On a destination's `.neodrop-trash/` folder, not per retained file |
| Question mark | On a destination but not written by NeoDrop: somebody put it there by hand, and NeoDrop will not delete or overwrite it | The only badge outside a protected folder — a sync found a file that is not NeoDrop's where the mirror wanted one, and left it alone |
| Dash | Nothing to do with NeoDrop, inside a protected folder but matching an ignore pattern | **Not yet** — the shape is defined, but nothing publishes it |

A file outside every protected folder gets no icon at all — a badge on everything would say nothing.
A folder shows the worst of what is inside it, so one file needing attention is visible from the
folder above. Right-click a file → **Show NeoDrop Status** for the full report (above).

**The badges need one team signature and a normal launch.** The state reaches the extension through a
file the app writes into the extension's sandbox container, and since macOS 14 a container is closed
to processes outside the *team* that owns it. An ad-hoc signature — the default build here, and all
`swift run` gives you — has no team at all, so the app is refused, logs
`Finder badges could not be updated … You don't have permission to save the file …`, and badges
nothing. Sign both bundles with one identity and it publishes:

```bash
MACOS_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" scripts/package.sh && scripts/install.sh
```

`security find-identity -v -p codesigning` prints that string for you — an identity's common name,
with its team in brackets — so it does not have to be typed from memory:

```bash
MACOS_SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F'\"' '/Apple Development/ {print $2; exit}')" \
  scripts/package.sh && scripts/install.sh
```

`scripts/verify.sh` reports the two halves separately: a note for an ad-hoc build, and a **failure**
for an app and an extension signed by *different* teams, because that combination builds, launches,
syncs and can never badge anything. There is one more condition, and it is macOS's rather than the
app's: it has to be started by LaunchServices (Finder, `open`, a login item), not launched from a
shell — the container decision follows the responsible process, so a shell-started run is refused
however the build is signed. AGENTS.md has the measurements, including the log lines.

This is a Finder extension, so it has to be switched on once: `scripts/install.sh` does it for you,
or **System Settings → General → Login Items & Extensions → Finder Extensions → NeoDrop**. The
badges come from NeoDrop's own records — nothing is hashed and no folder is walked to draw them — and
where they are drawn they are honest about *when* they last knew something. With no folders
configured there is nothing to badge, and nothing is drawn: a green tick on no evidence is the one
lie a badge must not tell.

### Trying it without a NAS

```bash
scripts/fake-nas.sh create 3     # mounts three real volumes: /Volumes/NeoDropNAS1..3
scripts/fake-nas.sh destroy      # unmount and delete them
```

They are genuine mounted APFS volumes, so the app treats them exactly like NAS shares — including
the warning when two replicas share a volume.

## Layout

```
Sources/NeoDropCore/     engine: scanning, hashing, mirroring, verification, repair, two-way sync
  MirrorEngine.swift     one-way sync / verify / repair, the deletion guard, retention + restore
  Vault.swift            vault + machine identity, the append-only journal, path normalisation,
                         retained versions, the local cursor
  VaultSync.swift        the two-way reconciler: publish, apply, seed, adopt, conflicts
  ActivityFeed.swift     what the Activity window shows: tabs, search, titles, the footer
  FileStatus.swift       "is this file safe?": every copy, what was recorded for it, its history
  FinderStatusBuilder.swift  the badge index the Finder extension reads, from records NeoDrop
                         already has — no hashing and no directory walk
  WebUIServer.swift      loopback HTTP server behind the deleted-files and file-status windows
  WebUIPage.swift        both pages: self-contained documents, rendered or fetched over loopback
  Scanner.swift          enumeration, excludes, cached source hashes
  Hashing.swift          streaming SHA-256, durable atomic writes
  Storage.swift          config, manifests, source index, runtime state (JSON)
  Volumes.swift          volume identity, SMB mount requests, boot-volume detection
  ConfigValidator.swift  "this configuration does not actually protect anything" checks
  FolderWatcher.swift    FSEvents with debounce
Sources/NeoDrop/         menu bar app: status item, menu, SwiftUI settings, the two web views
  SyncActivityView.swift  the Activity window, laid out over ActivityFeed
  SetupWizard.swift      the first-run wizard: the main folder, then the mode, then the destination
  VaultsTab.swift        the Two-Way settings tab
  VaultStatus.swift      per-folder display state for the menu and Settings
Sources/NeoDropShared/   the badge format, shared by the app and the Finder extension
Sources/NeoDropFinder/   the Finder Sync extension: the badges next to a file's date
Tests/NeoDropCoreTests/  268 tests: one per safety rule above, plus the vault (the paged catch-up and
                         its cursor, the one-pass settle when there is nothing to do, and the
                         incremental journal read — torn tails, shrunk files, lost journals), the
                         Activity window's filtering and wording, web-UI parsing, path and badge
                         cases — the container one asserts both sides of the signing rule
Resources/AppIcon.png    master app-icon artwork, masked by scripts/make-icon.swift
Resources/MenuBarIcon*.png  menu bar template icon at 1x/2x/3x, plus the .svg master
Resources/dmg-background.png  installer window wallpaper, as supplied (the master)
scripts/                 build, icon generation, packaging, verification, e2e, fake NAS
  make-icon.swift        app icon: masking, all ten sizes, mask + orientation checks
  verify-menubar-icon.swift  menu bar icon: template mask, sizes, centring, ink polarity
  make-dmg-artwork.swift  crops + darkens the wallpaper into the 1x/@2x pair and writes the layout
  dmg-layout.swift, make-dmg-background.swift  the earlier measuring pipeline, now unused
  make-dmg.py            builds the drag-and-drop DMG and verifies the written layout
  e2e-vault.sh           two real installs against one vault: both directions, joining, deletions
  install.sh             copy into /Applications and switch the Finder extension on
  reset.sh               the clean-install path: removes this Mac's state, never your data
  uninstall.sh           the other direction: the app, the Finder extension and the state, all gone
  setup-dmg-tools.sh     installs dmgbuild into .venv (optional, for the layout)
packaging/               Info.plist and entitlements templates for the app and the extension, and
                         VERSION — the version the app and the installer are named after
build/                   generated: NeoDrop.app, .icns, .dmg
```

State lives in `~/Library/Application Support/NeoDrop/`: `config.json`, a manifest per replica, the
source hash index, `runtime-state.json`, a rolling `neodrop.log`, `deletes/` — one file per
replica listing the deletions it is still holding — and, for two-way folders, `machine.json` (this
Mac's identity) plus `vaults/<id>.json` (the cursor per vault) and `vaults/<id>-journal.json` (how
far into the vault's journals this Mac has read). Delete that folder and NeoDrop
forgets everything — your data is unaffected, but the retained copies in `.neodrop-trash/` become
files with no record pointing at them, which is what the delete-first purge order is designed to
avoid.

### Clean install

Copying a new `NeoDrop.app` over the old one is *not* a clean install: the configuration lives in
Application Support, not in the bundle, so the app finds the old folders and carries on. "Clean"
means removing this Mac's state:

```bash
scripts/reset.sh                # dry run: prints exactly what it would remove, and what it will not touch
scripts/reset.sh --yes          # carries it out
scripts/reset.sh --yes --trash  # moves the state to the Trash instead, so it can be undone
```

The app must be quit first (the script checks and refuses). Four paths go:

| Path | What it holds |
| --- | --- |
| `~/Library/Application Support/NeoDrop/` | config, manifests, source index, deletion records, log, machine identity |
| `~/Library/Preferences/ai.storyteller.neodrop.plist` | the little macOS remembers about the app (window state) |
| `~/Library/Saved Application State/ai.storyteller.neodrop.savedState` | window restoration state |
| `~/Library/Containers/ai.storyteller.neodrop.finder/…/NeoDrop/finder-status.json` | the badge index the Finder extension reads — removed so Finder cannot keep badging folders NeoDrop has just forgotten. On macOS 26 it stays: a container refuses writes from processes outside the team that owns it, and the script reports it as kept rather than as a failure it cannot fix |

And two things stay, deliberately: **your folders** — every source, destination and two-way folder
in `config.json` is listed and left alone — and the **vault's `.neodrop/` on the share**, because its
journals and retained versions belong to every Mac, not to this one. The copy in `/Applications` is
removed only with `--app`. Pass `--keep-machine-name` to keep the identity so the others still know
this Mac by name. With `NEODROP_HOME` set, only that installation is touched.

Afterwards the app starts as a fresh install and the setup wizard offers itself again. Note what it
costs: each destination then holds files with no local record of them, so the next sync walks the
share and re-hashes what it finds — files that match the source are *adopted* into the new manifest
rather than uploaded again, so the cost is a read of the share, not a write to it. What is genuinely
lost is history: a deletion performed *before* the reset can no longer be restored, because the
record that pointed at the retained copy is gone with the state directory.

Every piece of per-machine state is local; the only thing shared is the vault itself. That is
deliberate: two machines must never write the same file, and a machine that copied another's
identity would do exactly that.

Set `NEODROP_HOME` to run the app against a different state directory (used by `scripts/e2e.sh`);
pointing two of them at one vault is how `scripts/e2e-vault.sh` runs two machines on one Mac.

### Uninstall

```bash
scripts/uninstall.sh                      # dry run: the app, the Finder extension and the state, plus what stays
scripts/uninstall.sh --yes                # carries it out
scripts/uninstall.sh --yes --trash        # the state goes to the Trash instead of being deleted
scripts/uninstall.sh --yes --keep-state   # remove the app and the extension, keep this Mac's state
scripts/uninstall.sh --yes --keep-app     # keep the app, remove the extension and the state
scripts/uninstall.sh --yes --app /path/to/AnotherCopy.app   # a copy somewhere else (repeatable)
```

Deleting the app is not uninstalling it. The state lives in Application Support, and a Finder Sync
extension outlives the app it came from: PlugInKit keeps the registration and goes on loading it into
Finder after the bundle is in the Trash. The script removes, in this order:

1. **Every installed copy of the app**, found by bundle identifier rather than by file name, with the
   copies PlugInKit is actually loading the extension from printed on the way past. A second copy
   left in place keeps the extension alive — which is why removing one `NeoDrop.app` can look like it
   changed nothing at all.
2. **The extension's registration**, taken away while the bundle is still on disk (that is what
   `pluginkit -r` needs), plus the `~/Library/Application Scripts/ai.storyteller.neodrop.finder/`
   directory macOS created for it.
3. **This Mac's state**, by calling `scripts/reset.sh`, so there is one definition of what that is.

Two things stay, and the script prints both. **Your folders** and the vault's `.neodrop/` on the
share, exactly as a reset leaves them. And the extension's **sandbox container**,
`~/Library/Containers/ai.storyteller.neodrop.finder/`, with the badge index inside it: on macOS 26
that container belongs to the system's container manager and nothing else can remove it — creating,
deleting and even listing inside it all come back `Operation not permitted`, for the app as much as for
a script, for Finder with its own privileges, and for `sudo`. So the index outlives the app; it is
inert once no extension is registered, because nothing reads it, and macOS discards containers of apps
it knows are gone on its own schedule. If “Launch at Login” was ever switched on, the login item is registered through
SMAppService and only the app can take it back: the script says so instead of quietly leaving it, and
turning it off in the app's menu (or System Settings → General → Login Items) is what removes it.

## What's left

Split by who it affects: gaps a user can hit in this release, and work deliberately left for later.

### Gaps you can hit today

* **Badges need a team signature.** With both bundles signed by one team the index reaches the
  extension, which is the shipping answer. An ad-hoc build — including `swift run` — cannot write
  into the extension's container, so it shows no badges; the unbuilt fix is an XPC Mach service from
  the app or a loopback server the extension polls. AGENTS.md records why a file channel cannot be
  replaced by an App Group. The container itself is a second case: nothing removes it — not a
  script, not the app, not root, not Finder — so the uninstaller leaves it behind and says so.
* **One previous version per path, not a history.** A deletion *and* the version a copy replaces stay
  recoverable for 30 days everywhere, and a two-way folder keeps the previous contents of anything it
  overwrites in `.neodrop/versions/`. What neither keeps is a chain: a later edit replaces the
  earlier retained version rather than adding to it.
* **Keeping the share's copy is still a Finder operation.** Taking the share's copy *as* the source
  is built — the **Deleted Files & Versions** window lists unresolved conflicts per replica, shows
  the share-file digest and matching source path, and offers **Replace with source…** — but the
  reverse would import destination data into a protected source, so NeoDrop leaves it to you.
* **A same-size corruption on the share needs Verify & Repair.** Every sync checks the share's bytes
  by size, and a deleted or truncated file is put back from retained content; a change that keeps the
  size is only found by re-hashing. An index of what the share holds would make that cheap enough to
  do more often.
* **No “the source was lost, put it back”.** Repair can rebuild a replica from the source or from
  another replica, but there is no button that restores a lost source folder from a share.

### Deliberately out of scope for v1

* **A fully idle two-way pass.** Catching up, reconciliation and the journal read are all bounded: a
  folder that agrees with the vault settles in one pass (5,000 paths: ten passes and sixteen seconds
  became one pass of about one and a half seconds), and a pass reads only the journal lines appended
  since the last. What is still a full walk each pass is the scan of the local tree itself.
* **Erasure coding.** Full mirrors cost N× the storage. Sharding files so any K of N replicas can
  rebuild them would make large libraries practical, at the cost of "your data is still just files".
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
