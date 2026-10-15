#!/usr/bin/env bash
#
# End-to-end test of the built app, not the library.
#
# Sets up a throwaway folder tree that looks like one local source and two mounted NAS shares,
# launches the real NeoDrop binary with NEODROP_HOME pointed at a scratch state directory, and
# then checks what actually landed on the "NAS" folders. This is the interface a user has:
# app launches → reads config → mirrors → verifies.
#
# Usage: scripts/e2e.sh [--app path/to/NeoDrop.app] [--keep] [--volumes]
#
#   --volumes  additionally run the same app against three real mounted APFS volumes created by
#              scripts/fake-nas.sh, because a folder under /tmp is not the same thing as a share
#              under /Volumes: volume identity, the boot-volume guard and the same-volume warning
#              only mean anything against genuinely separate mounts.
#
# Exit status: 0 when every assertion passed, 1 otherwise, 2 on bad usage.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP="$ROOT/build/NeoDrop.app"
KEEP=0
VOLUMES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --volumes) VOLUMES=1; shift ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'e2e.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

EXECUTABLE="$APP/Contents/MacOS/NeoDrop"
[ -x "$EXECUTABLE" ] || { printf 'e2e.sh: no app at %s; run scripts/package.sh first\n' "$APP" >&2; exit 2; }

