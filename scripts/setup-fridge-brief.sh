#!/usr/bin/env bash
#
# setup-fridge-brief.sh — install the timers that keep the fridge panel fed.
#
# Idempotent. Run again to update the units after changing this file.
#
# ---------------------------------------------------------------------------
# TWO TIMERS, NOT ONE. DO NOT COLLAPSE THEM.
# ---------------------------------------------------------------------------
#   fridge-mail-idle.service  always on   -- holds ONE IMAP IDLE connection and
#                                            reacts the moment mail arrives.
#   fridge-brief.timer        every 15 min -- calendar, tasks, HA. No IMAP.
#   fridge-brief-mail.timer   every 3 h    -- BACKSTOP only, now that IDLE does
#                                            the reacting. Deliberately not
#                                            removed: a daemon that dies quietly
#                                            is indistinguishable from a quiet
#                                            mailbox, and this bounds that to
#                                            hours-late rather than never.
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

# Attachment reading is poppler's. Checked here rather than discovered at 6am:
# without it a PDF newsletter silently contributes nothing and the wall just
# looks like a quiet week.
command -v pdftotext >/dev/null \
  || die "pdftotext not found -- install poppler-utils (apt-get install -y poppler-utils)"
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

# Watchdog: the IDLE daemon's only evidence of life is the age of its
# heartbeat. Checked here rather than in a separate unit, because this already
# runs every 15 minutes and a watchdog that needs its own watchdog is worse.
HB=/tmp/brief-idle-heartbeat
if [ -f "\$HB" ]; then
  AGE=\$(( \$(date +%s) - \$(stat -c %Y "\$HB") ))
  # The daemon touches it at least every renewal (24 min) and on reconnect.
  if [ "\$AGE" -gt 2400 ]; then
    echo "\$(date -Is) WARN: IDLE heartbeat is \${AGE}s old -- watcher may be dead" >> "\$LOG"
  fi
else
  echo "\$(date -Is) WARN: no IDLE heartbeat file -- watcher never started" >> "\$LOG"
fi

ARGS=()
if [ "\${1:-}" = "mail" ]; then
  ARGS+=(--refresh-mail)
  # The AI step runs ONLY here, on the hourly tick, and only when there is
  # unread mail (extract.py exits immediately otherwise). gemma4:26b is 17 GB;
  # calling it every 15 minutes would risk evicting the chat model and buy no
  # freshness -- the panel re-reads its file every 10 minutes anyway.
  # Failure is non-fatal: the brief is still built and pushed without it.
  timeout 900 python3 "\$STACK_DIR/brief/extract.py" \\
      --headline-out /tmp/brief-headline.txt >>"\$LOG" 2>&1 \\
    || echo "\$(date -Is) WARN: extract failed (brief still built)" >> "\$LOG"
fi

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
Description=Fridge brief mail BACKSTOP every 3h -- IDLE does the reacting

[Timer]
# :07 rather than :00 so it does not collide with the 15-minute tick.
# Was hourly; IDLE now handles arrival, so this is a safety net rather than
# the mechanism. Three hours is "if the daemon is dead, mail is late, not lost".
OnCalendar=00/3:07
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF

# --- the IDLE watcher ---------------------------------------------------------
cat > "$UNIT_DIR/fridge-mail-idle.service" <<EOF
[Unit]
Description=Watch the bot mailbox with IMAP IDLE and react on arrival
After=network-online.target
# StartLimit* belong in [Unit]. Put in [Service] systemd ignores them with only
# a log line, so the crash-loop backoff would silently not exist.
StartLimitIntervalSec=600
StartLimitBurst=10

[Service]
Type=simple
ExecStart=/usr/bin/python3 $STACK_DIR/brief/mail_idle.py --runner $RUNNER
# A watcher that stays dead is the failure mode that looks like silence.
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now fridge-brief.timer fridge-brief-mail.timer >/dev/null
# `daemon-reload` does not re-arm a timer sitting in the `elapsed` state: an
# edited OnCalendar is loaded but never scheduled, and `list-timers` shows
# NEXT as "-". Restarting is what actually applies a schedule change.
systemctl --user restart fridge-brief.timer fridge-brief-mail.timer
systemctl --user enable --now fridge-mail-idle.service >/dev/null

# Without lingering, user timers stop the moment the ssh session closes.
loginctl enable-linger "$USER" >/dev/null 2>&1 || true

log "done. Timers:"
systemctl --user list-timers 'fridge-brief*' --no-pager | head -5
