#!/usr/bin/env python3
"""The next few hours of weather for the wall, from a swappable provider.

WHY THIS IS ITS OWN MODULE
--------------------------
Home Assistant's forecast is what the house already has, so it is what this
starts on -- but it carries no precipitation PROBABILITY, which is the row a
Google-style hourly strip normally shows. Swapping in a source that has one
(Open-Meteo needs no key) should not touch the fridge, the brief document, or
any other file. So the seam is here:

  * `fetch(env)` returns a provider's RAW payload, tagged with its name. It is
    the only part that talks to the network.
  * `hours(payload, now)` turns that into the panel's vocabulary. Pure, so the
    mapping is testable without a forecast server.
  * `PROVIDERS` maps a name to that pair. A new source is one fetch function,
    one normalise function, and one line in that dict.

The panel's vocabulary is ICONS below. A provider maps its own condition names
onto those keys; nothing on the Pi changes when the provider does. `precip_pct`
is None when a provider cannot say, and the panel simply omits the row -- which
is what makes today's source usable and tomorrow's an improvement rather than a
rewrite.
"""
import json
import os
import urllib.request
from datetime import datetime, timedelta

HOURS = int(os.environ.get("WEATHER_HOURS", "5"))
PROVIDER = os.environ.get("WEATHER_PROVIDER", "homeassistant")
WEATHER_ENTITY = os.environ.get("WEATHER_ENTITY", "weather.forecast_home")

# The panel's icon vocabulary. Named for what a person sees, not for any one
# provider's taxonomy.
ICONS = {
    "sunny", "clear-night", "partly-cloudy", "partly-cloudy-night", "cloudy",
    "rain", "showers", "thunderstorm", "snow", "sleet", "hail", "fog", "windy",
}
FALLBACK_ICON = "cloudy"

# Crude but adequate for a kitchen: a provider that reports "sunny" at 3am is
# reporting a daytime condition code, not a claim about the sky. Real sunrise
# times would cost another API call and buy a few minutes of accuracy at the
# edges twice a day.
NIGHT_FROM = int(os.environ.get("WEATHER_NIGHT_FROM", "20"))
NIGHT_UNTIL = int(os.environ.get("WEATHER_NIGHT_UNTIL", "6"))

HA_ICONS = {
    "clear-night": "clear-night",
    "cloudy": "cloudy",
    "exceptional": "cloudy",
    "fog": "fog",
    "hail": "hail",
    "lightning": "thunderstorm",
    "lightning-rainy": "thunderstorm",
    "partlycloudy": "partly-cloudy",
    "pouring": "rain",
    "rainy": "showers",
    "snowy": "snow",
    "snowy-rainy": "sleet",
    "sunny": "sunny",
    "windy": "windy",
    "windy-variant": "windy",
}
NIGHT_SWAP = {"sunny": "clear-night", "partly-cloudy": "partly-cloudy-night"}


def _is_night(dt: datetime) -> bool:
    return dt.hour >= NIGHT_FROM or dt.hour < NIGHT_UNTIL


def _label(dt: datetime) -> str:
    """"8 AM", "12 PM" -- no leading zero, as the phone shows it."""
    hour = dt.hour % 12 or 12
    return f"{hour} {'AM' if dt.hour < 12 else 'PM'}"


# --- Home Assistant ----------------------------------------------------------

def _ha_fetch(env: dict) -> dict:
    """weather.get_forecasts, hourly. The house already owns this."""
    body = json.dumps({"entity_id": WEATHER_ENTITY, "type": "hourly"}).encode()
    req = urllib.request.Request(
        f"{env['HA_URL']}/api/services/weather/get_forecasts?return_response",
        data=body, method="POST",
        headers={"Authorization": f"Bearer {env['HA_TOKEN']}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def _ha_hours(payload: dict, now: datetime, count: int, tz=None) -> list:
    """HA's forecast list -> the panel's hours.

    Times arrive in UTC with an offset, so they are converted before anything
    is labelled: an hour named "8 AM" has to be 8 AM in the kitchen, not in
    Greenwich. `tz` of None means the host's own zone, which is the wall's --
    the generator runs on the same LAN as the fridge. It is a parameter only so
    that a test can pin a zone instead of inheriting the runner's.
    """
    resp = payload.get("service_response") or {}
    entry = resp.get(WEATHER_ENTITY) or next(iter(resp.values()), {})
    out = []
    for f in entry.get("forecast") or []:
        try:
            at = datetime.fromisoformat(f["datetime"]).astimezone(tz)
        except (KeyError, TypeError, ValueError):
            continue
        if at < now:
            continue
        icon = HA_ICONS.get((f.get("condition") or "").lower(), FALLBACK_ICON)
        if _is_night(at):
            icon = NIGHT_SWAP.get(icon, icon)
        temp = f.get("temperature")
        out.append({
            "label": _label(at),
            "icon": icon,
            "temp": None if temp is None else round(temp),
            # met.no through HA reports precipitation in mm, never a chance of
            # it. None means "this provider cannot say", and the panel drops
            # the row rather than inventing a number.
            "precip_pct": None,
        })
        if len(out) >= count:
            break
    return out


PROVIDERS = {
    "homeassistant": (_ha_fetch, _ha_hours),
}


# --- the seam ----------------------------------------------------------------

def fetch(env: dict, provider: str = None) -> dict:
    """The raw payload, tagged so hours() knows how to read it."""
    name = provider or PROVIDER
    get, _ = PROVIDERS[name]
    return {"provider": name, "raw": get(env)}


def hours(payload: dict, now: datetime = None, count: int = HOURS, tz=None) -> dict:
    """The panel's hourly strip. Never raises: a broken or missing forecast
    renders as no strip at all, which is a gap the wall survives."""
    if not payload:
        return {"provider": None, "hours": []}
    name = payload.get("provider") or PROVIDER
    pair = PROVIDERS.get(name)
    if not pair:
        return {"provider": name, "hours": []}
    now = now or datetime.now().astimezone(tz)
    try:
        got = pair[1](payload.get("raw") or {}, now, count, tz)
    except Exception:
        got = []
    return {"provider": name, "hours": got}


def main(argv=None) -> int:
    import argparse
    import importlib.util
    import sys
    here = os.path.dirname(os.path.abspath(__file__))
    sp = importlib.util.spec_from_file_location("fl", os.path.join(here, "fetch_live.py"))
    fl = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(fl)

    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--provider", default=None, help=f"one of {sorted(PROVIDERS)}")
    p.add_argument("--hours", type=int, default=HOURS)
    a = p.parse_args(argv)
    doc = hours(fetch(fl.load_env(), a.provider), count=a.hours)
    json.dump(doc, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