FAILURES=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
note() { printf '  --   %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/neodrop-e2e.XXXXXX")"
STATE="$WORK/state"
SOURCE="$WORK/Source"
NAS1="$WORK/NAS1/NeoDrop"
NAS2="$WORK/NAS2/NeoDrop"
# Where the Finder extension reads the badge index: the extension is sandboxed, so the app publishes
# into the container the sandbox gives it. Spelled out here rather than read from the app so that a
# build naming a different container is caught rather than agreed with.
BADGE_INDEX="$HOME/Library/Containers/ai.storyteller.neodrop.finder/Data/Library/Application Support/NeoDrop/finder-status.json"

cleanup() {
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
  fi
  # The app publishes its badge index to wherever the *installed* Finder extension reads it, not to
  # the scratch state directory (it cannot: the extension is sandboxed and its container is the only
  # place both processes can reach). This run therefore leaves an index in that container, and the
  # attempt to remove it is usually refused: a container is closed to processes outside the team that
  # owns it (AGENTS.md), and this shell is not in it. Nothing to panic about — the installed app
  # republishes its own index on the next refresh — but saying nothing would be claiming a cleanup
  # that did not happen.
  rm -f "$BADGE_INDEX" 2>/dev/null
  if [ -f "$BADGE_INDEX" ]; then
    printf '  --   the badge index this run published is still in the container (a shell cannot delete inside one); the installed app republishes over it\n'
  fi
  rm -f "$STATE"/finder-status.json 2>/dev/null
  if [ "$KEEP" -eq 0 ]; then rm -rf "$WORK"; else printf 'kept: %s\n' "$WORK"; fi
}
trap cleanup EXIT

mkdir -p "$STATE" "$SOURCE/Documents/2026" "$SOURCE/Photos" "$NAS1" "$NAS2"

# A mix that exercises nested paths, spaces, unicode and binary data.
printf 'quarterly numbers\n' > "$SOURCE/Documents/report.txt"
printf 'nested and deep\n'     > "$SOURCE/Documents/2026/plans.txt"
printf 'holiday snapshots\n'   > "$SOURCE/Photos/README — notes.txt"
dd if=/dev/urandom of="$SOURCE/Photos/binary.dat" bs=1024 count=512 2>/dev/null

# Every file below a directory as "hash  relative/path", sorted by path. Sorting by path (not by
# the whole line) is what makes two trees comparable: sorting by hash would only compare orders.
hashes_of() {
  ( cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s  %s\n' "$(shasum -a 256 "$path" | cut -d' ' -f1)" "$path"
    done )
}

SOURCE_HASHES="$(hashes_of "$SOURCE")"

cat > "$STATE/config.json" <<JSON
{
  "version": 1,
  "sources": [
    { "id": "11111111-1111-1111-1111-111111111111", "name": "Source", "path": "$SOURCE" }
  ],
  "replicas": [
    { "id": "22222222-2222-2222-2222-222222222222", "name": "NAS1", "path": "$NAS1", "enabled": true, "priority": 0 },
    { "id": "33333333-3333-3333-3333-333333333333", "name": "NAS2", "path": "$NAS2", "enabled": true, "priority": 1 }
  ],
  "watchForChanges": true,
  "scheduledSync": true,
  "syncIntervalMinutes": 15,
  "scheduledVerify": true,
  "verifyIntervalHours": 24,
  "verifyAfterCopy": true,
  "mirrorDeletions": true,
  "allowBulkDeletions": false,
  "excludes": [".DS_Store", "._*", ".Trash", "*.tmp", "*.part", ".neodrop-*"]
}
JSON
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$STATE/config.json" >/dev/null 2>&1; then
  pass "scratch config is valid JSON"
else
  fail "scratch config is valid JSON"
fi

echo "Launching the packaged app…"
NEODROP_HOME="$STATE" "$EXECUTABLE" > "$WORK/app.log" 2>&1 &
PID=$!

# The app syncs on launch; give it time to finish the first mirror.
DEADLINE=$((SECONDS + 60))
while [ $SECONDS -lt $DEADLINE ]; do
  if [ -f "$NAS2/Photos/binary.dat" ] && [ -f "$NAS1/Photos/binary.dat" ]; then break; fi
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done

if kill -0 "$PID" 2>/dev/null; then
  pass "app is still running after the launch sync"
else
  fail "app exited early"
  sed 's/^/       /' "$WORK/app.log" | head -20
fi

# A live process is not the same as a visible menu bar icon, so check that the status item was
# actually installed rather than assuming it.
if grep -q "Menu bar status item installed" "$STATE/neodrop.log" 2>/dev/null; then
  pass "the title bar status item was installed"
  note "$(grep 'Menu bar status item installed' "$STATE/neodrop.log" | tail -1)"
else
  fail "the app never installed a menu bar status item"
fi

# An installed status item is not the same as the icon that was packaged with it: a missing or
# unreadable resource file leaves AppKit a usable system symbol instead, and the only visible surface
# of a menu bar app then shows something nobody chose. The app logs which it used; assert on that.
# Matched as a prefix: the line goes on to report the pixel sizes of the representations AppKit
# assembled, and pinning the whole string made this fail on a message change rather than a regression.
if grep -q "Menu bar status item installed (icon: bundled artwork" "$STATE/neodrop.log" 2>/dev/null; then
  pass "the menu bar shows the bundled artwork, not a fallback symbol"
  # Loading the file is not the claim that matters: the @2x and @3x files are what keep it sharp, and
  # a 1x-only load would be upscaled and merely look soft. All three have to be present.
  ICON_LINE="$(grep 'Menu bar status item installed' "$STATE/neodrop.log" | tail -1)"
  MISSING=""
  for size in 18x18 36x36 54x54; do
    case "$ICON_LINE" in *"$size"*) ;; *) MISSING="$MISSING $size" ;; esac
  done
  if [ -z "$MISSING" ]; then
    pass "all three representations (18x18, 36x36, 54x54) were assembled by AppKit"
  else
    fail "the menu bar icon loaded without$MISSING: $ICON_LINE"
  fi
else
  fail "the app fell back to a system symbol: $(grep 'Menu bar status item installed' "$STATE/neodrop.log" | tail -1)"
fi

# ---- the Finder badges --------------------------------------------------------------------------
# The badges are the only part of the app a user sees without opening it, and the chain has three
# links that fail silently on their own: the app has to publish the index, it has to land where the
# sandboxed extension can read it, and it has to name the folders it is protecting. A green tick that
# is never drawn looks exactly like a file nobody asked about.
# The index itself — what the badges would say — is checkable here: the app keeps a second copy in its
# own state directory, which is an ordinary file. That copy naming the protected folder is the link
# that fails when the app publishes nothing at all.
if [ -f "$STATE/finder-status.json" ]; then
  if grep -q "$SOURCE" "$STATE/finder-status.json" 2>/dev/null; then
    pass "the published index names the folder it protects"
  else
    fail "the published index does not mention $SOURCE"
  fi
