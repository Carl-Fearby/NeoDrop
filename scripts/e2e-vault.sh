#!/usr/bin/env bash
#
# End-to-end test of two-way sync, driven through the real app.
#
# Two separate installs — two state directories, two local folders, two machine identities — are
# pointed at one vault on a "share". That is the arrangement the product is for: two Macs, one NAS,
# the same files on both. This script runs the actual NeoDrop binary for each machine, so what it
# proves is the thing a user has: launch the app → the folder comes together → an edit on either
# machine shows up on the other → a Mac joining later pulls the whole tree down.
#
# By default it uses the SwiftPM binary. Pass --binary to run a packaged .app's executable instead —
# mounted from a DMG, say — which is how the artefact that actually ships gets the same coverage.
# Either way each "machine" is a directly executed binary: LaunchServices will not start a second copy
# of the same bundle, and two machines is the entire point. scripts/e2e.sh covers the packaged app's
# icon and its one-way mirror.
#
# Usage: scripts/e2e-vault.sh [--keep] [--timeout seconds] [--binary path/to/NeoDrop]
#
#   --binary  run that executable instead of building one — point it at NeoDrop.app's binary
#             (mounted from a DMG, say) to exercise the artefact that actually ships, rather than
#             the SwiftPM build.
#
# Exit status: 0 when every assertion passed, 1 otherwise, 2 on bad usage.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
KEEP=0
STEP_TIMEOUT=45
BINARY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1; shift ;;
    --timeout) STEP_TIMEOUT="${2:-45}"; shift 2 ;;
    --binary) BINARY="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'e2e-vault.sh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

FAILURES=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
note() { printf '  --   %s\n' "$1"; }
step() { printf '\n%s\n' "$1"; }

if [ -n "$BINARY" ]; then
  EXEC="$BINARY"
  printf 'Using the supplied binary (no build): %s\n' "$EXEC"
else
  printf 'Building…\n'
  if ! swift build --package-path "$ROOT" >/dev/null; then
    printf 'e2e-vault.sh: swift build failed\n' >&2
    exit 2
  fi
  EXEC="$(swift build --package-path "$ROOT" --show-bin-path)/NeoDrop"
fi
[ -x "$EXEC" ] || { printf 'e2e-vault.sh: no binary at %s\n' "$EXEC" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/neodrop-vault-e2e.XXXXXX")"
VAULT="$WORK/NAS/Vault"
shopt -s nullglob
PIDS=()

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
    fi
  done
  if [ "$KEEP" -eq 0 ]; then rm -rf "$WORK"; else printf 'kept: %s\n' "$WORK"; fi
}
trap cleanup EXIT

mkdir -p "$VAULT" "$WORK/A/Folder/Documents" "$WORK/B/Folder" "$WORK/a-state" "$WORK/b-state"

printf 'quarterly numbers\n' > "$WORK/A/Folder/Documents/report.txt"
printf 'notes from machine A\n' > "$WORK/A/Folder/Documents/notes.txt"
printf 'holiday snapshots\n'   > "$WORK/A/Folder/Documents/README — notes.txt"
dd if=/dev/urandom of="$WORK/A/Folder/Documents/binary.dat" bs=1024 count=256 2>/dev/null

# One machine: its own state directory, its own local folder, the shared vault.
write_config() { # state-dir, local-folder, link-name
  cat > "$1/config.json" <<JSON
{
  "version": 1,
  "sources": [],
  "replicas": [],
  "vaults": [
    {
      "id": "$(uuidgen | tr 'A-Z' 'a-z')",
      "name": "$3",
      "vaultPath": "$VAULT",
      "localPath": "$2",
      "enabled": true
    }
  ],
  "watchForChanges": true,
  "scheduledSync": true,
  "syncIntervalMinutes": 1,
  "scheduledVerify": false,
  "verifyIntervalHours": 24,
  "verifyAfterCopy": true,
  "mirrorDeletions": true,
  "allowBulkDeletions": false,
  "excludes": [".DS_Store", "._*", ".Trash", "*.tmp", "*.part", ".neodrop-*"]
}
JSON
}

