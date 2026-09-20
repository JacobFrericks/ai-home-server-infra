#!/usr/bin/env bash
#
# fix-mm-logs.sh — stop MagicMirror writing secret calendar URLs to disk,
# and clean up the ones already there. Idempotent.
#
# THE PROBLEM
# -----------
# The stock `calendar` module logs the FULL feed URL on every fetch, at INFO
# and LOG level, and again on error:
#
#   [INFO] [calendar] Broadcasting 48 events from https://calendar.google.com/
#          calendar/ical/<address>/private-<32 hex>/basic.ics
#
# That "private-..." key IS the credential. Anyone holding the URL reads the
# calendar forever, with no login and no way to tell they are doing it. Found
# three distinct keys -- both adults' personal calendars and the family one --
# across ~500 log lines, in files that were mode 644, i.e. readable by every
# account on the machine.
#
# FOUR PARTS, because no single one is sufficient:
#   1. Stop emitting them: drop INFO/LOG from logLevel.
#   2. Purge what is already written.
#   3. Lock the log DIRECTORY, not just the files -- new files inherit the
#      umask, so per-file chmod fixes only today.
#   4. Lock config.js, which holds the same URLs by necessity.
#
# Part 1 alone is not enough: fetch FAILURES log the URL at ERROR level, and
# ERROR has to stay on -- it is how a broken feed is noticed at all. So a
# secret CAN still reach the disk, and the redaction pass is not a one-time
# cleanup. Hence --install: a timer that re-runs it, so the exposure window is
# bounded by a schedule rather than by somebody remembering.
#
# Part 3 -- the 700 directory -- is what holds in between, and needs nobody to
# remember anything. It is the durable control; the timer bounds how long a
# leaked line sits there for the one account that can read it.
#
#   ./fix-mm-log-leak.sh              # redact + harden once
#   ./fix-mm-log-leak.sh --install    # the above, plus a 15-minute timer
set -euo pipefail

# Overridable so this is not welded to one account's home directory.
MM="${MM_DIR:-$HOME/MagicMirror}"
CFG="$MM/config/config.js"
LOGS="${PM2_LOGS:-$HOME/.pm2/logs}"

log() { echo "[fix-mm-logs] $*"; }

# --- 1. stop emitting -------------------------------------------------------
if grep -q 'logLevel: \["INFO"' "$CFG"; then
  cp -p "$CFG" "$CFG.bak-logfix-$(date +%Y%m%d%H%M%S)"
  # Keeping WARN and ERROR: those are what a failure looks like, and they do
  # not routinely carry the URL. To debug a fetch, re-add "INFO" TEMPORARILY
  # and purge the logs afterwards.
  sed -i 's/logLevel: \["INFO", "LOG", "WARN", "ERROR"\]/logLevel: ["WARN", "ERROR"]/' "$CFG"
  log "logLevel reduced to WARN+ERROR"
else
  log "logLevel already reduced"
fi

# --- 2. purge what is already on disk ---------------------------------------
# Rewriting in place rather than deleting: the operational history is worth
# keeping, the credentials in it are not.
n=0
while IFS= read -r -d '' f; do
  if grep -q "private-[a-f0-9]\{16,\}" "$f" 2>/dev/null; then
    sed -i 's#\(calendar/ical/\)[^ ]*#\1<REDACTED>#g; s#private-[a-f0-9]\{16,\}#private-<REDACTED>#g' "$f"
    n=$((n+1))
  fi
done < <(find "$LOGS" -name '*.log' -print0)
log "redacted secrets in $n log file(s)"

# --- 3. lock the directory, so future files are covered too -----------------
chmod 700 "$LOGS"
find "$LOGS" -name '*.log' -exec chmod 600 {} +
log "$LOGS is now 700, logs 600"

# --- 4. lock the config, which holds the same URLs --------------------------
chmod 600 "$CFG"
chmod 600 "$MM"/config/config.js.bak-* 2>/dev/null || true
log "config.js and its backups are now 600"

# --- verify ------------------------------------------------------------------
# `|| true`: grep exits 1 when it finds nothing, which is exactly the outcome
# being hoped for. Under `set -o pipefail` that aborted the script at the
# moment it had succeeded.
left=$(grep -rho "private-[a-f0-9]\{16,\}" "$LOGS" 2>/dev/null | sort -u | wc -l || true)
left=${left:-0}
log "secret keys remaining in logs: $left"
[ "$left" -eq 0 ] || { echo "[fix-mm-logs] ERROR: secrets still present" >&2; exit 1; }


# --- optional: keep doing it -------------------------------------------------
if [ "${1:-}" = "--install" ]; then
  UNIT_DIR="$HOME/.config/systemd/user"
  SELF="$(readlink -f "$0")"
  mkdir -p "$UNIT_DIR"

  cat > "$UNIT_DIR/mm-log-redact.service" <<EOF
[Unit]
Description=Redact secret calendar URLs from MagicMirror logs

[Service]
Type=oneshot
ExecStart=$SELF
EOF

  cat > "$UNIT_DIR/mm-log-redact.timer" <<EOF
[Unit]
Description=Re-redact MagicMirror logs every 15 minutes

[Timer]
# Bounds how long an ERROR-level leak can sit on disk. It cannot prevent the
# write -- only the log level could, and ERROR must stay on.
OnCalendar=*:3/15
Persistent=true
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now mm-log-redact.timer >/dev/null
  # Without lingering, user timers die when the ssh session ends.
  loginctl enable-linger "$USER" >/dev/null 2>&1 || true
  log "timer installed:"
  systemctl --user list-timers mm-log-redact.timer --no-pager | head -3
fi