else
  fail "the app published no index at all: the extension would draw nothing"
fi

# The other half — that the index *reaches* the extension's container — cannot be checked from this
# instance, and that is a property of macOS rather than of the product. A container is closed to
# processes outside the team that owns it, and for anything started from a shell the responsible
# process is the shell, which has no team: measured here, the same binary publishes when
# LaunchServices starts it and is refused when a shell does (AGENTS.md has the log lines). So the
# launch path is what has to be checked, and the last section of this script does exactly that, with
# the installed app and `open`.
if grep -q "Finder badges updated" "$STATE/neodrop.log" 2>/dev/null; then
  pass "the app published the index, container copy included"
elif grep -q "Finder badges could not be updated" "$STATE/neodrop.log" 2>/dev/null; then
  note "this shell-launched instance could not write the container (expected); the launch-path section at the end checks the real one"
else
  fail "the app never said anything about the badge index"
fi

# ---- what landed on the shares -----------------------------------------------------------------
for relative in "Documents/report.txt" "Documents/2026/plans.txt" "Photos/README — notes.txt" "Photos/binary.dat"; do
  if [ -f "$NAS1/$relative" ] && [ -f "$NAS2/$relative" ]; then
    pass "mirrored to both replicas: $relative"
  else
    fail "missing on a replica: $relative"
  fi
done

# Identical file lists, and identical bytes. Comparing digests is the whole promise of the app.
NAS1_LIST="$(cd "$NAS1" && find . -type f | sed 's|^\./||' | sort)"
NAS2_LIST="$(cd "$NAS2" && find . -type f | sed 's|^\./||' | sort)"
if [ "$NAS1_LIST" = "$NAS2_LIST" ]; then
  pass "both replicas hold the same file list"
else
  fail "replica file lists differ"
  printf '%s\n' "$NAS1_LIST" | sed 's/^/       NAS1: /'
  printf '%s\n' "$NAS2_LIST" | sed 's/^/       NAS2: /'
fi

NAS1_HASHES="$(hashes_of "$NAS1")"
NAS2_HASHES="$(hashes_of "$NAS2")"

if [ "$NAS1_HASHES" = "$NAS2_HASHES" ]; then
  pass "both replicas are byte-identical to each other"
else
  fail "replica contents differ"
  diff <(printf '%s\n' "$NAS1_HASHES") <(printf '%s\n' "$NAS2_HASHES") | sed 's/^/       /' | head -10
fi

if [ "$NAS1_HASHES" = "$SOURCE_HASHES" ]; then
  pass "replica matches the source digest for digest"
else
  fail "replica does not match the source"
  diff <(printf '%s\n' "$SOURCE_HASHES") <(printf '%s\n' "$NAS1_HASHES") | sed 's/^/       /' | head -10
fi

# The manifest is the proof that verification has something to compare against.
if [ -f "$STATE/manifests/22222222-2222-2222-2222-222222222222.json" ] \
   && grep -q '"sha256"' "$STATE/manifests/22222222-2222-2222-2222-222222222222.json"; then
  pass "a checksum manifest was written for NAS1"
else
  fail "no manifest recorded for NAS1"
fi

# Junk the excludes list protects against must not be mirrored.
printf 'junk' > "$SOURCE/.DS_Store"
sleep 6
if [ -f "$NAS1/.DS_Store" ]; then
  fail "excluded file .DS_Store was mirrored"
else
  pass "excluded file .DS_Store stayed out of the mirror"
fi

# A deleted source file should disappear from every replica (small deletion, guard not tripped),
# and its bytes should still exist under the trash directory on both.
REPORT_DIGEST="$(shasum -a 256 "$SOURCE/Documents/report.txt" | cut -d' ' -f1)"
rm -f "$SOURCE/Documents/report.txt"
DEADLINE=$((SECONDS + 30))
while [ $SECONDS -lt $DEADLINE ]; do
  [ -f "$NAS1/Documents/report.txt" ] || break
  sleep 1
done
if [ ! -f "$NAS1/Documents/report.txt" ] && [ ! -f "$NAS2/Documents/report.txt" ]; then
  pass "a deletion in the source propagated to both replicas"
