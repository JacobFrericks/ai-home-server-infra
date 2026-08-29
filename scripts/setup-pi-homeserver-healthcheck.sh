#!/usr/bin/env bash
# Calendar Pi watchdog for HomeServer -> LAN-only ntfy on the Pi itself.
# Idempotent. Safe to re-run. Contains no secrets: the topic is generated on
# first run and kept in /etc/homeserver-healthcheck.conf (root:hscheck 0640).
set -euo pipefail

NTFY_PORT="8090"
LAN_CIDR="192.168.86.0/24"
CHECK_EVERY="5min"      # normal polling cadence
REMIND_SECS="3600"      # while broken, re-nag the phone this often
FAIL_THRESHOLD="2"      # consecutive bad checks before the first alert
RUN_USER="hscheck"
CONF="/etc/homeserver-healthcheck.conf"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 1; fi

echo "==> 0/7 config + secret topic"
# Only the secret topic survives a re-run; all other settings re-derive from
# the tunables above, so editing this script and re-running actually takes effect.
# Precedence: an explicitly supplied TOPIC beats the existing conf, which beats a
# freshly generated one.
#
# The env override is the whole reason a REBUILD is reproducible. Grafana's ntfy
# contact point (in the PRIVATE k8s repo) names this topic literally, and ntfy
# runs auth-default-access=deny-all -- so a fresh SD card that generated a NEW
# random topic would leave Grafana publishing to a topic ntfy rejects with 403.
# Alerts would stop dead and nothing on the phone would say so. When rebuilding
# this Pi, pass the topic the server already knows:
#   sudo TOPIC="homeserver-xxxxxxxxxx" ./setup-pi-homeserver-healthcheck.sh
# Recover it from the old conf, or from the contact point URL in the k8s repo.
TOPIC="${TOPIC:-}"
[ -n "$TOPIC" ] || TOPIC="$(sed -n 's/^TOPIC="\(.*\)"$/\1/p' "$CONF" 2>/dev/null | head -1)"
TOPIC="${TOPIC:-homeserver-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 10)}"
TARGET_HOST="192.168.86.63"
TARGET_NAME="HomeServer"
HEALTH_URL="http://192.168.86.63:3000/api/health"

echo "==> 1/7 dedicated unprivileged user '${RUN_USER}'"
getent passwd "$RUN_USER" >/dev/null || \
  useradd --system --no-create-home --shell /usr/sbin/nologin "$RUN_USER"

umask 077
cat > "$CONF" <<EOF
# Managed by setup-homeserver-healthcheck.sh. Contains the ntfy topic, which is
# the ONLY access control on the alert channel. Keep this file 0640 root:${RUN_USER}.
TOPIC="${TOPIC}"
TARGET_HOST="${TARGET_HOST}"
TARGET_NAME="${TARGET_NAME}"
HEALTH_URL="${HEALTH_URL}"
FAIL_THRESHOLD="${FAIL_THRESHOLD}"
REMIND_SECS="${REMIND_SECS}"
NTFY_URL="http://127.0.0.1:${NTFY_PORT}/${TOPIC}"
EOF
chown "root:${RUN_USER}" "$CONF"; chmod 0640 "$CONF"
umask 022

echo "==> 2/7 install ntfy"
if ! command -v ntfy >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://archive.ntfy.sh/apt/keyring.gpg -o /etc/apt/keyrings/archive.ntfy.sh.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/archive.ntfy.sh.gpg] https://archive.ntfy.sh/apt stable main" \
    > /etc/apt/sources.list.d/archive.ntfy.sh.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ntfy
else
  echo "    already installed"
fi

echo "==> 3/7 configure ntfy (deny-all by default)"
install -d -m 0755 /etc/ntfy
install -d -m 0750 -o ntfy -g ntfy /var/cache/ntfy /var/lib/ntfy
cat > /etc/ntfy/server.yml <<EOF
# Managed by setup-homeserver-healthcheck.sh - edits will be overwritten.
base-url: "http://calendar-pi.local:${NTFY_PORT}"
listen-http: ":${NTFY_PORT}"
cache-file: "/var/cache/ntfy/cache.db"
cache-duration: "48h"
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
behind-proxy: false
enable-signup: false
enable-login: false
upstream-base-url: ""
EOF
chmod 0644 /etc/ntfy/server.yml
systemctl enable ntfy >/dev/null 2>&1
systemctl restart ntfy
for _ in $(seq 1 20); do curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${NTFY_PORT}/v1/health" && break; sleep 0.5; done

