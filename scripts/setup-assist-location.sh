#!/usr/bin/env bash
# setup-assist-location.sh — let the OWUI "assistant" model see WHERE THE USER IS.
# Idempotent; safe to re-run.
#
#   ./scripts/setup-assist-location.sh --check     # read-only (DEFAULT)
#   ./scripts/setup-assist-location.sh --apply
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# Open WebUI / Conduit never send the phone GPS to the model. Home Assistant
# already has it, from the companion app: device_tracker.jacob_s_phone reports
# source_type=gps with ~11 m accuracy.
#
# The assistant model reaches HA through the HA MCP Server integration, and that
# integration only shows entities that are EXPOSED TO ASSIST. The tracker was not
# exposed, so "what is the weather" had no location to work with and fell back to
# the search engine guessing from the house IP.
#
# Exposure is websocket-only in HA (no REST route), so this drives
# homeassistant/expose_entity over ws://127.0.0.1:8123/api/websocket from inside
# the HA container, which already has aiohttp. The token is read from the
# existing k8s secret and never printed.
set -euo pipefail

log() { printf "[assist-location] %s\n" "$*"; }
die() { printf "[assist-location] ERROR: %s\n" "$*" >&2; exit 1; }

# Callers may override, e.g. setup-ha-weather.sh exposing the weather entity.
ENTITIES="${ENTITIES:-device_tracker.jacob_s_phone person.jacob}"

# ⚠️ NOT `sudo k3s kubectl`, and not `sudo docker` below, because sudo on this
# box PROMPTS FOR A PASSWORD. That is fine by hand and fatal everywhere else:
# verify-services.sh calls this with --check from cron and over ssh, where
# there is no tty. sudo then fails, `set -e` aborts at the ha_token assignment
# BEFORE die() can print, and the caller sees an empty string and exit 1. It
# read as "no entity exposed to Assist" -- three red checks on 2026-09-14 while
# HA was entirely healthy. A check that cannot tell "broken" from "could not
# look" is worse than no check.
#
# jacob's own kubeconfig needs no sudo, and jacob is in the docker group. This
# is the idiom verify-cluster.sh and verify-services.sh already use, and the
# reason they were green while the scripts they call were not.
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

ha_token() {
  kubectl -n monitoring get secret ha-scrape-token \
    -o jsonpath="{.data.ha_token}" 2>/dev/null | base64 -d | tr -d "\r\n"
}

run_ws() {  # $1 = mode (check|apply)
  local tok; tok="$(ha_token)"
  [ -n "$tok" ] || die "no HA token in secret monitoring/ha-scrape-token"
  docker exec -e HA_TOKEN="$tok" -e MODE="$1" -e ENTS="$ENTITIES" -i homeassistant python3 - <<"PY"
import asyncio, json, os, sys
import aiohttp

TOKEN = os.environ["HA_TOKEN"]
MODE  = os.environ["MODE"]
ENTS  = os.environ["ENTS"].split()

async def main():
    rc = 0
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect("http://127.0.0.1:8123/api/websocket") as ws:
            await ws.receive_json()                       # auth_required
            await ws.send_json({"type": "auth", "access_token": TOKEN})
            if (await ws.receive_json())["type"] != "auth_ok":
                print("  auth failed"); sys.exit(1)

            i = 0
            async def call(msg):
                nonlocal i
                i += 1
                msg["id"] = i
                await ws.send_json(msg)
                while True:
                    r = await ws.receive_json()
                    if r.get("id") == i:
                        return r

            if MODE == "apply":
                r = await call({"type": "homeassistant/expose_entity",
                                "assistants": ["conversation"],
                                "entity_ids": ENTS,
                                "should_expose": True})
                if not r.get("success"):
                    print("  expose failed:", r.get("error")); sys.exit(1)

            # Verify against what HA actually stores.
            r = await call({"type": "homeassistant/expose_entity/list"})
            exposed = (r.get("result") or {}).get("exposed_entities", {})
            for e in ENTS:
                on = bool(((exposed.get(e) or {}).get("conversation")))
                print(f"  {e}: exposed_to_assist={on}")
                if not on:
                    rc = 1
    sys.exit(rc)

asyncio.run(main())
PY
}

case "${1:---check}" in
  --check) run_ws check ;;
  --apply) run_ws apply ;;
  *) die "usage: $0 [--check|--apply]" ;;
esac