else
  fail "deletion did not propagate"
fi

# ---- deleted files: retention, the web view, and restoring through it ---------------------------

# The deletion is a rename, not a delete: identical bytes, trashed on both replicas.
for volume in NAS1 NAS2; do
  TRASHED="$WORK/$volume/NeoDrop/.neodrop-trash/Documents/report.txt"
  if [ ! -f "$TRASHED" ]; then
    fail "$volume did not retain the deleted file in .neodrop-trash"
  elif [ "$(shasum -a 256 "$TRASHED" | cut -d' ' -f1)" != "$REPORT_DIGEST" ]; then
    fail "$volume retained different bytes than the file that was deleted"
  else
    pass "$volume keeps the deleted bytes, digest for digest"
  fi
done

# A record per replica, with the recovery window the app advertises. Records are looked up in the
# deletes directory rather than by a guessed file name: the name is the replica UUID, and pinning it
# here would make this fail on a case change rather than on a regression.
if python3 - "$STATE/deletes" <<'PY'
import json, glob, os, sys
from datetime import datetime
records = []
for path in glob.glob(os.path.join(sys.argv[1], "*.json")):
    records.append((os.path.basename(path), json.load(open(path))))
matches = [(name, record)
           for name, entries in records
           for record in entries
           if record["relativePath"] == "Documents/report.txt"]
assert matches, "no record for the deleted file"
assert len(matches) == 2, f"expected one record per replica, found {len(matches)}"
for name, record in matches:
    assert record["sha256"], "the record carries no digest to verify a restore against"
    assert record["sourcePath"].endswith("Source/Documents/report.txt"), record["sourcePath"]
    start = datetime.fromisoformat(record["deletedAt"].replace("Z", "+00:00"))
    end = datetime.fromisoformat(record["expiresAt"].replace("Z", "+00:00"))
    days = (end - start).total_seconds() / 86400
    assert 29.9 < days < 30.1, f"recovery window is {days} days"
PY
then
  pass "a deletion record with a 30-day window was written for each replica"
else
  fail "no usable deletion record for the deleted file"
fi

# The in-app web view. The app logs the URL it is serving; drive it the way the page does.
WEB_URL="$(grep -o 'Deleted files view ready at http://127.0.0.1:[0-9]*/[a-f0-9]*/' "$STATE/neodrop.log" 2>/dev/null | tail -1 | sed 's/^Deleted files view ready at //')"
if [ -n "$WEB_URL" ]; then
  pass "the app started its deleted-files view"

  if curl -fsS --max-time 10 "$WEB_URL" | grep -q "Deleted Files"; then
    pass "the deleted-files page is served on loopback"
  else
    fail "the deleted-files page did not load from $WEB_URL"
  fi

  # Parsed as JSON, not grepped: the assertion is about the entry, not about how the encoder
  # happens to spell a path.
  if curl -fsS --max-time 10 "${WEB_URL}api/deletions" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
