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
        self.assertNotIn("Water park weekend", names)

    def test_all_day_sorts_before_timed(self):
        evs = gen.events_for(self.events, TODAY)
        self.assertTrue(evs[0]["all_day"])
        timed = [e for e in evs if not e["all_day"]]
        self.assertEqual([e["summary"] for e in timed],
                         ["Sam Northside", "Speech — Robin and Quinn"])

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

    def test_sender_display_name_is_used(self):
        froms = [m["from"] for m in gen.mail_summaries(self.mail)]
        self.assertIn("Northside School", froms)
        self.assertFalse(any("<" in f for f in froms))

    def test_read_mail_is_skipped(self):
        subjects = [m["subject"] for m in gen.mail_summaries(self.mail)]
        self.assertFalse(any(s.startswith("Re:") for s in subjects))

    # --- the body is the point ---------------------------------------------

    def test_body_is_read(self):
        """The detail that makes a to-do lives in the body, never the subject.
        "moved to October 3" is not derivable from "Picture Day moved to
        October 3" alone -- the OLD date, the form deadline and the retake date
        are all body-only."""
        m = next(m for m in gen.mail_summaries(self.mail)
                 if "Picture Day" in m["subject"])
        self.assertIn("October 3", m["body"])
        self.assertIn("September 26", m["body"])     # the date it moved FROM
        self.assertIn("Order forms", m["body"])
        self.assertIn("November 14", m["body"])      # retakes

    def test_plain_text_preferred_over_html(self):
        """Both parts are usually present; the HTML one is layout markup."""
        body = gen.message_body(self.mail["messages"][0])
        self.assertIn("Dear Families", body)
        self.assertNotIn("<b>", body)
        self.assertNotIn("<html>", body)

    def test_nested_multipart_is_walked(self):
        """multipart/mixed with a PDF keeps the real text one level down,
        inside a multipart/alternative. Not recursing loses the whole body."""
        body = gen.message_body(self.mail["messages"][1])
        self.assertIn("registration closes September 30", body)
        self.assertIn("$85 per player", body)

    def test_attachment_parts_are_skipped(self):
        """An attachment carries attachmentId and no inline data."""
        body = gen.message_body(self.mail["messages"][1])
        self.assertNotIn("soccer-flyer.pdf", body)
        self.assertNotIn("ANGjdJ_attach", body)

    def test_simple_message_body_on_payload(self):
        """No parts at all -- data sits directly on payload.body."""
        body = gen.message_body(self.mail["messages"][2])
        self.assertIn("No action needed", body)

    def test_base64url_alphabet(self):
        """Gmail uses -_ rather than +/, and drops the padding."""
        import base64
        raw = "Picture day ~ 3 + 4 / 5 ? yes"
        data = base64.urlsafe_b64encode(raw.encode()).decode().rstrip("=")
        msg = {"payload": {"mimeType": "text/plain", "body": {"data": data}}}
        self.assertEqual(gen.message_body(msg), raw)

    def test_metadata_format_yields_empty_not_a_crash(self):
        """format=metadata returns headers and no body. That is a client
        misconfiguration, not a parse error -- it must not raise."""
        msg = {"payload": {"mimeType": "multipart/alternative",
                           "headers": [{"name": "Subject", "value": "x"}]}}
        self.assertEqual(gen.message_body(msg), "")

    def test_html_only_message_falls_back_to_stripped_html(self):
        import base64
        html = "<p>Practice is <b>cancelled</b> tonight.</p>"
        data = base64.urlsafe_b64encode(html.encode()).decode().rstrip("=")
        msg = {"payload": {"mimeType": "text/html", "body": {"data": data}}}
        body = gen.message_body(msg)
        self.assertIn("cancelled", body)
        self.assertNotIn("<b>", body)

    def test_thread_replies_are_joined_not_dropped(self):
        """A correction sent as a reply must not be lost to thread dedup."""
        mail = {"messages": [
            dict(self.mail["messages"][0], labelIds=["UNREAD"]),
            dict(self.mail["messages"][2], threadId=self.mail["messages"][0]["threadId"],
                 labelIds=["UNREAD"]),
        ]}
        out = gen.mail_summaries(mail)
        self.assertEqual(len(out), 1)
        self.assertIn("Dear Families", out[0]["body"])
        self.assertIn("No action needed", out[0]["body"])

    def test_with_body_false_omits_it(self):
        out = gen.mail_summaries(self.mail, with_body=False)
        self.assertTrue(all("body" not in m for m in out))


class Todos(unittest.TestCase):
    def setUp(self):
        self.todos = fixture("ha_todos.json")
        self.cols = gen.todo_columns(self.todos, TODAY)

    def test_completed_items_are_excluded(self):
        col_a = next(c for c in self.cols if c["owner"] == "adult-a")
        self.assertNotIn("Pay the water bill",
                         [i["text"] for i in col_a["items"]])

    def test_undated_items_sort_last_not_first(self):
        """An empty `due` must not sort as the most urgent thing on the wall."""
        col_a = next(c for c in self.cols if c["owner"] == "adult-a")
        self.assertEqual(col_a["items"][-1]["text"], "Fix the garage light")

    def test_due_handles_date_and_datetime(self):
        """HA returns a bare date for some items and a full datetime for
        others. Both must render."""
        col_b = next(c for c in self.cols if c["owner"] == "adult-b")
        labels = {i["text"]: i["due"] for i in col_b["items"]}
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

    def test_wall_renders_distilled_facts_not_pasted_email(self):
        """The AI reads the whole body -- forwarding is the permission. But the
        panel shows the distilled fact, because it is read from across a room.
        Body text must not end up in headline/lines, which are what render."""
        rendered = self.doc["headline"] + " " + " ".join(
            l["text"] for l in self.doc["lines"])
        self.assertNotIn("Dear Families", rendered)
        self.assertNotIn("$85 per player", rendered)
        self.assertLess(len(self.doc["headline"]), 120)

    def test_owner_keys_match_the_wall_colour_keys(self):
        allowed = {"adult-a", "adult-b", "family"}
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
