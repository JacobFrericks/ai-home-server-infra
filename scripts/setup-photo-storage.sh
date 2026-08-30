#!/usr/bin/env bash
# setup-photo-storage.sh — create the host directories the immich-private
# workload's `local` PersistentVolumes bind to. Idempotent. Safe to re-run.
#
#   sudo ./scripts/setup-photo-storage.sh --create
#   sudo ./scripts/setup-photo-storage.sh --status
#
# ---------------------------------------------------------------------------
# WHY THESE DIRECTORIES MUST EXIST FIRST
# ---------------------------------------------------------------------------
# A `local` PersistentVolume does NOT create its path. If the directory is
# missing the PV still binds and the pod hangs in ContainerCreating with a
# mount error -- which reads like a storage-class problem rather than a missing
# mkdir. Creating them up front turns a confusing failure into a non-event.
#
# This is also why the workload uses `local` PVs rather than the default
# local-path StorageClass: local-path's reclaimPolicy is Delete and its
# provisioner rm -rf's the directory when the claim goes. For a photo library
# and its database index, Retain on an explicit path is the only safe shape.
#
# ---------------------------------------------------------------------------
# OWNERSHIP
# ---------------------------------------------------------------------------
# The Immich Postgres image runs as uid 999. The pod also sets fsGroup: 999
# with fsGroupChangePolicy: OnRootMismatch, so kubelet would fix ownership on
# first mount -- but doing it here means the very first pod start does not
# depend on that, and OnRootMismatch only inspects the TOP directory.
set -euo pipefail

DERIVED=/srv/photos/immich-b        # thumbnails, previews, encoded video
DB=/srv/photos/immich-b-db          # PostgreSQL data
PRISTINE=/srv/photos/pristine       # reference copy, see make-pristine-copy.sh
POSTGRES_UID=999

log() { printf '[photo-storage] %s\n' "$*"; }
die() { printf '[photo-storage] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (/srv is root-owned)"

do_create() {
  # /srv exists on Debian by default but is not guaranteed on a rebuild.
  mkdir -p "$DERIVED" "$DB" "$PRISTINE"

  # Immich's server container runs as root and writes its own tree here.
  chown root:root "$DERIVED"
  chmod 755 "$DERIVED"

  # Postgres refuses to start if its data directory is group- or world-
  # readable: "data directory has invalid permissions ... must be u=rwx".
  # Note PGDATA is a SUBDIRECTORY of this mount (see postgres.yaml) because
  # initdb also refuses to run in a directory containing lost+found.
  chown "$POSTGRES_UID:$POSTGRES_UID" "$DB"
  chmod 700 "$DB"

  chown root:root "$PRISTINE"
  chmod 755 "$PRISTINE"

  log "created:"
  do_status
}

do_status() {
  local d
  for d in "$DERIVED" "$DB" "$PRISTINE"; do
    if [[ -d "$d" ]]; then
      printf '[photo-storage]   %-28s %s %s:%s  %s\n' "$d" \
        "$(stat -c '%A' "$d")" "$(stat -c '%u' "$d")" "$(stat -c '%g' "$d")" \
        "$(du -sh "$d" 2>/dev/null | cut -f1)"
    else
      printf '[photo-storage]   %-28s MISSING\n' "$d"
    fi
  done
  # Free space is the real constraint here: everything on this box shares one
  # filesystem, and a `local` PV's declared capacity is advisory -- nothing
  # warns before the disk fills.
  log "free on $(df --output=target /srv | tail -1): $(df -h --output=avail /srv | tail -1 | tr -d ' ')"
}

case "${1:---status}" in
  --create) do_create ;;
  --status) do_status ;;
  *) die "usage: $0 [--create|--status]" ;;
esac