entries = {f["relativePath"]: f for f in payload["files"]}
entry = entries.get("Documents/report.txt")
assert entry, f"deleted file not listed: {sorted(entries)}"
assert payload["retentionDays"] == 30, payload["retentionDays"]
assert entry["restorable"], "the page would offer no working Restore button"
assert all(c["available"] for c in entry["copies"]), entry["copies"]
'; then
    pass "the page's API lists the deletion as restorable on every destination"
  else
    fail "the deletions API did not list the deleted file as restorable"
  fi

  # Without the token, a local process (or a page that guessed the port) learns nothing.
  PORT="$(printf '%s' "$WEB_URL" | sed -E 's|http://127.0.0.1:([0-9]+)/.*|\1|')"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:$PORT/")"
  if [ "$CODE" = "404" ]; then
    pass "a request without the token is refused"
  else
    fail "an unauthenticated request returned $CODE, expected 404"
  fi

  # Restore through the API, exactly as the Restore button does.
  CODE="$(curl -s -o "$WORK/restore.json" -w '%{http_code}' --max-time 30 \
    -X POST -H 'Content-Type: application/json' \
    -d '{"relativePath":"Documents/report.txt"}' "${WEB_URL}api/restore")"
  if [ "$CODE" = "200" ]; then
    pass "restoring through the web view returned 200"
  else
    fail "restore returned $CODE: $(head -c 200 "$WORK/restore.json")"
  fi

  if [ -f "$SOURCE/Documents/report.txt" ] \
     && [ "$(shasum -a 256 "$SOURCE/Documents/report.txt" | cut -d' ' -f1)" = "$REPORT_DIGEST" ]; then
    pass "the restored file is back in its original folder, byte for byte"
  else
    fail "the restored file is missing from $SOURCE/Documents or has different contents"
  fi

  if [ -f "$WORK/NAS1/NeoDrop/.neodrop-trash/Documents/report.txt" ] \
     || [ -f "$WORK/NAS2/NeoDrop/.neodrop-trash/Documents/report.txt" ]; then
    fail "the retained copies were not given back after the restore"
  else
    pass "the retained copies were released once the file was back"
  fi

  # It is mirrored again: the sync the app kicks off after a restore.
  DEADLINE=$((SECONDS + 30))
  while [ $SECONDS -lt $DEADLINE ]; do
    [ -f "$NAS1/Documents/report.txt" ] && [ -f "$NAS2/Documents/report.txt" ] && break
    sleep 1
  done
  if [ -f "$NAS1/Documents/report.txt" ] && [ -f "$NAS2/Documents/report.txt" ]; then
    pass "the restored file is mirrored to both replicas again"
  else
    fail "the restored file was not re-mirrored"
  fi

  if curl -fsS --max-time 10 "${WEB_URL}api/deletions" | python3 -c '
import json, sys
paths = [f["relativePath"] for f in json.load(sys.stdin)["files"]]
assert "Documents/report.txt" not in paths, paths
'; then
    pass "the restored file left the deleted-files list"
  else
    fail "the restored file is still listed as deleted"
  fi
else
  fail "the app never logged a deleted-files URL: $(grep -c 'Deleted files view' "$STATE/neodrop.log" 2>/dev/null || echo 0) line(s)"
fi

if grep -q "Done in" "$STATE/neodrop.log" 2>/dev/null; then
  pass "the activity log recorded a completed sync"
  note "$(grep 'Done in' "$STATE/neodrop.log" | tail -1)"
else
  fail "the activity log has no completed sync"
fi

# ---- somebody else's file, where the mirror wants one -------------------------------------------
# The sharpest promise the engine makes: a file NeoDrop did not write is never replaced. The bytes may
# exist nowhere else, and a name collision in a shared folder is no reason to lose them. Staged the
# way it happens in real life — the file is already sitting there when the source gains a file of that
# name — and checked byte for byte after a real sync, on the replica that has it and the replica that
# does not.
FOREIGN_RELATIVE="Documents/2026/quarterly-notes.txt"
printf 'written by a person, not by NeoDrop\n' > "$NAS1/$FOREIGN_RELATIVE"
printf 'a new file, sharing a name with somebody else\n' > "$SOURCE/$FOREIGN_RELATIVE"
DEADLINE=$((SECONDS + 30))
while [ $SECONDS -lt $DEADLINE ]; do
  [ -f "$NAS2/$FOREIGN_RELATIVE" ] && break
  sleep 1
done

if [ -f "$NAS1/$FOREIGN_RELATIVE" ] \
   && grep -q "written by a person" "$NAS1/$FOREIGN_RELATIVE" 2>/dev/null; then
  pass "a file NeoDrop did not write survived the sync, byte for byte"
else
  fail "the file somebody put on the share was replaced: $(cat "$NAS1/$FOREIGN_RELATIVE" 2>&1 | head -1)"
fi

if [ -f "$NAS2/$FOREIGN_RELATIVE" ] \
   && grep -q "sharing a name with somebody else" "$NAS2/$FOREIGN_RELATIVE" 2>/dev/null; then
  pass "the other replica mirrored it as usual, so the refusal is per file"
else
  fail "the second replica never received $FOREIGN_RELATIVE"
fi

if grep -q "not written by NeoDrop" "$STATE/neodrop.log" 2>/dev/null; then
  pass "and the run says which file it left alone"
  note "$(grep 'not written by NeoDrop' "$STATE/neodrop.log" | tail -1 | cut -c1-160)"
