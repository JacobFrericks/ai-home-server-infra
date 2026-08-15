#!/usr/bin/env bash
#
# setup-wyze.sh — install the vendored Wyze integration into Home Assistant.
#
# Idempotent: re-running re-syncs the component from the repo and restarts HA,
# so this is the "start over" button. Run it AFTER deploy.sh has brought the
# stack up. It:
#   1. syncs homeassistant/custom_components/wyzeapi/ into the live HA config
#   2. quiets the camera logger that leaks AWS credentials into the logs
#   3. restarts HA so the component loads (and pip-installs wyzeapy on boot)
#   4. reports whether a Wyze config entry already exists
#
# WHY THIS IS NEEDED AT ALL: Wyze bulbs speak no local protocol (no mDNS/SSDP/
# Matter), so HA's auto-discovery will never find them even though they sit on
# the LAN. The only route is Wyze's unofficial cloud API. See the "Important
# caveats" section of homeassistant/custom_components/wyzeapi/VENDORED.md.
#
# CREDENTIALS ARE NOT HANDLED HERE, BY DESIGN. This repo is public. Finish the
# setup once, by hand, in the HA UI (the script prints instructions).
#
# Env overrides: HA_CONFIG_DIR (default /home/jacob/Documents/homeassistant).
# Requires: docker (jacob is in the docker group). No sudo needed.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

log() { echo "[setup-wyze $(date +%H:%M:%S)] $*"; }

HA_CFG="${HA_CONFIG_DIR:-/home/jacob/Documents/homeassistant}"
SRC="homeassistant/custom_components/wyzeapi"

[ -d "$SRC" ] || { log "ERROR: vendored component missing at $SRC"; exit 1; }

# --- 1. sync the vendored component -----------------------------------------
log "installing vendored wyzeapi component into ${HA_CFG}/custom_components..."
mkdir -p "$HA_CFG/custom_components"
rm -rf "$HA_CFG/custom_components/wyzeapi"
cp -r "$SRC" "$HA_CFG/custom_components/"
# Vendoring notes are repo bookkeeping; don't ship them into the live config.
rm -f "$HA_CFG/custom_components/wyzeapi/VENDORED.md"
find "$HA_CFG/custom_components/wyzeapi" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
log "installed version $(python3 -c "import json;print(json.load(open('$SRC/manifest.json'))['version'])")"

# --- 2. quiet the credential-leaking camera logger ---------------------------
# The camera platform logs Wyze's full get_stream_info response on a failed
# config fetch (routine for offline cameras) — that payload carries live AWS
# credentials, a JWT, and TURN passwords into home-assistant.log and Loki.
# See the docstring in scripts/ha-wyze-logging.py. Idempotent.
log "ensuring wyzeapi.camera logger is quieted in configuration.yaml..."
docker cp scripts/ha-wyze-logging.py homeassistant:/tmp/ha-wyze-logging.py >/dev/null
docker exec homeassistant python3 /tmp/ha-wyze-logging.py

# --- 3. restart HA -----------------------------------------------------------
log "restarting HA to load the component (first boot also pip-installs wyzeapy)..."
docker restart homeassistant >/dev/null

log "waiting for HA to come back (timeout 180s)..."
waited=0
until curl -fsS -o /dev/null --max-time 5 http://127.0.0.1:8123/ 2>/dev/null; do
  sleep 5; waited=$((waited + 5))
  if [ "$waited" -ge 180 ]; then log "ERROR: HA not ready after 180s"; exit 1; fi
done

# Component import happens after the HTTP server is up; give it a moment before
# grepping the log, otherwise a clean load looks like a missing load.
sleep 20

# --- 4. report load + config-entry status ------------------------------------
if docker logs homeassistant --since 3m 2>&1 | grep -qiE 'wyzeapi.*(error|traceback|failed)'; then
  log "WARNING: wyzeapi errors in the HA log:"
  docker logs homeassistant --since 3m 2>&1 | grep -iE 'wyzeapi' | tail -20
fi

ENTRIES="$HA_CFG/.storage/core.config_entries"
if [ -r "$ENTRIES" ] && grep -q '"domain": "wyzeapi"' "$ENTRIES"; then
  log "a Wyze config entry already exists — nothing further to do."
else
  cat <<'EOM'

  ─────────────────────────────────────────────────────────────────────
  Component installed. One manual step remains (credentials, on purpose):

    1. Generate a Key ID + API Key at
         https://developer-api-console.wyze.com/
    2. In HA: Settings -> Devices & Services -> Add Integration -> "Wyze"
    3. Enter Wyze email, password, Key ID, API Key.

  Bulbs then appear as light entities with brightness + color temperature.
  Credentials are stored only in HA's .storage, never in this repo.
  ─────────────────────────────────────────────────────────────────────

EOM
fi

log "done. Verify with: scripts/verify-services.sh"
