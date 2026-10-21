# Roadmap

v1 is the file-sync core: mirror mode, two-way folders, recovery, verification, the menu bar app
and the installer. What follows is the order the rest gets built in, and what "done" means for each.
The order is by who is hurt by the gap: a missing badge or a silent corruption first, scale and
polish last.

A milestone leaves this file when it ships. Its behaviour belongs in README.md, its mechanics in
AGENTS.md, and a gap that is still a gap stays here with what is actually missing.

## M1 — Badges without a team signature  *(built, awaiting the installed-extension check)*

**The gap.** The extension reads its badge index from its own sandbox container, and macOS 14+ only
lets the *same team* write there. An ad-hoc build — the default, and what `scripts/package.sh`
produces without a Developer ID — therefore published nothing and showed no badges at all.

**What was built.** Loopback HTTP. The app serves the same encoded index on `127.0.0.1`, first free
port of 47_623…47_632, at `/badges.json`; the extension fetches it with
`com.apple.security.network.client`. A Mach service was tried first and cannot work:
`NSXPCListener(machServiceName:)` needs launchd to own the name (measured: error 3, "No such
process", from both a test process and a LaunchServices-launched app). The container file stays the
first choice, so a team-signed build behaves exactly as before and no badge depends on the app being
open.

**Verified**

* The app half, live: a running ad-hoc build serves the index at `http://127.0.0.1:47623/badges.json`
  (200 with a decodable index), and answers 403 to a foreign `Host`, 404 to another path, 405 to a
  write.
* `FinderStatusTests`, over real HTTP: served and decoded, nothing before the first publish, a
  withdrawn index, a future version refused, and a client that gives up when nobody is listening.
* `scripts/verify.sh`: sandbox present, `network.client` present, no App Group, no file access, no
  server entitlement, and both binaries carrying the same channel path.
* `swift test` — 275 tests, 0 failures.

**Still to confirm on a real install**

* That the sandboxed extension may actually connect (its side of the entitlement), and that it says
  so: `log stream --predicate 'process == "NeoDropFinder"'` should print "Badge index answered by the
  loopback channel" when the app is running and no file answers.
* That an ad-hoc build badges a watched folder in Finder with no team identity in either bundle —
  the whole point of the milestone, and the one thing no unit test can show.

## M2 — A version chain in mirror mode

**The gap.** Mirror mode retains the version a copy replaced, for 30 days, but only the newest one:
a second edit replaces the first retained version instead of adding to it.

**Done when**

* A path keeps a bounded chain (per-path limit and the existing 30-day window, whichever ends first).
* Deleted Files & Versions groups a path's versions, shows which is which, and restores any of them.
* Purge removes a whole chain's bytes and records together, and a restore of an older version asks
  before overwriting a newer one.
* Tests cover the cap, the window, purge, and restore from the middle of a chain.

## M3 — Keeping the share's copy from inside the app

**The gap.** Replacing a share's copy with the source is built. The reverse — deciding the share is
right — is still a Finder operation, because it would import destination data into a protected
source, which NeoDrop does not do on its own.

**Done when**

* The conflict list offers **Keep the share's copy** next to **Replace with source…**, behind an
  explicit confirmation that names the destination and what will be overwritten.
* The source's bytes are retained first, the import is recorded as a normal change, and the next
  sync publishes it to the other replicas.
* It refuses directories, an offline share, bytes that changed since the row was listed, and a bulk
  import that would cross the deletion guard's threshold.
* Tests cover each refusal and both directions on one conflict.

## M4 — A share contents index

**The gap.** Every sync checks the share's bytes by size, so a file changed in place to the same
size is only found by **Verify & Repair**, which re-hashes everything.

**Done when**

* An index beside the vault's metadata records what the share holds (size and digest) per path, and
  a pass compares against it without reading file contents.
* A same-size corruption is found and reported by a normal sync, and repaired from retained content
  or another replica.
* The index is rebuilt when missing, stale or from a future version, and never becomes the only
  record of a file.
* Tests inject a same-size flip on a replica and assert the next sync notices it.

## M5 — Restoring a lost source from a replica

**The gap.** Repair can rebuild a replica from the source or another replica. If the source folder
itself is lost, there is no button that puts it back.

**Done when**

* A source can be reconstructed from a replica's manifest plus retained versions, into a folder the
  user chooses — never silently over an existing one.
* Files that only existed locally and were never published are reported as unrecoverable rather than
  quietly missing.
* The reconstruction is journalled and the result is verified by digest before it is called done.

## Deliberately out of scope for v1

Kept here so they stop being re-argued: an incremental local scan for an idle two-way pass, erasure
coding, bandwidth and time windows, a per-file progress list, and icon art that simplifies at
16–32 px. Each is a real idea; none is needed for the product to be trustworthy at v1.