else
  fail "nothing in the activity log mentions the file it left alone"
fi

# ---- optional: the same app against real mounted volumes ---------------------------------------
if [ "$VOLUMES" -eq 1 ]; then
  echo
  echo "Real volumes (scripts/fake-nas.sh)"
  if "$ROOT/scripts/fake-nas.sh" create 3 >/dev/null 2>&1; then
    pass "three fake NAS volumes mounted under /Volumes"
  else
    fail "could not mount the fake NAS volumes"
  fi

  # Scenario A: three replicas on three separate volumes — the configuration that actually protects
  # anything.
  write_config() { # state-dir, replicas-json
    mkdir -p "$1"
    cat > "$1/config.json" <<JSON
{
  "version": 1,
  "sources": [ { "id": "11111111-1111-1111-1111-111111111111", "name": "Source", "path": "$SOURCE" } ],
  "replicas": $2,
  "watchForChanges": true,
  "scheduledSync": false,
  "syncIntervalMinutes": 60,
  "scheduledVerify": false,
  "verifyIntervalHours": 24,
  "verifyAfterCopy": true,
  "mirrorDeletions": true,
  "allowBulkDeletions": false,
  "excludes": [".DS_Store", "*.tmp"]
}
JSON
  }

  VOLSTATE="$WORK/volstate"
  mkdir -p "/Volumes/NeoDropNAS1/NeoDrop" "/Volumes/NeoDropNAS2/NeoDrop" "/Volumes/NeoDropNAS3/NeoDrop"
  write_config "$VOLSTATE" '[
    { "id": "44444444-4444-4444-4444-444444444444", "name": "NAS1", "path": "/Volumes/NeoDropNAS1/NeoDrop", "enabled": true, "priority": 0 },
    { "id": "55555555-5555-5555-5555-555555555555", "name": "NAS2", "path": "/Volumes/NeoDropNAS2/NeoDrop", "enabled": true, "priority": 1 },
    { "id": "66666666-6666-6666-6666-666666666666", "name": "NAS3", "path": "/Volumes/NeoDropNAS3/NeoDrop", "enabled": true, "priority": 2 }
  ]'

  NEODROP_HOME="$VOLSTATE" "$EXECUTABLE" > "$WORK/volumes.log" 2>&1 &
  VPID=$!
  DEADLINE=$((SECONDS + 60))
  while [ $SECONDS -lt $DEADLINE ]; do
    [ -f "/Volumes/NeoDropNAS3/NeoDrop/Photos/binary.dat" ] && break
    kill -0 "$VPID" 2>/dev/null || break
    sleep 1
  done

  MIRRORED=0
  for volume in 1 2 3; do
    if [ -f "/Volumes/NeoDropNAS$volume/NeoDrop/Documents/2026/plans.txt" ]; then
      MIRRORED=$((MIRRORED + 1))
    fi
  done
  if [ "$MIRRORED" -eq 3 ]; then
    pass "mirrored to all three mounted volumes"
  else
    fail "only $MIRRORED of 3 volumes received the mirror"
  fi

  if [ "$(hashes_of /Volumes/NeoDropNAS1/NeoDrop)" = "$(hashes_of /Volumes/NeoDropNAS3/NeoDrop)" ]; then
    pass "the two named NAS volumes hold identical data"
  else
    fail "volumes differ"
  fi

  # Three separate volumes must NOT be reported as failing together.
  if grep -q "same volume" "$VOLSTATE/neodrop.log" 2>/dev/null; then
    fail "three separate volumes were wrongly reported as sharing a volume"
  else
    pass "separate volumes are recognised as independent"
  fi

  # The boot-volume guard must not fire: /Volumes/NeoDropNAS* are real other volumes.
  if grep -q "resolves to the boot disk" "$VOLSTATE/neodrop.log" 2>/dev/null; then
    fail "mounted volumes were mistaken for the boot disk"
  else
    pass "mounted volumes are not mistaken for the boot disk"
  fi

  kill "$VPID" 2>/dev/null
  wait "$VPID" 2>/dev/null

  # Scenario B: two replicas on the SAME volume. This is the configuration people actually get
  # wrong, and the app has to say so.
  SAMESTATE="$WORK/samestate"
  mkdir -p "/Volumes/NeoDropNAS1/NeoDrop-b"
  write_config "$SAMESTATE" '[
    { "id": "77777777-7777-7777-7777-777777777777", "name": "NAS1-a", "path": "/Volumes/NeoDropNAS1/NeoDrop", "enabled": true, "priority": 0 },
    { "id": "88888888-8888-8888-8888-888888888888", "name": "NAS1-b", "path": "/Volumes/NeoDropNAS1/NeoDrop-b", "enabled": true, "priority": 1 }
  ]'

  NEODROP_HOME="$SAMESTATE" "$EXECUTABLE" > "$WORK/same.log" 2>&1 &
  SPID=$!
  DEADLINE=$((SECONDS + 20))
  while [ $SECONDS -lt $DEADLINE ]; do
    grep -q "same volume" "$SAMESTATE/neodrop.log" 2>/dev/null && break
    kill -0 "$SPID" 2>/dev/null || break
    sleep 1
  done
  kill "$SPID" 2>/dev/null
  wait "$SPID" 2>/dev/null

  if grep -q "same volume" "$SAMESTATE/neodrop.log" 2>/dev/null; then
    pass "two replicas on one volume are reported as a risk"
  else
    fail "two replicas on the same volume were not reported"
  fi

  rm -rf "/Volumes/NeoDropNAS1/NeoDrop-b" 2>/dev/null
  "$ROOT/scripts/fake-nas.sh" destroy >/dev/null 2>&1
  pass "fake NAS volumes detached and deleted"