start_machine() { # state-dir, label, log
  NEODROP_HOME="$1" "$EXEC" > "$3" 2>&1 &
  PIDS+=("$!")
  note "$2 started (pid $!)"
}

# Wait until a condition holds, or until the deadline. The condition is a shell command.
wait_for() { # description, command...
  local description="$1"; shift
  local deadline=$((SECONDS + STEP_TIMEOUT))
  while [ $SECONDS -lt $deadline ]; do
    if "$@" >/dev/null 2>&1; then
      pass "$description"
      return 0
    fi
    sleep 1
  done
  fail "$description (waited ${STEP_TIMEOUT}s)"
  return 1
}

digest() { shasum -a 256 "$1" | cut -d' ' -f1; }

# Every file below a folder as "hash  relative/path", sorted by path.
#
# NeoDrop's own bookkeeping is left out on both sides: `.neodrop/` on the share and
# `.neodrop-trash/` in a working copy hold journals, retained versions and recoverable deletions,
# not the shared tree. Counting them would compare metadata that is *supposed* to differ.
hashes_of() {
  ( cd "$1" && find . -type f -not -path './.neodrop-trash/*' -not -path './.neodrop/*' | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s  %s\n' "$(digest "$path")" "$path"
    done )
}

step "Machine A, first sync: the vault is created from A's folder"
write_config "$WORK/a-state" "$WORK/A/Folder" "Shared"
start_machine "$WORK/a-state" "Machine A" "$WORK/a.log"
wait_for "A published its folder to the vault" test -f "$VAULT/Documents/report.txt"
wait_for "nested and non-ASCII paths survive" test -f "$VAULT/Documents/README — notes.txt"

if [ "$(hashes_of "$WORK/A/Folder")" = "$(hashes_of "$VAULT")" ]; then
  pass "the vault is a byte-for-byte copy of A's folder"
else
  fail "the vault does not match A's folder"
  diff <(hashes_of "$WORK/A/Folder") <(hashes_of "$VAULT") | sed 's/^/       /' | head -10
fi

if [ -d "$VAULT/.neodrop/journals" ] && [ -n "$(ls -A "$VAULT/.neodrop/journals" 2>/dev/null)" ]; then
  pass "the vault carries its own journal, so other machines can read the tree"
else
  fail "no journal was written into the vault"
fi

step "Machine B joins: a new Mac gets the content across"
write_config "$WORK/b-state" "$WORK/B/Folder" "Shared"
start_machine "$WORK/b-state" "Machine B" "$WORK/b.log"
wait_for "B pulled the tree from the vault" test -f "$WORK/B/Folder/Documents/report.txt"

if [ "$(hashes_of "$WORK/B/Folder")" = "$(hashes_of "$WORK/A/Folder")" ]; then
  pass "B's folder is byte-identical to A's"
else
  fail "B's folder differs from A's"
  diff <(hashes_of "$WORK/A/Folder") <(hashes_of "$WORK/B/Folder") | sed 's/^/       /' | head -10
fi

if grep -q "first sync on this Mac" "$WORK/b-state/neodrop.log" 2>/dev/null; then
  pass "B's first sync is reported as a first sync"
  note "$(grep 'first sync on this Mac' "$WORK/b-state/neodrop.log" | tail -1)"
else
  fail "B never reported a first sync"
fi

if [ "$(digest "$WORK/B/Folder/Documents/binary.dat")" = "$(digest "$WORK/A/Folder/Documents/binary.dat")" ]; then
  pass "the binary file came across intact"
else
  fail "the binary file did not match"
fi

step "An edit on B reaches the vault and A"
NOW_B="edited on machine B"
printf '%s\n' "$NOW_B" > "$WORK/B/Folder/Documents/notes.txt"
wait_for "B's edit reached the vault" grep -q "$NOW_B" "$VAULT/Documents/notes.txt"
wait_for "B's edit reached A" grep -q "$NOW_B" "$WORK/A/Folder/Documents/notes.txt"

