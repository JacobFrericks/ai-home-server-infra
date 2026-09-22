#!/usr/bin/env python3
"""Tests for brief/weather.py -- the hourly strip and its provider seam.

No network: every test drives the pure half, which is the point of splitting
fetch() from hours(). What is under test is the mapping a provider swap would
have to preserve.

Run: python3 tests/test_weather.py
"""
import importlib.util
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "wx", os.path.join(ROOT, "brief", "weather.py"))
wx = importlib.util.module_from_spec(spec)
sys.modules["wx"] = wx
spec.loader.exec_module(wx)

LOCAL = timezone(timedelta(hours=-5))
NOW = datetime(2026, 9, 22, 7, 30, tzinfo=LOCAL)


def strip(payload_, now, count):
    """hours() with the zone pinned. Without this the assertions depend on the
    clock of whatever machine runs them: CI is UTC, the fridge is Central, and
    "is 2am night?" gets a different answer in each."""
    return wx.hours(payload_, now, count, LOCAL)


def payload(*hours):
    """A Home Assistant get_forecasts response carrying these hours."""
    return {"provider": "homeassistant",
            "raw": {"service_response": {wx.WEATHER_ENTITY: {"forecast": list(hours)}}}}


def hour(at, condition="cloudy", temp=54):
    return {"datetime": at.isoformat(), "condition": condition,
            "temperature": temp}


class Strip(unittest.TestCase):
    def test_returns_the_requested_number_of_hours(self):
        hrs = [hour(NOW + timedelta(hours=i)) for i in range(12)]
        got = strip(payload(*hrs), NOW, 5)
        self.assertEqual(len(got["hours"]), 5)

    def test_hours_already_past_are_skipped(self):
        hrs = [hour(NOW - timedelta(hours=3)), hour(NOW - timedelta(hours=1)),
               hour(NOW + timedelta(hours=1), temp=61)]
        got = strip(payload(*hrs), NOW, 5)["hours"]
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["temp"], 61)

    def test_a_short_forecast_returns_what_it_has(self):
        got = strip(payload(hour(NOW + timedelta(hours=1))), NOW, 5)
        self.assertEqual(len(got["hours"]), 1)

    def test_temperature_is_rounded_to_a_whole_degree(self):
        got = strip(payload(hour(NOW + timedelta(hours=1), temp=54.6)), NOW, 5)
        self.assertEqual(got["hours"][0]["temp"], 55)

    def test_a_missing_temperature_is_none_not_zero(self):
        h = hour(NOW + timedelta(hours=1))
        h["temperature"] = None
        self.assertIsNone(strip(payload(h), NOW, 5)["hours"][0]["temp"])

    def test_unparseable_times_are_skipped_not_fatal(self):
        bad = {"datetime": "not a time", "condition": "sunny", "temperature": 50}
        got = strip(payload(bad, hour(NOW + timedelta(hours=1))), NOW, 5)
        self.assertEqual(len(got["hours"]), 1)


class Labels(unittest.TestCase):
    """The label has to read as the hour in the kitchen."""

    def test_midnight_and_noon_are_12_not_0(self):
        self.assertEqual(wx._label(NOW.replace(hour=0)), "12 AM")
        self.assertEqual(wx._label(NOW.replace(hour=12)), "12 PM")

    def test_no_leading_zero(self):
        self.assertEqual(wx._label(NOW.replace(hour=8)), "8 AM")

    def test_afternoon_is_pm(self):
        self.assertEqual(wx._label(NOW.replace(hour=13)), "1 PM")

    def test_utc_times_are_converted_before_labelling(self):
        """The forecast arrives in UTC. An hour named 8 AM must be 8 AM here."""
        utc = datetime(2026, 9, 22, 18, 0, tzinfo=timezone.utc)
        got = strip(payload(hour(utc)), utc - timedelta(hours=1), 5)["hours"]
        self.assertEqual(got[0]["label"], "1 PM")   # 18:00 UTC in UTC-5


class Icons(unittest.TestCase):
    """Every condition maps into the panel's vocabulary, whatever arrives."""

    def icon(self, condition, at=None):
        at = at or NOW.replace(hour=13)
        return strip(payload(hour(at, condition)), at - timedelta(minutes=1),
                        1)["hours"][0]["icon"]

    def test_every_mapped_icon_is_in_the_panel_vocabulary(self):
        for key in wx.HA_ICONS.values():
            self.assertIn(key, wx.ICONS, key)
        for key in wx.NIGHT_SWAP.values():
            self.assertIn(key, wx.ICONS, key)

    def test_known_conditions_map(self):
        self.assertEqual(self.icon("lightning-rainy"), "thunderstorm")
        self.assertEqual(self.icon("pouring"), "rain")
        self.assertEqual(self.icon("snowy-rainy"), "sleet")

    def test_an_unknown_condition_falls_back_rather_than_vanishing(self):
        self.assertEqual(self.icon("meteor-shower"), wx.FALLBACK_ICON)
        self.assertIn(wx.FALLBACK_ICON, wx.ICONS)

    def test_a_missing_condition_falls_back(self):
        h = {"datetime": (NOW + timedelta(hours=1)).isoformat(), "temperature": 50}
        self.assertEqual(strip(payload(h), NOW, 1)["hours"][0]["icon"],
                         wx.FALLBACK_ICON)

    def test_sun_at_night_becomes_a_moon(self):
        """A provider reporting "sunny" at 2am is reporting a code, not a sky."""
        self.assertEqual(self.icon("sunny", NOW.replace(hour=2)), "clear-night")
        self.assertEqual(self.icon("partlycloudy", NOW.replace(hour=22)),
                         "partly-cloudy-night")

    def test_sun_in_the_day_stays_a_sun(self):
        self.assertEqual(self.icon("sunny", NOW.replace(hour=13)), "sunny")

    def test_rain_is_not_swapped_for_night(self):
        self.assertEqual(self.icon("pouring", NOW.replace(hour=2)), "rain")


class ProviderSeam(unittest.TestCase):
    """What a second provider must not have to change."""

    def test_precip_is_none_when_the_provider_cannot_say(self):
        """Not 0 -- the panel omits the row rather than claiming no rain."""
        got = strip(payload(hour(NOW + timedelta(hours=1))), NOW, 1)["hours"]
        self.assertIsNone(got[0]["precip_pct"])

    def test_every_hour_has_the_full_shape(self):
        got = strip(payload(hour(NOW + timedelta(hours=1))), NOW, 1)["hours"]
        self.assertEqual(set(got[0]), {"label", "icon", "temp", "precip_pct"})

    def test_the_provider_is_named_in_the_document(self):
        self.assertEqual(strip(payload(), NOW, 5)["provider"], "homeassistant")

    def test_an_unknown_provider_yields_no_strip_rather_than_raising(self):
        got = wx.hours({"provider": "nope", "raw": {}}, NOW, 5)
        self.assertEqual(got["hours"], [])

    def test_no_payload_at_all_yields_no_strip(self):
        self.assertEqual(wx.hours(None)["hours"], [])

    def test_a_malformed_payload_yields_no_strip(self):
        self.assertEqual(
            wx.hours({"provider": "homeassistant", "raw": "nonsense"}, NOW)["hours"],
            [])

    def test_an_empty_forecast_yields_no_strip(self):
        self.assertEqual(strip(payload(), NOW, 5)["hours"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
