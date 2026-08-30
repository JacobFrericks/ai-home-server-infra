#!/usr/bin/env bash
# setup-ha-location-weather.sh — weather WHERE THE PHONE IS, not where the house
# is. Idempotent; safe to re-run.
#
#   ./scripts/setup-ha-location-weather.sh --check     # read-only (DEFAULT)
#   ./scripts/setup-ha-location-weather.sh --apply
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# setup-ha-weather.sh added met.no, which is pinned to the HOME coordinates. Ask
# it for the weather from the office and it confidently answers about the house.
#
# The model cannot fix that itself: the HA MCP tool hands it entity STATES, so
# the phone tracker reads as the bare word "home" or "not_home" with no
# coordinates attached. Nothing in that chain carries a latitude.
#
# So do the lookup inside HA instead. A rest sensor with a resource_template
# re-renders its URL on every poll, which means it follows the companion app's
# live GPS. open-meteo needs no API key and no account. The sensor's STATE is a
# plain English sentence rather than a number, because the state is the only
# part the model reliably sees.
#
# Coordinates leave the house on each poll, to open-meteo. That is the same
# trade already made for met.no, which sends the home coordinates.
#
# Sibling scripts: setup-ha-weather.sh (home forecast), setup-assist-location.sh
# (exposes entities to Assist, and is reused here for exposure).
set -euo pipefail

die() { printf "[loc-weather] ERROR: %s\n" "$*" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG=/home/jacob/Documents/homeassistant/configuration.yaml
ENTITY=sensor.weather_at_my_location
TRACKER=device_tracker.jacob_s_phone
MARK_BEGIN="# >>> weather-at-my-location (managed by setup-ha-location-weather.sh) >>>"
KUBECTL="sudo k3s kubectl"

HA_TOKEN="$($KUBECTL -n monitoring get secret ha-scrape-token \
  -o jsonpath='{.data.ha_token}' 2>/dev/null | base64 -d | tr -d '\r\n')"
[ -n "$HA_TOKEN" ] || die "no HA token in secret monitoring/ha-scrape-token"
export HA_TOKEN ENTITY TRACKER

MODE="${1:---check}"
case "$MODE" in --check|--apply) ;; *) die "usage: $0 [--check|--apply]" ;; esac

# --- 1. the YAML ----------------------------------------------------------
if [ "$MODE" = --apply ] && ! grep -qF "$MARK_BEGIN" "$CONFIG"; then
  # HA owns this file as root; the container writes it too.
  sudo cp -a "$CONFIG" "$CONFIG.bak-locweather-$(date +%Y%m%d%H%M%S)"
  sudo tee -a "$CONFIG" >/dev/null <<'YAML'

# >>> weather-at-my-location (managed by setup-ha-location-weather.sh) >>>
# Follows the phone's live GPS, falling back to the home zone when the tracker
# has no fix. State is a sentence on purpose: the assistant model reads entity
# states, not attributes.
rest:
  - resource_template: >-
      https://api.open-meteo.com/v1/forecast?latitude={{ state_attr('device_tracker.jacob_s_phone','latitude') | default(state_attr('zone.home','latitude'), true) }}&longitude={{ state_attr('device_tracker.jacob_s_phone','longitude') | default(state_attr('zone.home','longitude'), true) }}&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m,relative_humidity_2m&temperature_unit=fahrenheit&wind_speed_unit=mph
    scan_interval: 300
    sensor:
      - name: Weather At My Location
        unique_id: weather_at_my_location_gps
        value_template: >-
          {% set c = value_json.current %}
          {% set codes = {0:'clear',1:'mainly clear',2:'partly cloudy',3:'overcast',45:'foggy',48:'foggy',51:'light drizzle',53:'drizzle',55:'heavy drizzle',56:'freezing drizzle',57:'freezing drizzle',61:'light rain',63:'rain',65:'heavy rain',66:'freezing rain',67:'freezing rain',71:'light snow',73:'snow',75:'heavy snow',77:'snow grains',80:'rain showers',81:'rain showers',82:'heavy rain showers',85:'snow showers',86:'snow showers',95:'thunderstorm',96:'thunderstorm with hail',99:'thunderstorm with hail'} %}
          {{ codes.get(c.weather_code | int, 'unclear conditions') }}, {{ c.temperature_2m | round }}F, feels like {{ c.apparent_temperature | round }}F, humidity {{ c.relative_humidity_2m | round }}%, wind {{ c.wind_speed_10m | round }} mph
# <<< weather-at-my-location <<<
YAML
  echo "  appended rest sensor to configuration.yaml"

  # YAML platforms need a reload; rest.reload avoids a full HA restart.
  HA_RELOAD=1 python3 - <<'PY'
import json, os, urllib.request
HDR = {"Authorization": "Bearer " + os.environ["HA_TOKEN"],
       "Content-Type": "application/json"}
req = urllib.request.Request("http://127.0.0.1:8123/api/services/rest/reload",
                             data=b"{}", headers=HDR, method="POST")
try:
    urllib.request.urlopen(req, timeout=60)
    print("  reloaded rest entities")
except Exception as e:
    print("  rest.reload failed (%s); restarting HA" % e)
    req = urllib.request.Request(
        "http://127.0.0.1:8123/api/services/homeassistant/restart",
        data=b"{}", headers=HDR, method="POST")
    try:
        urllib.request.urlopen(req, timeout=120)
    except Exception as e2:
        print("  restart call failed:", e2)
PY
fi

# --- 2. did the sensor actually come up? ----------------------------------
python3 <<'PY'
import json, os, sys, time, urllib.request
HDR = {"Authorization": "Bearer " + os.environ["HA_TOKEN"]}
ENTITY, TRACKER = os.environ["ENTITY"], os.environ["TRACKER"]

def state(eid):
    req = urllib.request.Request("http://127.0.0.1:8123/api/states/" + eid, headers=HDR)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())
    except Exception:
        return None

# A fresh rest sensor needs a poll cycle before it holds a value.
for _ in range(24):
    s = state(ENTITY)
    if s and s["state"] not in ("unknown", "unavailable", None):
        break
    time.sleep(5)

s = state(ENTITY)
if not s:
    print("  %s does not exist" % ENTITY); sys.exit(1)
print("  %s = %s" % (ENTITY, s["state"]))

t = state(TRACKER)
if t:
    a = t["attributes"]
    print("  %s = %s (gps fix: %s)" % (TRACKER, t["state"], bool(a.get("latitude"))))
if s["state"] in ("unknown", "unavailable"):
    sys.exit(1)
PY

# --- 3. let Assist read it ------------------------------------------------
ENTITIES="$ENTITY" "$HERE/setup-assist-location.sh" "$MODE"
