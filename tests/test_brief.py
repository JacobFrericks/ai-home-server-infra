#!/usr/bin/env python3
"""Tests for brief/generate_brief.py.

These run against the recorded fixtures, which copy the REAL published response
shapes (Google Calendar events.list, Gmail users.messages.get, Home Assistant
todo.get_items). That is the point: the transforms are where the bugs live, and
they are identical whether the bytes came from a file or from the API. When
credentials arrive, only the fetch changes and these still hold.

Run: python3 tests/test_brief.py
"""
import importlib.util
import json
import os
import sys
import unittest
from datetime import date, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, "brief", "fixtures")

spec = importlib.util.spec_from_file_location(
    "gen", os.path.join(ROOT, "brief", "generate_brief.py"))
gen = importlib.util.module_from_spec(spec)
sys.modules["gen"] = gen
spec.loader.exec_module(gen)

TODAY = date(2026, 9, 20)


def fixture(name):
    with open(os.path.join(FIX, name), encoding="utf-8") as f:
        return json.load(f)


class Calendar(unittest.TestCase):
    def setUp(self):
        self.events = fixture("calendar_events.json")

    def test_all_day_events_are_not_dropped(self):
        """start.date, not start.dateTime. Recycle day lives here."""
        names = [e["summary"] for e in gen.events_for(self.events, TODAY)]
        self.assertIn("Recycle day", names)

    def test_cancelled_events_are_excluded(self):
        """A cancelled event stays in the feed. Showing it sends someone out
        to a thing that is not happening."""
        names = [e["summary"] for e in gen.events_for(self.events, TODAY)]
        self.assertNotIn("Swim lessons", names)

    def test_other_days_are_excluded(self):
        names = [e["summary"] for e in gen.events_for(self.events, TODAY)]
        self.assertNotIn("Great Wolf Lodge Reservation", names)

    def test_all_day_sorts_before_timed(self):
        evs = gen.events_for(self.events, TODAY)
        self.assertTrue(evs[0]["all_day"])
        timed = [e for e in evs if not e["all_day"]]
        self.assertEqual([e["summary"] for e in timed],
                         ["Cassie ACA", "Speech — Judah and Nora"])

    def test_time_format_is_short(self):
        f = gen._fmt_time
        self.assertEqual(f(datetime(2026, 9, 20, 7, 30)), "7:30a")
        self.assertEqual(f(datetime(2026, 9, 20, 15, 15)), "3:15p")
        self.assertEqual(f(datetime(2026, 9, 20, 9, 0)), "9a")
        self.assertEqual(f(datetime(2026, 9, 20, 12, 0)), "12p")
        self.assertEqual(f(datetime(2026, 9, 20, 0, 30)), "12:30a")


class Mail(unittest.TestCase):
    def setUp(self):
        self.mail = fixture("gmail_messages.json")

    def test_headers_are_case_insensitive(self):
        """payload.headers is a list of pairs and senders pick their own
        casing -- the second fixture message uses lowercase "subject"."""
        subjects = [m["subject"] for m in gen.mail_summaries(self.mail)]
        self.assertIn("Fall soccer registration closes Sept 30", subjects)

    def test_one_entry_per_thread(self):
        """A six-reply chain about one event is one thing happening."""
        out = gen.mail_summaries(self.mail)
        self.assertEqual(len(out), 2)
        self.assertEqual(len({m["subject"] for m in out}), 2)

    def test_body_and_snippet_never_appear(self):
        """The wall is public. A forwarded school mail can carry another
        family's details in its reply chain, and `snippet` is where that would
        surface -- so nothing derived from it may reach the output."""
        blob = json.dumps(gen.build(fixture("calendar_events.json"),
                                    self.mail, fixture("ha_todos.json"), TODAY))
        for msg in self.mail["messages"]:
            leak = msg["snippet"][:40]
            self.assertNotIn(leak, blob, "message snippet leaked into brief.json")
        self.assertNotIn("Order forms are due back", blob)

    def test_sender_display_name_is_used(self):
        froms = [m["from"] for m in gen.mail_summaries(self.mail)]
        self.assertIn("Ankeny Christian Academy", froms)
        self.assertFalse(any("<" in f for f in froms))

    def test_read_mail_is_skipped(self):
        subjects = [m["subject"] for m in gen.mail_summaries(self.mail)]
        self.assertFalse(any(s.startswith("Re:") for s in subjects))


class Todos(unittest.TestCase):
    def setUp(self):
        self.todos = fixture("ha_todos.json")
        self.cols = gen.todo_columns(self.todos, TODAY)

    def test_completed_items_are_excluded(self):
        jacob = next(c for c in self.cols if c["owner"] == "jacob")
        self.assertNotIn("Pay the water bill",
                         [i["text"] for i in jacob["items"]])

    def test_undated_items_sort_last_not_first(self):
        """An empty `due` must not sort as the most urgent thing on the wall."""
        jacob = next(c for c in self.cols if c["owner"] == "jacob")
        self.assertEqual(jacob["items"][-1]["text"], "Fix the garage light")

    def test_due_handles_date_and_datetime(self):
        """HA returns a bare date for some items and a full datetime for
        others. Both must render."""
        cassie = next(c for c in self.cols if c["owner"] == "cassie")
        labels = {i["text"]: i["due"] for i in cassie["items"]}
        self.assertEqual(labels["Return library books"], "Sat")
        self.assertEqual(labels["Reschedule haircut"], "")

    def test_due_labels_are_human(self):
        f = gen._due_label
        self.assertEqual(f("2026-09-20", TODAY), "today")
        self.assertEqual(f("2026-09-21", TODAY), "tomorrow")
        self.assertEqual(f("2026-10-03", TODAY), "Oct 3")
        self.assertEqual(f(None, TODAY), "")

    def test_auto_list_is_flagged(self):
        auto = [c for c in self.cols if c["auto"]]
        self.assertEqual(len(auto), 1)
        self.assertEqual(auto[0]["owner"], "family")

    def test_shopping_list_is_not_a_panel_column(self):
        self.assertNotIn("Shopping", [c["name"] for c in self.cols])


class Panel(unittest.TestCase):
    """The output must fit what MMM-FamilyBrief can actually render."""

    def setUp(self):
        self.doc = gen.build(fixture("calendar_events.json"),
                             fixture("gmail_messages.json"),
                             fixture("ha_todos.json"), TODAY)

    def test_respects_the_measured_caps(self):
        self.assertLessEqual(len(self.doc["lines"]), gen.MAX_LINES)
        for col in self.doc["todos"]:
            self.assertLessEqual(len(col["items"]), gen.MAX_ITEMS)

    def test_shape_matches_what_the_module_reads(self):
        self.assertEqual(set(self.doc) >= {"headline", "lines", "todos"}, True)
        for line in self.doc["lines"]:
            self.assertEqual(set(line), {"owner", "text"})
        for col in self.doc["todos"]:
            self.assertTrue({"owner", "name", "items"} <= set(col))
            for item in col["items"]:
                self.assertEqual(set(item), {"text", "due"})

    def test_owner_keys_match_the_wall_colour_keys(self):
        allowed = {"jacob", "cassie", "family"}
        self.assertTrue({c["owner"] for c in self.doc["todos"]} <= allowed)
        self.assertTrue({l["owner"] for l in self.doc["lines"]} <= allowed)

    def test_empty_day_still_produces_a_headline(self):
        """The panel must never render a blank band."""
        doc = gen.build({"items": []}, {"messages": []},
                        {"service_response": {}}, TODAY)
        self.assertTrue(doc["headline"])
        self.assertEqual(doc["lines"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