step "An edit on A reaches B (the other direction)"
NOW_A="edited on machine A"
printf '%s\n' "$NOW_A" > "$WORK/A/Folder/Documents/report.txt"
wait_for "A's edit reached the vault" grep -q "$NOW_A" "$VAULT/Documents/report.txt"
wait_for "A's edit reached B" grep -q "$NOW_A" "$WORK/B/Folder/Documents/report.txt"

step "A new file on B appears everywhere"
printf 'made on B\n' > "$WORK/B/Folder/Documents/from-b.txt"
wait_for "the new file reached the vault" test -f "$VAULT/Documents/from-b.txt"
wait_for "the new file reached A" test -f "$WORK/A/Folder/Documents/from-b.txt"

step "A file dropped onto the share by hand is taken into the sync"
mkdir -p "$VAULT/From Finder"
printf 'typed straight onto the NAS\n' > "$VAULT/From Finder/hand-typed.txt"
wait_for "A took the hand-placed file" test -f "$WORK/A/Folder/From Finder/hand-typed.txt"
wait_for "B took the hand-placed file" test -f "$WORK/B/Folder/From Finder/hand-typed.txt"

step "A deletion on B propagates and stays recoverable on A"
DELETED_DIGEST="$(digest "$WORK/B/Folder/Documents/from-b.txt")"
rm -f "$WORK/B/Folder/Documents/from-b.txt"
wait_for "the deletion reached the vault" test ! -f "$VAULT/Documents/from-b.txt"
wait_for "the deletion reached A's folder" test ! -f "$WORK/A/Folder/Documents/from-b.txt"

TRASHED="$WORK/A/Folder/.neodrop-trash/Documents/from-b.txt"
if [ -f "$TRASHED" ] && [ "$(digest "$TRASHED")" = "$DELETED_DIGEST" ]; then
  pass "A kept the deleted bytes in its trash, digest for digest"
else
  fail "A did not retain the deleted file's bytes"
fi

step "Both machines agree at the end"
if [ "$(hashes_of "$WORK/A/Folder")" = "$(hashes_of "$WORK/B/Folder")" ]; then
  pass "A's and B's folders are byte-identical"
else
  fail "the two machines did not converge"
  diff <(hashes_of "$WORK/A/Folder") <(hashes_of "$WORK/B/Folder") | sed 's/^/       /' | head -10
fi

if [ "$(hashes_of "$WORK/A/Folder")" = "$(hashes_of "$VAULT")" ]; then
  pass "the vault matches both machines"
else
  fail "the vault does not match the machines"
  diff <(hashes_of "$WORK/A/Folder") <(hashes_of "$VAULT") | sed 's/^/       /' | head -10
fi

for state in a b; do
  if grep -q "Started on\|NeoDrop started" "$WORK/$state-state/neodrop.log" 2>/dev/null; then
    note "$(grep -m1 'NeoDrop started' "$WORK/$state-state/neodrop.log")"
  fi
done

# A machine identity per install is what keeps the journals apart; two installs sharing one would
# mean two writers on one file, which is the failure the whole design avoids.
A_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$WORK/a-state/machine.json" 2>/dev/null)"
B_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$WORK/b-state/machine.json" 2>/dev/null)"
if [ -n "$A_ID" ] && [ -n "$B_ID" ] && [ "$A_ID" != "$B_ID" ]; then
  pass "each machine has its own identity, so each owns its own journal file"
else
  fail "the two installs do not have distinct machine identities ($A_ID / $B_ID)"
fi

JOURNALS="$(ls "$VAULT/.neodrop/journals" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$JOURNALS" -ge 2 ]; then
  pass "the vault holds one journal per machine ($JOURNALS files)"
else
  fail "expected a journal file per machine, found $JOURNALS"
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  echo "Two-way end-to-end test passed."
  exit 0
fi
echo "$FAILURES two-way end-to-end check(s) failed."
[ "$KEEP" -eq 0 ] && note "re-run with --keep to inspect $WORK"
exit 1
