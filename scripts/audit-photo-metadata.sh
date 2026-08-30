#!/usr/bin/env bash
# audit-photo-metadata.sh — report EXIF date coverage for a photo directory, so
# the import-date question is answered from real numbers instead of a guess.
#
#   sudo ./scripts/audit-photo-metadata.sh --install   # exiftool only (needs root)
#        ./scripts/audit-photo-metadata.sh --report    # the audit (no root needed)
#
# Reads nothing but metadata. Writes nothing but its own report.
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# Immich dates an asset by EXIF DateTimeOriginal first and falls back to the
# file's mtime. That fallback is a trap on this box: every one of the 3,062
# files in the SIBLING collection (~/backup/Photos) carries an mtime of
# 2025-01-25, because a past copy operation flattened them. Any file there
# without embedded EXIF would land in the timeline on that single day.
#
# Whether the same is true of THIS directory is unknown, and guessing costs
# either unnecessary repair work or a permanently wrong timeline. So: measure
# first. The output tells you how many files have a real embedded date, how
# many would fall back to mtime, and whether those mtimes are plausible.
#
# ---------------------------------------------------------------------------
# THE NO-VIEWING CONSTRAINT
# ---------------------------------------------------------------------------
# exiftool is invoked in metadata-extraction mode only. It parses header
# structures (EXIF/XMP/QuickTime atoms) and never decodes pixel data, renders,
# thumbnails, or extracts embedded previews. Specifically NOT used here:
#   -b / -Preview* / -ThumbnailImage   (would extract actual image data)
#   -W / -w with binary output
# Keep it that way if you edit this file.
set -uo pipefail

SRC="${AUDIT_SRC:-/home/jacob/backup/Jacob/untitled}"
OUT="${AUDIT_OUT:-/tmp/photo-metadata-audit}"

log() { printf '[audit] %s\n' "$*"; }
die() { printf '[audit] ERROR: %s\n' "$*" >&2; exit 1; }

do_install() {
  [[ $EUID -eq 0 ]] || die "--install must run as root"
  if command -v exiftool >/dev/null; then log "exiftool already present: $(exiftool -ver)"; return; fi
  log "installing libimage-exiftool-perl"
  apt-get update -qq && apt-get install -y -qq libimage-exiftool-perl
  log "installed exiftool $(exiftool -ver)"
}

do_report() {
  command -v exiftool >/dev/null || die "exiftool not installed; run: sudo $0 --install"
  [[ -d "$SRC" ]] || die "source does not exist: $SRC"
  mkdir -p "$OUT"

  local csv="$OUT/metadata.csv"
  log "scanning $SRC (metadata only, no image content is read)"

  # -fast2 stops parsing at the end of the metadata block instead of scanning
  # the whole file -- materially faster on a 50GB tree that is mostly video,
  # and it also means less of each file is ever touched.
  # Three date tags because stills and video disagree about which one is real:
  #   DateTimeOriginal  - EXIF, stills
  #   CreateDate        - EXIF/XMP, both
  #   MediaCreateDate   - QuickTime/MP4 atoms, video
  exiftool -q -q -r -n -fast2 -csv \
    -FileName -Directory -FileTypeExtension -FileSize \
    -DateTimeOriginal -CreateDate -MediaCreateDate -FileModifyDate \
    "$SRC" > "$csv" 2>"$OUT/exiftool.err" || true

  [[ -s "$csv" ]] || die "exiftool produced no output; see $OUT/exiftool.err"

  python3 - "$csv" "$SRC" <<'PY'
import csv, sys, os, collections, re
csv.field_size_limit(10**7)
path, src = sys.argv[1], sys.argv[2]

rows = list(csv.DictReader(open(path, newline='', encoding='utf-8', errors='replace')))
if not rows:
    print("no rows parsed"); sys.exit(1)

def has(r, k):
    v = (r.get(k) or "").strip()
    # exiftool writes 0000:00:00 00:00:00 for a present-but-empty date field.
    return bool(v) and not v.startswith("0000")

def year(r, k):
    m = re.match(r"(\d{4})", (r.get(k) or "").strip())
    return m.group(1) if m else None

by_ext = collections.defaultdict(lambda: {"n":0, "dated":0, "bytes":0})
mtime_years = collections.Counter()
embedded_years = collections.Counter()
no_date = []

for r in rows:
    ext = (r.get("FileTypeExtension") or "?").lower()
    e = by_ext[ext]; e["n"] += 1
    try: e["bytes"] += int(r.get("FileSize") or 0)
    except ValueError: pass

    dated = any(has(r, k) for k in ("DateTimeOriginal", "CreateDate", "MediaCreateDate"))
    if dated:
        e["dated"] += 1
        for k in ("DateTimeOriginal", "CreateDate", "MediaCreateDate"):
            y = year(r, k)
            if y: embedded_years[y] += 1; break
    else:
        no_date.append(os.path.join(r.get("Directory",""), r.get("FileName","")))
    y = year(r, "FileModifyDate")
    if y: mtime_years[y] += 1

total = len(rows)
dated = sum(v["dated"] for v in by_ext.values())

print(f"\n=== EXIF DATE COVERAGE — {src} ===\n")
print(f"{'ext':<8}{'files':>8}{'with date':>12}{'coverage':>11}{'size':>12}")
print("-" * 51)
for ext, v in sorted(by_ext.items(), key=lambda kv: -kv[1]["n"]):
    pct = 100.0 * v["dated"] / v["n"] if v["n"] else 0
    gb = v["bytes"] / 1e9
    size = f"{gb:.2f} GB" if gb >= 0.01 else f"{v['bytes']/1e6:.1f} MB"
    print(f"{ext:<8}{v['n']:>8}{v['dated']:>12}{pct:>10.1f}%{size:>12}")
print("-" * 51)
print(f"{'TOTAL':<8}{total:>8}{dated:>12}{100.0*dated/total:>10.1f}%")

print(f"\n{total - dated} file(s) have NO embedded date and would fall back to mtime.\n")

print("mtime years (the fallback Immich would use):")
for y, c in sorted(mtime_years.items()):
    flag = "  <-- suspicious: a single flattened date?" if c > 0.5 * total else ""
    print(f"  {y}: {c}{flag}")

if embedded_years:
    print("\nembedded date years (the real dates, where present):")
    for y, c in sorted(embedded_years.items()):
        print(f"  {y}: {c}")

if no_date:
    print(f"\nfirst 25 files with no embedded date:")
    for p in sorted(no_date)[:25]:
        print(f"  {p}")
    if len(no_date) > 25:
        print(f"  ... and {len(no_date)-25} more")

print("\nINTERPRETATION")
print("  High coverage + varied mtime years -> import as-is, no repair needed.")
print("  Low coverage  + ONE dominant mtime year -> those files will all land on")
print("    that single day in the timeline. Repair via XMP sidecars before import.")
PY

  log "raw csv kept at $csv (metadata only — no image data)"
}

case "${1:---report}" in
  --install) do_install ;;
  --report)  do_report ;;
  *) die "usage: $0 [--install|--report]" ;;
esac
