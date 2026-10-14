#!/usr/bin/env bash
#
# Create, mount and remove throwaway NAS drives.
#
#   scripts/fake-nas.sh create 3      mount /Volumes/NeoDropNAS1 .. NeoDropNAS3, each with a
#                                     NeoDrop folder ready to be used as a replica
#   scripts/fake-nas.sh destroy       unmount and delete them
#   scripts/fake-nas.sh list          show which ones are currently mounted
#
# These are real APFS volumes, not folders, which matters: NeoDrop reasons about volume identity
# (to warn when two replicas would fail together) and refuses to treat the boot volume as a NAS.
# Sparse images keep them cheap — a 256 MB volume costs a few MB of real disk.
#
# Exit status: 0 on success, 1 when something could not be done, 2 on bad usage.

set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
IMAGE_DIR="$ROOT/build/fake-nas"
PREFIX="NeoDropNAS"
SIZE_MB=256

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

image_path() { printf '%s/%s%s.asif' "$IMAGE_DIR" "$PREFIX" "$1"; }
mount_point() { printf '/Volumes/%s%s' "$PREFIX" "$1"; }

cmd_create() {
  local count="${1:-2}"
  case "$count" in ''|*[!0-9]*) printf 'fake-nas.sh: create needs a count\n' >&2; exit 2 ;; esac
  mkdir -p "$IMAGE_DIR"

  local index=1
  while [ "$index" -le "$count" ]; do
    local image mount
    image="$(image_path "$index")"
    mount="$(mount_point "$index")"

    if [ -d "$mount" ]; then
      printf '  %s already mounted\n' "$mount"
    else
      if [ ! -f "$image" ]; then
        printf '  creating %s (%s MB, sparse)\n' "$image" "$SIZE_MB"
        diskutil image create blank --size "${SIZE_MB}m" \
          --volumeName "${PREFIX}${index}" --fs APFS --format ASIF "$image" >/dev/null || return 1
      fi
      printf '  mounting %s\n' "$mount"
      diskutil image attach "$image" >/dev/null || return 1
      # Attach can be asynchronous about the mount point appearing.
      local waited=0
      while [ ! -d "$mount" ] && [ "$waited" -lt 20 ]; do sleep 0.5; waited=$((waited + 1)); done
    fi

    mkdir -p "$mount/NeoDrop"
    printf '  ready: %s/NeoDrop\n' "$mount"
    index=$((index + 1))
  done
  return 0
}

cmd_destroy() {
  # Detach by mount point: deleting the image out from under an attached device leaves a
  # dangling /dev/disk entry behind.
  local index=1
  while [ "$index" -le 8 ]; do
    local mount
    mount="$(mount_point "$index")"
    if [ -d "$mount" ]; then
      printf '  detaching %s\n' "$mount"
      hdiutil detach "$mount" >/dev/null 2>&1 || diskutil eject "$mount" >/dev/null 2>&1
    fi
    index=$((index + 1))
  done

  shopt -s nullglob
  local images=("$IMAGE_DIR"/*.asif)
  shopt -u nullglob
  for image in ${images[@]+"${images[@]}"}; do
    printf '  deleting %s\n' "$image"
    rm -f "$image"
  done
  rmdir "$IMAGE_DIR" 2>/dev/null
  return 0
}

cmd_list() {
  shopt -s nullglob
  local images=("$IMAGE_DIR"/*.asif)
  shopt -u nullglob
  if [ "${#images[@]}" -eq 0 ]; then
    printf '  no fake NAS images yet\n'
    return 0
  fi
  for image in "${images[@]}"; do
    local name
    name="$(basename "$image" .asif)"
    if [ -d "/Volumes/$name" ]; then
      printf '  mounted   /Volumes/%s\n' "$name"
    else
      printf '  detached  %s\n' "$image"
    fi
  done
  return 0
}

case "${1:-}" in
  create) shift; cmd_create "${1:-2}" ;;
  destroy) cmd_destroy ;;
  list) cmd_list ;;
  -h|--help|"") usage; exit 0 ;;
  *) printf 'fake-nas.sh: unknown command: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac

exit $?
