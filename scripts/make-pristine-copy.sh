#!/usr/bin/env bash
# make-pristine-copy.sh — take an independent, immutable, checksummed copy of a
# photo directory BEFORE any application is pointed at it. Safe to re-run.
#
# Run as root: it sets root ownership and the ext4 immutable attribute.
#
#   sudo ./scripts/make-pristine-copy.sh --create     # first run: copy + manifest + lock
#   sudo ./scripts/make-pristine-copy.sh --refresh    # unlock, re-sync from source, re-lock
#   sudo ./scripts/make-pristine-copy.sh --status     # what exists today, no changes
#
# Verification is a SEPARATE script on purpose — see verify-pristine-copy.sh.
# A manifest generated once and never re-checked proves nothing.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# Immich is about to index /home/jacob/backup/Jacob/untitled as a read-only
# external library. "Read-only" is asserted in two places (the PV's mountOptions
# and the container volumeMount) and both are one typo away from silently not
# applying. This copy is the control that would CATCH that, rather than trusting
# it: a byte-for-byte reference taken before Immich exists, re-checked after.
#
# 🔴 THIS IS NOT A BACKUP. It is a tamper check, and it lives on the SAME
# PHYSICAL DISK as the originals (one 4TB NVMe holds everything on this box).
# A single drive failure takes both copies. Real backups are setup-backup.sh,
# still blocked on a dedicated target drive.
#
# ---------------------------------------------------------------------------
# THE NO-VIEWING CONSTRAINT
# ---------------------------------------------------------------------------
# Everything here operates on bytes and metadata only. rsync copies bytes and
# sha256sum hashes them; neither decodes, renders, or interprets image content.
# No thumbnailing, no EXIF parsing, no `identify`. That is deliberate and must
# stay true of any future edit to this file.
set -euo pipefail

SRC="${PRISTINE_SRC:-/home/jacob/backup/Jacob/untitled}"
DEST_ROOT="${PRISTINE_DEST:-/srv/photos/pristine}"
DEST="$DEST_ROOT/$(basename "$SRC")"
MANIFEST="$DEST_ROOT/MANIFEST.sha256"
META="$DEST_ROOT/MANIFEST.meta"

log() { printf '[pristine] %s\n' "$*"; }
die() { printf '[pristine] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (sets root ownership and the immutable attribute)"
[[ -d "$SRC" ]]   || die "source does not exist: $SRC"

# ext4 only. chattr +i is what makes this copy meaningfully hard to clobber --
# without it, "read-only" is just permissions, which root ignores by default.
command -v chattr >/dev/null || die "chattr not found; e2fsprogs is required"

# --- locking ----------------------------------------------------------------
# -R applies recursively. Files AND directories: an immutable file inside a
# mutable directory can still be renamed out from under you.
lock()   { chattr -R +i "$DEST" 2>/dev/null || log "WARN: chattr +i failed (non-ext4?)"; }
unlock() { chattr -R -i "$DEST" 2>/dev/null || true; }

count_files() { find "$1" -type f -printf '.' | wc -c | tr -d ' '; }
total_bytes() { du -sb "$1" | cut -f1; }

# --- manifest ---------------------------------------------------------------
# NUL-delimited throughout: this tree contains directories with spaces in their
# names, and a newline in a filename would corrupt a line-based pipeline.
# sha256sum escapes such names with a leading backslash and `-c` understands it.
build_manifest() {
  log "hashing $(count_files "$DEST") files — this reads every byte, expect it to take a while"
  ( cd "$DEST_ROOT" && find "$(basename "$SRC")" -type f -print0 \
      | sort -z \
      | xargs -0 -r sha256sum > "$MANIFEST" )
  chmod 444 "$MANIFEST"

  {
    printf 'src_path=%s\n'     "$SRC"
    printf 'dest=%s\n'         "$DEST"
    printf 'created=%s\n'      "$(date -Is)"
    printf 'file_count=%s\n'   "$(count_files "$DEST")"
    printf 'total_bytes=%s\n'  "$(total_bytes "$DEST")"
    printf 'manifest_lines=%s\n' "$(wc -l < "$MANIFEST" | tr -d ' ')"
  } > "$META"
  chmod 444 "$META"

  log "manifest: $(wc -l < "$MANIFEST" | tr -d ' ') entries, $(du -h "$DEST" | tail -1 | cut -f1) total"
}

# --- the copy ---------------------------------------------------------------
# --checksum, not the default size+mtime heuristic. Slower, and correct: mtimes
# on this tree are known to be unreliable (a past copy flattened an entire
# sibling collection to a single date), so mtime equality proves nothing here.
do_sync() {
  mkdir -p "$DEST_ROOT"
  rsync -aH --checksum --delete --info=progress2 "$SRC/" "$DEST/"

  # Source and copy must agree before the manifest is taken, or the manifest
  # records a bad copy as if it were good.
  local sc dc sb db
  sc="$(count_files "$SRC")"; dc="$(count_files "$DEST")"
  sb="$(total_bytes "$SRC")"; db="$(total_bytes "$DEST")"
  [[ "$sc" == "$dc" ]] || die "file count mismatch after rsync: source=$sc copy=$dc"
  [[ "$sb" == "$db" ]] || die "byte count mismatch after rsync: source=$sb copy=$db"
  log "copy matches source: $sc files, $sb bytes"
}

harden() {
  chown -R root:root "$DEST"
  chmod -R a-w "$DEST"
  lock
  log "locked: root-owned, unwritable, immutable (chattr +i)"
}

do_create() {
  if [[ -f "$MANIFEST" ]]; then
    die "manifest already exists at $MANIFEST — use --refresh to re-sync, or --status to inspect. Refusing to silently overwrite a reference copy."
  fi
  do_sync
  build_manifest
  harden
  log "done. Verify with: sudo ./scripts/verify-pristine-copy.sh"
}

do_refresh() {
  [[ -f "$MANIFEST" ]] || die "no existing manifest; use --create first"
  log "unlocking to re-sync — the reference is UNPROTECTED until this finishes"
  unlock
  chmod -R u+w "$DEST"
  rm -f "$MANIFEST" "$META"
  do_sync
  build_manifest
  harden
}

do_status() {
  if [[ ! -d "$DEST" ]]; then log "no pristine copy at $DEST"; exit 0; fi
  log "dest:   $DEST"
  log "source: $SRC ($(count_files "$SRC") files, $(total_bytes "$SRC") bytes)"
  if [[ -f "$META" ]]; then sed 's/^/[pristine]   /' "$META"; else log "NO MANIFEST — this copy is unverifiable"; fi
  # lsattr on the top directory is enough to tell whether harden() ever ran.
  log "attrs:  $(lsattr -d "$DEST" 2>/dev/null | awk '{print $1}')"
}

case "${1:---status}" in
  --create)  do_create ;;
  --refresh) do_refresh ;;
  --status)  do_status ;;
  *) die "usage: $0 [--create|--refresh|--status]" ;;
esac
