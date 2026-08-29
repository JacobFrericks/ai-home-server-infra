#!/usr/bin/env bash
# setup-ha-weather.sh — give Home Assistant a real weather source, and let the
# assistant model read it. Idempotent; safe to re-run.
#
#   ./scripts/setup-ha-weather.sh --check     # read-only (DEFAULT)
#   ./scripts/setup-ha-weather.sh --apply
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# "What is the weather?" had no good answer. Two gaps stacked up:
#
#   1. HA had NO weather integration at all (zero weather.* entities).
#   2. The HA MCP tool hands the model only entity STATES. For the phone
#      tracker that is the bare word "home" — no coordinates. The model cannot
#      turn a zone name into a place to search for, so it correctly said it did
#      not know where the user is.
#
# Met.no needs no API key and no account, and reads the coordinates already
# configured as the HA home zone. Exposing the weather entity to Assist means
# the model answers from real forecast data instead of a web search guessing the
# location from the house IP address.
#
# Builds on setup-assist-location.sh, which exposes the phone tracker.
set -euo pipefail

die() { printf "[ha-weather] ERROR: %s\n" "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
KUBECTL="sudo k3s kubectl"

HA_TOKEN="$($KUBECTL -n monitoring get secret ha-scrape-token \
  -o jsonpath='{.data.ha_token}' 2>/dev/null | base64 -d | tr -d '\r\n')"
[ -n "$HA_TOKEN" ] || die "no HA token in secret monitoring/ha-scrape-token"
export HA_TOKEN

MODE="${1:---check}"
case "$MODE" in --check|--apply) ;; *) die "usage: $0 [--check|--apply]" ;; esac

# --- 1. the weather integration itself ------------------------------------
ents="$(MODE="$MODE" python3 <<'PY'
import json, os, sys, time, urllib.request

HA   = "http://127.0.0.1:8123"
HDR  = {"Authorization": "Bearer " + os.environ["HA_TOKEN"],
        "Content-Type": "application/json"}
MODE = os.environ["MODE"]

def call(path, data=None):
    req = urllib.request.Request(
        HA + path,
        data=None if data is None else json.dumps(data).encode(),
        headers=HDR,
        method="GET" if data is None else "POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or "{}")

def weather():
    return [e for e in call("/api/states") if e["entity_id"].startswith("weather.")]

def met_entry():
    try:
        return [e for e in call("/api/config/config_entries/entry")
                if e.get("domain") == "met"]
    except Exception:
        return []

# Adding twice returns already_configured, and an entry can exist while its
# entity does not (met sits in setup_retry whenever egress is broken).
if MODE == "--apply" and not weather() and not met_entry():
    flow = call("/api/config/config_entries/flow",
                {"handler": "met", "show_advanced_options": False})
    if flow.get("type") != "form":
        print("  could not start met flow:", flow, file=sys.stderr); sys.exit(1)
    d = {f["name"]: f.get("default") for f in flow["data_schema"]}
    # Met.no defaults to the coordinates already set as the HA home zone.
    res = call("/api/config/config_entries/flow/" + flow["flow_id"],
               {"name": "Home", "latitude": d["latitude"],
                "longitude": d["longitude"], "elevation": d.get("elevation") or 0})
    if res.get("type") != "create_entry":
        print("  met setup failed:", res.get("errors") or res, file=sys.stderr); sys.exit(1)
    print("  added Met.no integration", file=sys.stderr)
    time.sleep(6)

es = weather()
if not es:
    print("  no weather entity in HA", file=sys.stderr); sys.exit(1)
for e in es:
    a = e["attributes"]
    print("  %s = %s | %s%s | humidity %s%%"
          % (e["entity_id"], e["state"], a.get("temperature"),
             a.get("temperature_unit"), a.get("humidity")), file=sys.stderr)
print(",".join(e["entity_id"] for e in es))
PY
)" || die "weather step failed"

# --- 2. let Assist (and so the model) read it -----------------------------
# Exposure is websocket-only in HA; the sibling script already speaks it.
ENTITIES="$(printf '%s' "$ents" | tr ',' ' ')" \
  "$HERE/setup-assist-location.sh" "$MODE"