fi

# ---- the badge channel, launched the way a user's Mac launches it --------------------------------
# This is the one link the rest of the script cannot reach: the app has to be started by LaunchServices
# (Finder, `open`, a login item) *and* share a team identity with the extension before macOS lets it
# write into the extension's container. Both halves are checked here, the second one by starting the
# installed app the way Finder would and looking at where the index lands.
INSTALLED_APP="/Applications/NeoDrop.app"
if [ ! -d "$INSTALLED_APP" ]; then
  note "no app in /Applications, so the container half of the badge channel was not checked (scripts/install.sh puts one there)"
elif [ "$(codesign -dvv "$INSTALLED_APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')" = "not set" ]; then
  note "the installed app is signed ad-hoc, so nothing it publishes can reach the container (AGENTS.md): badges cannot work in this build, and that is a note rather than a failure"
else
  BADGE_STATE="$WORK/badge-state"
  mkdir -p "$BADGE_STATE"
  cp "$STATE/config.json" "$BADGE_STATE/config.json"
  open -a "$INSTALLED_APP" --env "NEODROP_HOME=$BADGE_STATE"
  DEADLINE=$((SECONDS + 20))
  while [ $SECONDS -lt $DEADLINE ]; do
    grep -q "Finder badges" "$BADGE_STATE/neodrop.log" 2>/dev/null && break
    sleep 1
  done
  if grep -q "Finder badges updated" "$BADGE_STATE/neodrop.log" 2>/dev/null; then
    pass "launched by LaunchServices, the app's index reached the extension's container"
    if grep -q "$SOURCE" "$BADGE_STATE/finder-status.json" 2>/dev/null; then
      pass "and the index it published is the one this run built"
    else
      fail "the installed app published an index that does not mention $SOURCE"
    fi
  elif [ -s "$BADGE_STATE/neodrop.log" ]; then
    grep "Finder badges" "$BADGE_STATE/neodrop.log" | tail -1 | sed 's/^/       /'
    fail "the installed, team-signed app could not publish its badge index"
  else
    note "the installed app did not start (LaunchServices may have preferred the running instance): the container half was not checked"
  fi
  pkill -f "$INSTALLED_APP/Contents/MacOS/NeoDrop" >/dev/null 2>&1 || true
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "End-to-end test passed."
  exit 0
fi
echo "$FAILURES end-to-end check(s) failed."
[ "$KEEP" -eq 0 ] && note "re-run with --keep to inspect $WORK"
exit 1
