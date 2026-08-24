#!/usr/bin/env bash
# setup-raid.sh — build and maintain the RAID 1 backup mirror. Idempotent, safe to re-run.
#
#   ./scripts/setup-raid.sh --check                 # read-only status (DEFAULT)
#   sudo ./scripts/setup-raid.sh --harden           # timeouts, scrub cron, smartd only
#   sudo ./scripts/setup-raid.sh --create --i-understand-this-erases WD-... WD-...
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
# ---------------------------------------------------------------------------
# Two 4TB WD drives (ex-Windows LDM dynamic-disk mirror from the old PC) become a
# Linux md RAID 1 at /srv/backup, which is the restic target for setup-backup.sh.
# Before this existed there were NO backups of anything on this box, including the
# sealed-secrets master key.
#
# ---------------------------------------------------------------------------
# 🔴 THE ONE CATASTROPHIC FAILURE MODE
# ---------------------------------------------------------------------------
# Writing to the wrong disk. /dev/nvme0n1 is the ENTIRE SYSTEM — root LV, /boot,
# every PVC, every container. Kernel device letters are NOT stable across boots,
# so `sda` today can be a different disk tomorrow.
#
# Therefore --create NEVER trusts a device path. It resolves disks by SERIAL, the
# caller must type both serials on the command line, and every device is re-checked
# immediately before it is written to. A mismatch is a hard abort, never a prompt.
set -euo pipefail

# --- the only two disks this script may ever write to ------------------------
SERIAL_RED=WD-WCC7K0DFV5HH      # WDC WD40EFRX-68N32N0  (NAS drive, has TLER/ERC)
SERIAL_BLUE=WD-WCC7K5CEXLL6     # WDC WD40EZRZ-22GXCB0  (desktop drive, NO ERC)
ALLOWED_SERIALS=("$SERIAL_RED" "$SERIAL_BLUE")

ARRAY=/dev/md0
ARRAY_NAME=backup
MOUNTPOINT=/srv/backup
FSLABEL=backup
TAIL_SLACK=100M                 # leave slack so a marginally smaller replacement still fits

