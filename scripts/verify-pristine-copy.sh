#!/usr/bin/env bash
# shellcheck disable=SC2154  # src_path/dest/file_count/total_bytes/manifest_lines come from the `source <(grep ...)` below
# verify-pristine-copy.sh — re-check the pristine photo copy against its
# manifest. Exits non-zero on ANY difference. Safe to run any time; read-only.
#
#   sudo ./scripts/verify-pristine-copy.sh          # full check (hashes everything)
#   sudo ./scripts/verify-pristine-copy.sh --quick  # counts + bytes + attrs only
#
# Run as root only because the copy is root-owned 0444; it writes nothing.
#
# ---------------------------------------------------------------------------
# WHAT THIS IS ACTUALLY TESTING
# ---------------------------------------------------------------------------
# Immich indexes /home/jacob/backup/Jacob/untitled through a mount asserted
# read-only in two independent places. This script is the control that would
# catch BOTH of them being wrong. Run it:
#
#   * after the first Immich library scan          (the important one)
#   * after every Immich version upgrade
#   * after anything that touches the PV or its mountOptions
#
# A pass here means the originals are byte-identical to the reference taken
# before Immich existed. A fail means something wrote to a tree that nothing
# should ever have been able to write to — investigate before doing anything
# else.
#
# ---------------------------------------------------------------------------
# TWO THINGS THIS DELIBERATELY DOES NOT CLAIM
# ---------------------------------------------------------------------------
# 1. It does NOT test durability. The copy shares one physical disk with the
#    originals, so one drive failure takes both. See setup-backup.sh.
#
# 2. It is NOT tamper-evident against a deliberate attacker. The manifest lives
#    beside the data and is not itself immutable (--refresh has to rewrite it),
#    so anyone who can modify the files can regenerate the manifest to match.
#    The threat model here is ACCIDENTAL modification -- a mis-applied
#    mountOptions, a bad upgrade, an Immich code path that writes where it
#    shouldn't -- not an adversary with root. For that, the manifest would need
#    to live off-box.
#
# NO-VIEWING CONSTRAINT: sha256sum reads bytes to hash them and never decodes
# or renders image content. Keep it that way.
set -uo pipefail   # deliberately not -e: a failed check must REPORT, not abort

DEST_ROOT="${PRISTINE_DEST:-/srv/photos/pristine}"
MANIFEST="$DEST_ROOT/MANIFEST.sha256"
META="$DEST_ROOT/MANIFEST.meta"

log()  { printf '[verify-pristine] %s\n' "$*"; }
die()  { printf '[verify-pristine] ERROR: %s\n' "$*" >&2; exit 2; }

FAIL=0
record() { # $1=name $2=result $3=detail
  printf '  %-28s %-6s %s\n' "$1" "$2" "${3:-}"
  [[ "$2" == "FAIL" ]] && FAIL=1
  return 0
}

[[ -f "$MANIFEST" ]] || die "no manifest at $MANIFEST — run make-pristine-copy.sh --create first"
[[ -f "$META" ]]     || die "no metadata at $META"

# Only these five keys, and only in `key=value` form -- the meta file is written
# by us, but sourcing anything unvalidated as shell is how a data file becomes
# code execution.
# shellcheck disable=SC1090
. <(grep -E '^(src_path|dest|file_count|total_bytes|manifest_lines)=[^;&|$(`]*$' "$META")
DEST="$dest"

log "reference taken from: $src_path"
log "checking:             $DEST"
echo

# --- 1. the copy still exists and is still locked ---------------------------
if [[ -d "$DEST" ]]; then
  record "copy exists" "PASS" "$DEST"
else
  record "copy exists" "FAIL" "$DEST is GONE"
  exit 1
fi

attrs="$(lsattr -d "$DEST" 2>/dev/null | awk '{print $1}')"
if [[ "$attrs" == *i* ]]; then
  record "immutable attribute" "PASS" "$attrs"
else
  record "immutable attribute" "FAIL" "chattr +i is NOT set (attrs: ${attrs:-none}) — copy is writable"
fi

# --- 2. shape: count and bytes ----------------------------------------------
now_count="$(find "$DEST" -type f -printf '.' | wc -c | tr -d ' ')"
now_bytes="$(du -sb "$DEST" | cut -f1)"

if [[ "$now_count" == "$file_count" ]]; then
  record "file count" "PASS" "$now_count"
else
  record "file count" "FAIL" "expected $file_count, found $now_count"
fi

if [[ "$now_bytes" == "$total_bytes" ]]; then
  record "total bytes" "PASS" "$now_bytes"
else
  record "total bytes" "FAIL" "expected $total_bytes, found $now_bytes"
fi

# --- 3. content: every hash ---------------------------------------------------
# This is the only check that catches an in-place modification that preserves
# both the file count and the total size. Counts and bytes are cheap screens;
# they are NOT a substitute for this, which is why --quick is not the default.
if [[ "${1:-}" == "--quick" ]]; then
  record "sha256 of every file" "SKIP" "--quick: shape checked, CONTENT NOT VERIFIED"
else
  log "hashing $now_count files..."
  cksum_out="$(cd "$DEST_ROOT" && sha256sum -c --quiet "$MANIFEST" 2>&1)"
  cksum_rc=$?
  if [[ $cksum_rc -eq 0 ]]; then
    record "sha256 of every file" "PASS" "$manifest_lines files match the reference"
  else
    # Count ONLY the per-file failure lines. sha256sum also emits a trailing
    # "WARNING: N computed checksums did NOT match" summary line, and counting
    # every line containing a colon inflated the tally by one -- caught by
    # tampering with a single file in a synthetic tree and being told 2 differed.
    bad="$(printf '%s\n' "$cksum_out" | grep -c ': FAILED$')"
    record "sha256 of every file" "FAIL" "$bad file(s) differ from the reference"
    printf '%s\n' "$cksum_out" | grep ': FAILED$' | head -20 | sed 's/^/    /'
    [[ "$bad" -gt 20 ]] && printf '    ... and %s more\n' "$((bad - 20))"
  fi
fi

# --- 4. the live source, for context -----------------------------------------
# Not a pass/fail: the source is EXPECTED to be identical, but a difference here
# is the interesting signal (something wrote to the originals), whereas a
# difference in the copy above means something defeated the immutable flag.
if [[ -d "$src_path" ]]; then
  src_count="$(find "$src_path" -type f -printf '.' | wc -c | tr -d ' ')"
  src_bytes="$(du -sb "$src_path" | cut -f1)"
  if [[ "$src_count" == "$file_count" && "$src_bytes" == "$total_bytes" ]]; then
    record "live source unchanged" "PASS" "$src_count files, $src_bytes bytes"
  else
    record "live source unchanged" "FAIL" \
      "SOURCE DRIFTED: expected $file_count/$total_bytes, found $src_count/$src_bytes — something wrote to the originals"
  fi
else
  record "live source unchanged" "FAIL" "$src_path is GONE"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  log "ALL CHECKS PASSED — originals are byte-identical to the pre-Immich reference"
else
  log "🔴 FAILURES ABOVE — investigate before touching anything else"
fi
exit "$FAIL"