# deny-all means anonymous gets nothing until we grant exactly one topic.
ntfy access everyone "$TOPIC" read-write >/dev/null
chown ntfy:ntfy /var/lib/ntfy/user.db /var/cache/ntfy/cache.db 2>/dev/null || true
chmod 0600 /var/lib/ntfy/user.db /var/cache/ntfy/cache.db 2>/dev/null || true
systemctl restart ntfy
for _ in $(seq 1 20); do curl -fsS -m 2 -o /dev/null "http://127.0.0.1:${NTFY_PORT}/v1/health" && break; sleep 0.5; done

echo "==> 4/7 open port ${NTFY_PORT} to the LAN only (ufw)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
  ufw allow from ${LAN_CIDR} to any port ${NTFY_PORT} proto tcp comment "ntfy (LAN only)" >/dev/null
  echo "    allowed ${LAN_CIDR} -> ${NTFY_PORT}/tcp"
else
  echo "    ufw not active, nothing to open"
fi

echo "==> 5/7 install healthcheck script"
cat > /usr/local/bin/homeserver-healthcheck.sh <<'EOF'
#!/usr/bin/env bash
# Managed by setup-homeserver-healthcheck.sh - edits will be overwritten.
#
# STATE_FILE holds the last state we SUCCESSFULLY DELIVERED to the phone.
# It is only advanced after curl exits 0, so a failed send is retried on the
# next tick instead of being silently marked as done. While the state is bad,
# a reminder is re-sent every REMIND_SECS until it recovers.
set -uo pipefail

. /etc/homeserver-healthcheck.conf

STATE_DIR="/var/lib/homeserver-healthcheck"
STATE_FILE="$STATE_DIR/state"
FAIL_FILE="$STATE_DIR/fails"
SINCE_FILE="$STATE_DIR/down_since"
SINCE_TS_FILE="$STATE_DIR/down_since_ts"
LAST_FILE="$STATE_DIR/last_notify_ts"   # epoch of the last SUCCESSFUL send

log() { logger -t homeserver-healthcheck -- "$*"; }

downtime() {  # human-readable time since it first went bad
  local start now mins
  start="$(cat "$SINCE_TS_FILE" 2>/dev/null || echo 0)"
  [ "$start" -eq 0 ] 2>/dev/null && { echo "an unknown time"; return; }
  now="$(date +%s)"; mins=$(( (now - start) / 60 ))
  if [ "$mins" -lt 60 ]; then echo "${mins}m"; else echo "$(( mins / 60 ))h $(( mins % 60 ))m"; fi
}

notify() {  # notify <title> <priority> <tags> <body>  -> exit status of curl
  curl -fsS -m 10 \
    -H "Title: $1" -H "Priority: $2" -H "Tags: $3" \
    -d "$4" "$NTFY_URL" >/dev/null 2>&1
}

alive() {  # no privileges needed: plain TCP connect, ping only as a bonus
  timeout 4 bash -c "cat </dev/null >/dev/tcp/${TARGET_HOST}/22" 2>/dev/null && return 0
  ping -c 1 -W 3 "$TARGET_HOST" >/dev/null 2>&1
}

prev="$(cat "$STATE_FILE" 2>/dev/null || echo UP)"
fails="$(cat "$FAIL_FILE" 2>/dev/null || echo 0)"

if curl -fsS -m 8 -o /dev/null "$HEALTH_URL"; then
  now="UP";       detail="Everything is answering."
elif alive; then
  now="DEGRADED"; detail="The machine is up, but its services do not respond."
else
  now="OFFLINE";  detail="No reply at all. It is powered off, or off the network."
fi

if [ "$now" = "UP" ]; then fails=0; else fails=$(( fails + 1 )); fi
echo "$fails" > "$FAIL_FILE"

