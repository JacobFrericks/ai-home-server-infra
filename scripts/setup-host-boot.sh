#!/usr/bin/env bash
# setup-host-boot.sh — make the host come up fully WITHOUT a human at the console.
# Idempotent; safe to re-run.
#
#   ./scripts/setup-host-boot.sh --check     # read-only (DEFAULT)
#   sudo ./scripts/setup-host-boot.sh --apply
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# On 2026-08-27 unattended-upgrades rebooted the box at 04:00, as designed. It
# then sat for 38 HOURS doing nothing useful, and nobody knew:
#
#   Aug 27 04:02  boot; enp15s0 carrier comes up, then parks at 'disconnected'
#   Aug 28 17:59  k3s: fatal "no default routes found in /proc/net/route"
#   Aug 28 03:30  nightly restic backup runs -> kubectl fails -> backup FAILS
#   Aug 28 18:22  a human logs in at the console -> NIC activates -> all recovers
#
# Root cause: the NetworkManager profile for the wired NIC carried
# `permissions=user:jacob:;`. A user-scoped profile is only activated while that
# user has an active session, so the machine had no network until someone
# physically logged in. Everything downstream — sshd reachable, k3s startable,
# backups able to reach the API — depended on a person walking to the machine.
#
# The failure is silent in the worst way: the host is UP, systemd is running,
# timers fire, sshd is listening. It just cannot be reached and cannot do its
# job. A remote check sees "host down" and a local check sees "everything fine".
#
# This script asserts the boot-path invariants that keep that from recurring.
set -euo pipefail

log()  { printf '[host-boot] %s\n' "$*"; }
warn() { printf '[host-boot] WARN: %s\n' "$*" >&2; }
die()  { printf '[host-boot] ERROR: %s\n' "$*" >&2; exit 1; }

# The wired NIC the server is actually reachable on.
WIRED_IFACE=enp15s0

# Resolve the profile currently bound to that interface, rather than hardcoding
# a name — the profile has been renamed before ("Wired connection 1").
wired_profile() {
  nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
    | awk -F: -v d="$WIRED_IFACE" '$2==d {print $1; exit}'
}

do_check() {
  local rc=0 prof perms

  prof="$(wired_profile)"
  if [[ -z "$prof" ]]; then
    warn "no active NetworkManager profile on $WIRED_IFACE"; return 1
  fi
  echo "  wired profile: $prof"

  # THE check. A non-empty permissions list means "only while this user is
  # logged in", which is exactly the 38-hour outage above.
  perms="$(nmcli -t -f connection.permissions con show "$prof" 2>/dev/null | cut -d: -f2-)"
  if [[ -z "$perms" ]]; then
    echo "  permissions: (none) — system-wide, activates at boot"
  else
    warn "permissions='$perms' — profile is USER-SCOPED; the host will have NO network until that user logs in"
    rc=1
  fi

  [[ "$(nmcli -t -f connection.autoconnect con show "$prof" | cut -d: -f2)" == "yes" ]] \
    && echo "  autoconnect: yes" || { warn "autoconnect is off"; rc=1; }

  # k3s cannot start without a default route, so it is a good downstream canary.
  ip route show default | grep -q . && echo "  default route: present" \
    || { warn "no default route — k3s will fail to start"; rc=1; }
  systemctl is-enabled --quiet k3s && echo "  k3s: enabled at boot" \
    || { warn "k3s not enabled at boot"; rc=1; }
  systemctl is-enabled --quiet ssh && echo "  sshd: enabled at boot" \
    || { warn "sshd not enabled at boot"; rc=1; }

  return $rc
}

do_apply() {
  [[ $EUID -eq 0 ]] || die "must run as root (edits /etc/NetworkManager)"
  local prof; prof="$(wired_profile)"
  [[ -n "$prof" ]] || die "no active profile on $WIRED_IFACE — refusing to guess"

  # Clearing permissions writes the profile file only; it does NOT bounce the
  # link, so this is safe to run over SSH on the very interface being changed.
  nmcli con modify "$prof" \
    connection.permissions "" \
    connection.autoconnect yes \
    connection.autoconnect-priority 100
  log "'$prof' is now system-wide (autoconnect, priority 100)"

  do_check
}

case "${1:---check}" in
  --check) do_check ;;
  --apply) do_apply ;;
  *) die "usage: $0 [--check|--apply]" ;;
esac
