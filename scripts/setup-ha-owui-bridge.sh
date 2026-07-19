#!/usr/bin/env bash
#
# setup-ha-owui-bridge.sh — let Open WebUI chat control Home Assistant.
#
# Idempotent: every step is a no-op if already done, so this is the "start over"
# button for the OWUI->HA control bridge. Run it AFTER deploy.sh. It:
#   1. enables HA's `mcp_server` integration (exposes the `assist` toolset over
#      Streamable HTTP at /api/mcp) via HA's config-flow API
#   2. mints a dedicated HA long-lived token ("Open WebUI MCP") IF Open WebUI
#      isn't already wired with a working one
#   3. adds a bearer-authed `home-assistant` MCP tool to Open WebUI and attaches
#      it to the gemma4:31b model (leaving its other tools intact)
#
# The dedicated token lives ONLY in Open WebUI's DB (no stray secret files).
# Reads the HA admin token from $HA_TOKEN or the prometheus container's
# /etc/prometheus/ha_token. Requires: docker (no sudo).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

log() { echo "[setup-ha-owui-bridge $(date +%H:%M:%S)] $*"; }

# --- HA admin token (never echoed) ------------------------------------------
admin_token() {
  if [ -n "${HA_TOKEN:-}" ]; then printf '%s' "$HA_TOKEN"; return; fi
  docker exec prometheus cat /etc/prometheus/ha_token 2>/dev/null | tr -d '\r\n'
}
ADMIN=$(admin_token)
[ -n "$ADMIN" ] || { log "ERROR: no HA admin token (set \$HA_TOKEN or provide prometheus ha_token)"; exit 1; }

# --- 1. enable HA MCP Server integration ------------------------------------
log "ensuring HA mcp_server integration (exposes assist over /api/mcp)..."
HA_TOKEN="$ADMIN" python3 scripts/ha-owui-bridge-config.py

# --- 2. wire Open WebUI (mint token only if needed) -------------------------
docker cp scripts/openwebui-ha-bridge.py open-webui:/tmp/openwebui-ha-bridge.py >/dev/null
STATE=$(docker exec open-webui python3 /tmp/openwebui-ha-bridge.py --check 2>/dev/null || echo NEEDS_TOKEN)

if [ "$STATE" = WIRED ]; then
  log "Open WebUI already wired to HA — nothing to do"
else
  log "minting dedicated HA token 'Open WebUI MCP'..."
  TOKEN=$(docker exec -e ADMIN_TOKEN="$ADMIN" -i homeassistant python3 - <<'PY'
import asyncio, aiohttp, os, sys
async def main():
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect("http://127.0.0.1:8123/api/websocket") as ws:
            await ws.receive_json()
            await ws.send_json({"type": "auth", "access_token": os.environ["ADMIN_TOKEN"]})
            if (await ws.receive_json()).get("type") != "auth_ok":
                sys.exit("HA WS auth failed")
            await ws.send_json({"id": 1, "type": "auth/long_lived_access_token",
                                "client_name": "Open WebUI MCP", "lifespan": 3650})
            r = await ws.receive_json()
            if not r.get("success"):
                sys.exit("token mint failed: %s" % r)
            sys.stdout.write(r["result"])
asyncio.run(main())
PY
)
  [ -n "$TOKEN" ] || { log "ERROR: token mint returned empty"; exit 1; }
  log "wiring Open WebUI (home-assistant tool + gemma4:31b)..."
  docker exec -e HA_MCP_TOKEN="$TOKEN" open-webui python3 /tmp/openwebui-ha-bridge.py
  docker restart open-webui >/dev/null
fi

log "done. Verify with: scripts/verify-services.sh"