# What should the phone currently believe? Only change our story once we have
# seen the same bad reading FAIL_THRESHOLD times in a row.
if [ "$now" = "UP" ]; then
  desired="UP"
elif [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
  desired="$now"
else
  desired="$prev"
fi

nowts="$(date +%s)"
last="$(cat "$LAST_FILE" 2>/dev/null || echo 0)"

if [ "$desired" != "$prev" ]; then
  kind="change"
elif [ "$desired" != "UP" ] && [ $(( nowts - last )) -ge "$REMIND_SECS" ]; then
  kind="reminder"
else
  exit 0
fi

if [ "$desired" = "UP" ]; then
  since="$(cat "$SINCE_FILE" 2>/dev/null || echo unknown)"
  if notify "$TARGET_NAME is back" "default" "white_check_mark" \
       "Recovered at $(date '+%H:%M on %a %d %b'). It was $prev for $(downtime), since $since."; then
    echo UP > "$STATE_FILE"; echo "$nowts" > "$LAST_FILE"
    rm -f "$SINCE_FILE" "$SINCE_TS_FILE"
    log "delivered recovery notice (was $prev)"
  else
    log "ALERT DELIVERY FAILED (recovery, was $prev) - will retry next tick"
  fi
  exit 0
fi

if [ ! -f "$SINCE_FILE" ]; then
  date '+%H:%M on %a %d %b' > "$SINCE_FILE"
  echo "$nowts" > "$SINCE_TS_FILE"
fi
if [ "$desired" = "OFFLINE" ]; then tags="rotating_light"; else tags="warning"; fi

if [ "$kind" = "reminder" ]; then
  title="$TARGET_NAME is STILL $desired"
  body="$detail Down for $(downtime) now, since $(cat "$SINCE_FILE")."
else
  title="$TARGET_NAME is $desired"
  body="$detail (checked $fails times in a row, $(date '+%H:%M'))"
fi

if notify "$title" "high" "$tags" "$body"; then
  echo "$desired" > "$STATE_FILE"; echo "$nowts" > "$LAST_FILE"
  log "delivered $desired $kind"
else
  log "ALERT DELIVERY FAILED ($desired $kind) - will retry next tick"
fi
EOF
chown "root:${RUN_USER}" /usr/local/bin/homeserver-healthcheck.sh
chmod 0750 /usr/local/bin/homeserver-healthcheck.sh

install -d -m 0750 -o "$RUN_USER" -g "$RUN_USER" /var/lib/homeserver-healthcheck
chown -R "${RUN_USER}:${RUN_USER}" /var/lib/homeserver-healthcheck

echo "==> 6/7 install hardened systemd units"
cat > /etc/systemd/system/homeserver-healthcheck.service <<EOF
[Unit]
Description=Check that ${TARGET_NAME} is alive, push to local ntfy if not
After=network-online.target ntfy.service
Wants=network-online.target

[Service]
Type=oneshot
User=${RUN_USER}
Group=${RUN_USER}
ExecStart=/usr/local/bin/homeserver-healthcheck.sh
TimeoutStartSec=45
StateDirectory=homeserver-healthcheck
StateDirectoryMode=0750
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=
EOF
cat > /etc/systemd/system/homeserver-healthcheck.timer <<EOF
[Unit]
Description=Run the HomeServer healthcheck every ${CHECK_EVERY}

[Timer]
OnBootSec=2min
OnUnitActiveSec=${CHECK_EVERY}
AccuracySec=10s
Unit=homeserver-healthcheck.service

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now homeserver-healthcheck.timer >/dev/null 2>&1
systemctl restart homeserver-healthcheck.timer

echo "==> 7/7 first run"
systemctl start homeserver-healthcheck.service || true
sleep 2
echo
echo "ntfy:    $(systemctl is-active ntfy)"
echo "timer:   $(systemctl is-active homeserver-healthcheck.timer)"
echo "last run:$(systemctl show -p Result --value homeserver-healthcheck.service)"
echo "state:   $(cat /var/lib/homeserver-healthcheck/state 2>/dev/null || echo '(UP, nothing written yet)')"
echo "topic:   ${TOPIC}"
echo "url:     http://calendar-pi.local:${NTFY_PORT}"
