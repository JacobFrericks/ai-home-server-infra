#!/usr/bin/env bash
#
# setup-fridge-brief.sh — install the timers that keep the fridge panel fed.
#
# Idempotent. Run again to update the units after changing this file.
#
# ---------------------------------------------------------------------------
# TWO TIMERS, NOT ONE. DO NOT COLLAPSE THEM.
# ---------------------------------------------------------------------------
#   fridge-brief.timer       every 15 min  -- calendar, tasks, HA. Mail comes
#                                             from a local cache; no IMAP.
#   fridge-brief-mail.timer  every 60 min  -- the only thing that opens IMAP.
#
# The split exists because polling Gmail every 15 minutes is ~96 automated
# logins a day from a server IP, and an app password on this account has
# already been revoked once. Google reads that pattern as a compromised
# account, and the failure surfaces as "Invalid credentials" -- indistinguish-
# able from a wrong password, so it costs an hour of debugging rather than a
# retry. Nothing here needs minute-level freshness: the panel itself only
# re-reads its file every 10 minutes.
#
# WHY systemd RATHER THAN cron: cron gives no lock, no timeout, no record of
# whether the last run succeeded. `systemctl status` answers all three, and
# Persistent=true catches up a run missed while the box was down.
#
# Requires: the credentials at ~/docker/ai-stack/.env.family (0600) and the
# restricted ssh key ~/.ssh/brief_to_pi. Creates neither -- see the family-AI
# setup notes.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
STACK_DIR="$(pwd)"

# Where the panel lives. Override in the environment; the default is a
# placeholder, since a real hostname is deployment-identifying and this repo
# is public.
PI_HOST="${PI_HOST:-display-pi.local}"
PI_USER="${PI_USER:-$USER}"

log() { echo "[fridge-brief $(date +%H:%M:%S)] $*"; }
die() { echo "[fridge-brief] ERROR: $*" >&2; exit 1; }

[ -s "$STACK_DIR/.env.family" ] || die "missing .env.family -- credentials not provisioned"
[ -s "$HOME/.ssh/brief_to_pi" ] || die "missing ~/.ssh/brief_to_pi -- push key not provisioned"
[ -x "$STACK_DIR/brief/fetch_live.py" ] || chmod +x "$STACK_DIR/brief/fetch_live.py"

RUNNER=/usr/local/bin/fridge-brief-run
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

log "installing runner..."
TMP=$(mktemp)
cat > "$TMP" <<RUNNER_EOF
#!/usr/bin/env bash
# Generate brief.json and push it to the Pi. \$1 = "mail" to force an IMAP refresh.
set -uo pipefail
STACK_DIR="$STACK_DIR"
PI_TARGET="$PI_USER@$PI_HOST"
LOG=\$HOME/fridge-brief.log
OUT=\$(mktemp /tmp/brief.XXXXXX.json)
trap 'rm -f "\$OUT"' EXIT

# flock: a slow IMAP run must never overlap the next timer tick.
exec 9>/tmp/fridge-brief.lock
flock -n 9 || { echo "\$(date -Is) SKIP: previous run still going" >> "\$LOG"; exit 0; }

ARGS=()
[ "\${1:-}" = "mail" ] && ARGS+=(--refresh-mail)

if ! timeout 180 python3 "\$STACK_DIR/brief/fetch_live.py" "\${ARGS[@]}" -o "\$OUT" 2>>"\$LOG"; then
  echo "\$(date -Is) FAIL: fetch_live" >> "\$LOG"
  exit 1
fi

# The forced command on the far end validates the JSON before replacing the
# live file, so a malformed push cannot blank the wall.
if timeout 60 ssh -i "\$HOME/.ssh/brief_to_pi" -o BatchMode=yes \\
     -o StrictHostKeyChecking=accept-new "\$PI_TARGET" < "\$OUT" >>"\$LOG" 2>&1; then
  echo "\$(date -Is) OK \${1:-tick}" >> "\$LOG"
else
  echo "\$(date -Is) FAIL: push to pi" >> "\$LOG"
  exit 1
fi

# Keep the log from growing without bound; nothing rotates a user log.
tail -n 2000 "\$LOG" > "\$LOG.tmp" && mv "\$LOG.tmp" "\$LOG"
RUNNER_EOF
sudo install -o root -g root -m 0755 "$TMP" "$RUNNER" 2>/dev/null \
  || { RUNNER="$HOME/bin/fridge-brief-run"; mkdir -p "$HOME/bin"; install -m 0755 "$TMP" "$RUNNER"; }
rm -f "$TMP"
log "runner at $RUNNER"

log "writing units..."
cat > "$UNIT_DIR/fridge-brief.service" <<EOF
[Unit]
Description=Build the fridge brief and push it to the calendar Pi
After=network-online.target

[Service]
Type=oneshot
ExecStart=$RUNNER
EOF

cat > "$UNIT_DIR/fridge-brief.timer" <<EOF
[Unit]
Description=Fridge brief every 15 minutes (no IMAP -- mail comes from cache)

[Timer]
OnCalendar=*:0/15
# Catch up one run if the box was asleep, rather than waiting for the next tick.
Persistent=true
# Avoid every timer on the box firing on the same second.
RandomizedDelaySec=45

[Install]
WantedBy=timers.target
EOF

cat > "$UNIT_DIR/fridge-brief-mail.service" <<EOF
[Unit]
Description=Refresh the cached mail for the fridge brief (opens IMAP)
After=network-online.target

[Service]
Type=oneshot
ExecStart=$RUNNER mail
EOF

cat > "$UNIT_DIR/fridge-brief-mail.timer" <<EOF
[Unit]
Description=Fridge brief mail refresh, hourly -- the ONLY thing that opens IMAP

[Timer]
# :07 rather than :00 so it does not collide with the 15-minute tick.
OnCalendar=*:07
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now fridge-brief.timer fridge-brief-mail.timer >/dev/null

# Without lingering, user timers stop the moment the ssh session closes.
loginctl enable-linger "$USER" >/dev/null 2>&1 || true

log "done. Timers:"
systemctl --user list-timers 'fridge-brief*' --no-pager | head -5