log()  { printf '[raid] %s\n' "$*"; }
warn() { printf '[raid] WARN: %s\n' "$*" >&2; }
die()  { printf '[raid] ERROR: %s\n' "$*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }

# =============================================================================
# Disk identity — the safety core. Nothing destructive runs without these.
# =============================================================================

serial_of() { lsblk -dno SERIAL "$1" 2>/dev/null | tr -d ' '; }

# Resolve a serial to its CURRENT device path. This is the only sanctioned way to
# get a device path for writing; never accept one from the caller.
dev_for_serial() {
  local want="$1" d s
  for d in /dev/sd?; do
    [[ -b "$d" ]] || continue
    s="$(serial_of "$d")"
    [[ "$s" == "$want" ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

# Re-verified immediately before every destructive write. Belt and braces on purpose:
# the allow-list alone would be enough, but the explicit nvme/mount/holder checks mean
# a future edit that widens the allow-list still cannot eat the system disk.
assert_safe_target() {
  local dev="$1" s allowed=0 a mp
  [[ -b "$dev" ]] || die "REFUSING: $dev is not a block device"
  [[ "$dev" == /dev/nvme* ]] && die "REFUSING: $dev is an NVMe device"
  [[ "$dev" =~ ^/dev/sd[a-z]$ ]] || die "REFUSING: $dev is not a whole SATA disk"

  s="$(serial_of "$dev")"
  [[ -n "$s" ]] || die "REFUSING: cannot read a serial from $dev"
  for a in "${ALLOWED_SERIALS[@]}"; do [[ "$s" == "$a" ]] && allowed=1; done
  (( allowed )) || die "REFUSING: $dev has serial '$s', which is not a backup drive"

  # Nothing on this disk may be in use, mounted, swapped, or claimed by LVM/md.
  mp="$(lsblk -no MOUNTPOINT "$dev" | grep -c . || true)"
  [[ "$mp" -eq 0 ]] || die "REFUSING: $dev has a mounted partition"
  # Only a rejection if a member is actually assembled: an inactive stale signature
  # is exactly what we are here to erase.
  if lsblk -no TYPE "$dev" | grep -qE '^(lvm|raid[0-9])$'; then
    die "REFUSING: $dev is claimed by an active LVM VG or md array"
  fi
  if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^$dev"; then
    die "REFUSING: $dev is in use as swap"
  fi

  log "verified $dev = $s (safe to write)"
}

# The system disk must be healthy and untouched. Checked before AND after the wipe.
assert_nvme_intact() {
  findmnt -no SOURCE / | grep -q 'HomeServer--vg-root' \
    || die "ABORT: / is not the expected NVMe root LV — refusing to continue"
  [[ -b /dev/nvme0n1p3 ]] || die "ABORT: /dev/nvme0n1p3 missing"
  vgs HomeServer-vg >/dev/null 2>&1 || die "ABORT: HomeServer-vg not found"
}

# =============================================================================
# --check : read-only status. Safe for anyone, any time, including cron.
# =============================================================================

do_check() {
  local rc=0 dev s

  echo "--- disks ---"
  for s in "${ALLOWED_SERIALS[@]}"; do
    if dev="$(dev_for_serial "$s")"; then
      printf '  %-16s %s  %s\n' "$s" "$dev" "$(lsblk -dno MODEL "$dev")"
    else
      printf '  %-16s MISSING\n' "$s"; rc=1
    fi
  done

  echo "--- array ---"
  if [[ -b "$ARRAY" ]]; then
    grep -A2 "^md" /proc/mdstat | sed 's/^/  /'
    if mdadm --detail "$ARRAY" 2>/dev/null | grep -q 'State : clean'; then
      log "array clean"
    else
      warn "array is NOT clean"; rc=1
    fi
  else
    warn "$ARRAY does not exist"; rc=1
  fi

  echo "--- filesystem ---"
  if mountpoint -q "$MOUNTPOINT"; then
    df -h "$MOUNTPOINT" | tail -1 | sed 's/^/  /'
  else
    warn "$MOUNTPOINT not mounted"; rc=1
  fi

  echo "--- hardening ---"
  for s in "${ALLOWED_SERIALS[@]}"; do
    if dev="$(dev_for_serial "$s")"; then
      printf '  %s timeout=%ss\n' "$dev" "$(cat "/sys/block/${dev#/dev/}/device/timeout" 2>/dev/null || echo '?')"
    fi
  done
  if [[ -x /usr/share/mdadm/checkarray && -f /etc/cron.d/mdadm ]]; then
    echo "  scrub cron: present"
  else
    warn "scrub cron missing or checkarray not executable"; rc=1
  fi
  systemctl is-active --quiet smartmontools && echo "  smartd: active" || { warn "smartd not active"; rc=1; }
  # smartd stops reading at the first DEVICESCAN, so a self-test entry BELOW one
  # is silently dead. Verify ours is genuinely above it, not merely present.
  local ln_disk ln_scan
  ln_disk="$(grep -n '^/dev/disk/by-id/.*-s (S/' /etc/smartd.conf 2>/dev/null | head -1 | cut -d: -f1)"
  ln_scan="$(grep -n '^DEVICESCAN' /etc/smartd.conf 2>/dev/null | head -1 | cut -d: -f1)"
  if [[ -n "$ln_disk" && ( -z "$ln_scan" || "$ln_disk" -lt "$ln_scan" ) ]]; then
    echo "  smartd self-tests: scheduled (line $ln_disk, above DEVICESCAN)"
  else
    warn "smartd self-tests NOT scheduled (entry missing, or below DEVICESCAN and therefore ignored)"; rc=1
  fi

  return $rc
}

# =============================================================================
# --create : the destructive path.
# =============================================================================

wipe_disk() {
  local dev="$1" bytes mb
  assert_safe_target "$dev"          # re-verify at the last possible moment

  log "wiping $dev"
  # Partitions first, then the disk, so no stale signature is left behind.
  local p; for p in "$dev"?*; do [[ -b "$p" ]] && wipefs -a "$p" >/dev/null || true; done
  wipefs -a "$dev" >/dev/null || true
  sgdisk --zap-all "$dev" >/dev/null

  # Windows LDM (dynamic disk) metadata lives at BOTH ends of the disk, and the
  # backup GPT header lives in the last sectors. wipefs/sgdisk alone leave enough
  # behind that the kernel can still probe an LDM volume, so zero both ends.
  bytes="$(blockdev --getsize64 "$dev")"; mb=$(( bytes / 1024 / 1024 ))
  dd if=/dev/zero of="$dev" bs=1M count=16 conv=fsync status=none
  dd if=/dev/zero of="$dev" bs=1M seek=$(( mb - 16 )) count=16 conv=fsync status=none

  partprobe "$dev"; udevadm settle
  log "wiped $dev"
}

partition_disk() {
  local dev="$1"
  assert_safe_target "$dev"
  log "partitioning $dev"
  sgdisk --new=1:2048:-${TAIL_SLACK} \
         --typecode=1:FD00 \
         --change-name=1:backup-mirror "$dev" >/dev/null
  partprobe "$dev"; udevadm settle
}

do_create() {
  need_root
  # The caller must type BOTH serials. This is the human confirmation step: it is
  # impossible to fire this by tab-completing a device path.
  local given_a="${1:-}" given_b="${2:-}"
  [[ "$given_a" == "$SERIAL_RED"  || "$given_a" == "$SERIAL_BLUE" ]] || die "serial 1 does not match a backup drive"
  [[ "$given_b" == "$SERIAL_RED"  || "$given_b" == "$SERIAL_BLUE" ]] || die "serial 2 does not match a backup drive"
  [[ "$given_a" != "$given_b" ]] || die "the two serials must differ"

  assert_nvme_intact

  if [[ -b "$ARRAY" ]]; then
    log "$ARRAY already exists — nothing to create"
    do_check || return $?
    return 0
  fi

  # Pre-flight: no arrays assembled, nothing from these disks in fstab.
  if grep -qE '^md[0-9]' /proc/mdstat; then
    die "an md array is already assembled — resolve manually"
  fi
  local dev_a dev_b
  dev_a="$(dev_for_serial "$given_a")" || die "serial $given_a not present"
  dev_b="$(dev_for_serial "$given_b")" || die "serial $given_b not present"
  if grep -qE "$(basename "$dev_a")|$(basename "$dev_b")" /etc/fstab; then
    die "fstab still references these disks"
  fi

  log "targets: $dev_a ($given_a), $dev_b ($given_b)"
  wipe_disk "$dev_a";      wipe_disk "$dev_b"
  partition_disk "$dev_a"; partition_disk "$dev_b"
  assert_nvme_intact       # the system disk must be exactly as healthy as before

  log "creating $ARRAY"
  # --bitmap=internal: a write-intent bitmap means a transient drop re-syncs only
  # the dirty regions instead of re-copying all 3.6TB.
  # stdin is not a tty over ssh; the disks were just zeroed so any prompt mdadm
  # raises is about a stale signature we already intend to destroy.
  printf 'y\n' | mdadm --create "$ARRAY" --run \
    --level=1 --raid-devices=2 --metadata=1.2 \
    --bitmap=internal --name="$ARRAY_NAME" \
    "${dev_a}1" "${dev_b}1"

  # Resync runs in the background; the array is fully usable meanwhile.
  echo 100000 > /proc/sys/dev/raid/speed_limit_min || true
  persist_array
  make_filesystem
  do_harden
  log "created. resync is running in the background — watch: cat /proc/mdstat"
}

persist_array() {
  # Without this the array will not assemble at boot.
  local uuid line
  uuid="$(mdadm --detail --brief "$ARRAY" | grep -o 'UUID=[^ ]*')"
  if ! grep -q "$uuid" /etc/mdadm/mdadm.conf 2>/dev/null; then
    line="$(mdadm --detail --scan "$ARRAY")"
    printf '%s\n' "$line" >> /etc/mdadm/mdadm.conf
    log "added to /etc/mdadm/mdadm.conf"
  fi
  update-initramfs -u >/dev/null 2>&1
}

make_filesystem() {
  if ! blkid "$ARRAY" >/dev/null 2>&1; then
    # -m 0: this is not a root fs, so the 5% root reserve is 180GB thrown away.
    mkfs.ext4 -q -m 0 -L "$FSLABEL" "$ARRAY"
    log "formatted ext4"
  fi
  mkdir -p "$MOUNTPOINT"
  local uuid; uuid="$(blkid -s UUID -o value "$ARRAY")"
  if ! grep -q "$uuid" /etc/fstab; then
    # nofail: if the array is degraded or absent at boot the server must still come
    # up and run the cluster, not drop to an emergency shell.
    printf 'UUID=%s  %s  ext4  defaults,noatime,nofail,x-systemd.device-timeout=30  0  2\n' \
      "$uuid" "$MOUNTPOINT" >> /etc/fstab
    systemctl daemon-reload
    log "added to /etc/fstab"
  fi
  mountpoint -q "$MOUNTPOINT" || mount "$MOUNTPOINT"
  log "mounted $MOUNTPOINT"
}

# =============================================================================
# --harden : survivability. Separately runnable; --create calls it too.
# =============================================================================

do_harden() {
  need_root
  local dev s

  # 0. Resync/rebuild speed floor. The kernel default min is 1000 (1MB/s), and
  #    it is NOT a boot-persistent setting. With restic writing to the same
  #    spindles a fresh resync drops to single-digit MB/s and a 3.6TB mirror
  #    takes DAYS instead of hours -- and until it finishes the mirror is not
  #    actually redundant, which is the whole reason it exists.
  cat > /etc/sysctl.d/60-md-resync.conf <<'SYSCTL'
# Keep the backup mirror resync moving even while restic is writing to it.
dev.raid.speed_limit_min = 50000
dev.raid.speed_limit_max = 200000
SYSCTL
  sysctl -q -p /etc/sysctl.d/60-md-resync.conf || warn "could not apply resync sysctl"
  log "resync speed floor set to 50MB/s"

  # 1. SCSI timeout. The Blue drive has no ERC/TLER: on a marginal sector it can
  #    retry for minutes, blow the 30s default timeout, and get kicked out of a
  #    perfectly healthy array. Matched on serial so a letter reshuffle is harmless.
  cat > /etc/udev/rules.d/99-md-disk-timeout.rules <<RULES
# Backup mirror members. The WD Blue has no ERC, so give both disks a timeout
# longer than a worst-case internal recovery instead of dropping them from md.
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_SERIAL_SHORT}=="$SERIAL_RED", ATTR{device/timeout}="180"
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_SERIAL_SHORT}=="$SERIAL_BLUE", ATTR{device/timeout}="180"
RULES
  udevadm control --reload
  for s in "${ALLOWED_SERIALS[@]}"; do
    if dev="$(dev_for_serial "$s")"; then
      echo 180 > "/sys/block/${dev#/dev/}/device/timeout" 2>/dev/null || true
    fi
  done
  log "disk timeouts set to 180s"

  # 2. ERC where the hardware supports it. The Red accepts; the Blue refuses, and
  #    that refusal is expected — it is exactly why step 1 exists.
  if dev="$(dev_for_serial "$SERIAL_RED")"; then
    smartctl -l scterc,70,70 "$dev" >/dev/null 2>&1 \
      && log "ERC 7s set on the Red" || warn "Red did not accept ERC"
  fi

  # 3. Monthly scrub. Finds latent bad sectors BEFORE a rebuild needs to read them,
  #    which is the moment a second drive failure turns into data loss.
  if [[ ! -f /etc/cron.d/mdadm ]]; then
    cat > /etc/cron.d/mdadm <<'CRON'
# Monthly md scrub — first Sunday, 02:00. checkarray reads every block and repairs
# mismatches from the good copy.
57 0 * * 0 root [ -x /usr/share/mdadm/checkarray ] && [ $(date +\%d) -le 7 ] && /usr/share/mdadm/checkarray --cron --all --idle --quiet
CRON
    log "installed monthly scrub cron"
  fi

  # 4. smartd self-tests. Both drives are ~6 years old, so a scheduled long test
  #    is the cheapest early warning available.
  #
  #    ⚠️ smartd IGNORES EVERY LINE AFTER THE FIRST `DEVICESCAN`, and Debian ships
  #    one enabled by default. Appending a second DEVICESCAN — the obvious thing
  #    to do — produces a config that looks correct, logs nothing, and schedules
  #    no tests at all. Explicit per-device lines must go BEFORE that DEVICESCAN.
  #    Addressed via /dev/disk/by-id so the entry follows the disk, not the letter.
  if [[ -f /etc/smartd.conf ]] && ! grep -q 'backup mirror' /etc/smartd.conf; then
    local byid tmpconf; tmpconf="$(mktemp)"
    {
      echo '# --- backup mirror (added by setup-raid.sh) ---'
      echo '# Short test Sun 03:00, long test 1st Sat 04:00, temp warn 45C / crit 55C.'
      echo '# Placed above DEVICESCAN on purpose: smartd stops reading at that line.'
      for byid in /dev/disk/by-id/*"$SERIAL_RED" /dev/disk/by-id/*"$SERIAL_BLUE"; do
        [[ -e "$byid" ]] && printf '%s -a -o on -S on -s (S/../.././03|L/../../6/04) -W 4,45,55\n' "$byid"
      done
      echo
      cat /etc/smartd.conf
    } > "$tmpconf"
    cat "$tmpconf" > /etc/smartd.conf
    rm -f "$tmpconf"
    log "smartd tests scheduled (above DEVICESCAN)"
  fi
  # The unit is smartmontools.service; "smartd" is only an alias and cannot be
  # enabled directly on Debian.
  systemctl enable --now smartmontools >/dev/null 2>&1 || warn "could not enable smartmontools"
}

case "${1:---check}" in
  --check)  do_check ;;
  --harden) do_harden ;;
  --create)
    [[ "${2:-}" == "--i-understand-this-erases" ]] \
      || die "usage: $0 --create --i-understand-this-erases <serial> <serial>"
    do_create "${3:-}" "${4:-}"
    ;;
  *) die "usage: $0 [--check|--harden|--create --i-understand-this-erases <serial> <serial>]" ;;
esac
