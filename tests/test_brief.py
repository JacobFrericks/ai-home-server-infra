#!/usr/bin/env python3
"""Tests for brief/generate_brief.py.

These run against the recorded fixtures, which copy the REAL published response
shapes (Google Calendar events.list, Gmail users.messages.get, Home Assistant
todo.get_items). That is the point: the transforms are where the bugs live, and
they are identical whether the bytes came from a file or from the API. When
credentials arrive, only the fetch changes and these still hold.

Run: python3 tests/test_brief.py
"""
import base64
import importlib.util
import shutil
import json
import os
import sys
import unittest
from datetime import date, datetime, timedelta

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

    # --- noise removal -----------------------------------------------------

    def test_footer_boilerplate_is_cut(self):
        """Measured on a real forwarded newsletter: 1651 chars in, one useful
        sentence. The rest was tracking URLs, unsubscribe blocks and an
        address -- context spent on nothing, plus more ways to mislead."""
        raw = ("Picture Day is coming up on September 24, 2026.\n"
               "Cheers,\n\nUnsubscribe\n<https://x.example/token>\n"
               "  |  Manage Preferences\n  |  Privacy Policy\n"
               "735 Tehama Street, San Francisco CA 94103")
        out = gen.clean_body(raw)
        self.assertIn("September 24, 2026", out)
        self.assertNotIn("Unsubscribe", out)
        self.assertNotIn("Tehama", out)

    def test_long_tracking_urls_are_dropped(self):
        long_url = "https://x.example/p?ctt=" + "A" * 300
        out = gen.clean_body(f"Event is Friday.\n<{long_url}>\nCheers,")
        self.assertIn("Event is Friday.", out)
        self.assertNotIn("ctt=", out)

    def test_short_links_are_kept(self):
        """A short bare link is sometimes the content -- a form, a meeting."""
        out = gen.clean_body("Sign up: https://ex.co/form1")
        self.assertIn("https://ex.co/form1", out)

    def test_image_placeholders_go(self):
        out = gen.clean_body("[image: Logo]\nPractice at 5.\n[image: Footer]")
        self.assertNotIn("[image:", out)
        self.assertIn("Practice at 5.", out)

    def test_forward_header_survives(self):
        """Manual forwards put the REAL sender in the body -- the From header
        just says whoever forwarded it. Losing this loses who it came from."""
        raw = ("---------- Forwarded message ---------\n"
               "From: School <office@school.example.edu>\n"
               "Subject: Picture Day\n\nIt moved to Oct 3.\nUnsubscribe\n")
        out = gen.clean_body(raw)
        self.assertIn("office@school.example.edu", out)
        self.assertIn("Oct 3", out)

    def test_cleaning_never_empties_real_content(self):
        for raw in ("Practice cancelled tonight.", "A\n\nB", "  spaced  "):
            self.assertTrue(gen.clean_body(raw).strip(), f"emptied: {raw!r}")

    def test_with_body_false_omits_it(self):
        out = gen.mail_summaries(self.mail, with_body=False)
        self.assertTrue(all("body" not in m for m in out))


class Todos(unittest.TestCase):
    def setUp(self):
        self.todos = fixture("ha_todos.json")
        # Explicit HA specs: the shipped defaults now read the personal list
        # from Google Tasks, so they no longer describe this fixture.
        self.cols = gen.todo_columns(self.todos, TODAY, [
            {"source": "ha", "entity": "todo.adult_a", "owner": "adult-a",
             "name": "Adult A", "panel": True},
            {"source": "ha", "entity": "todo.adult_b", "owner": "adult-b",
             "name": "Adult B", "panel": True},
            {"source": "ha", "entity": "todo.family_auto", "owner": "family",
             "name": "Suggested", "auto": True, "panel": True},
            {"source": "ha", "entity": "todo.shopping_list", "owner": "family",
             "name": "Shopping", "panel": False},
        ])

    def test_item_descriptions_never_reach_the_wall(self):
        """The panel shows `summary` and `due`, and nothing else.

        extract.build_note deliberately writes a long description -- the
        source line plus a verbatim quote -- so the assistant can answer
        "what is that about?" later. That is only acceptable while the wall
        cannot render it, so this asserts the boundary rather than trusting
        it: a secret is planted in every field the panel might pick up.
        """
        secret = "SHOULD-NOT-BE-ON-THE-WALL"
        todos = json.loads(json.dumps(self.todos))
        resp = todos.get("service_response", todos)
        for lst in resp.values():
            for item in lst.get("items", []):
                item["description"] = secret
                item["notes"] = secret
        cols = gen.todo_columns(todos, TODAY, [
            {"source": "ha", "entity": "todo.family_auto", "owner": "family",
             "name": "Suggested", "auto": True, "panel": True}])
        self.assertTrue(cols[0]["items"], "fixture produced no items to check")
        self.assertNotIn(secret, json.dumps(cols))

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


class GoogleTasks(unittest.TestCase):
    """The personal-list source. Read-only by credential, not by politeness."""

    def setUp(self):
        self.gt = fixture("google_tasks.json")
        self.spec = [{"source": "google_tasks", "account": "adult-a",
                      "list": "My Tasks", "owner": "adult-a",
                      "name": "Mine", "panel": True}]
        self.col = gen.todo_columns({"google_tasks": {"adult-a": self.gt}},
                                    TODAY, self.spec)[0]

    def titles(self):
        return [i["text"] for i in self.col["items"]]

    def test_ancient_overdue_task_is_hidden(self):
        """The one that forced this rule: a 2013 task sorts SOONEST-DUE and
        would otherwise sit permanently at the top of the kitchen wall."""
        self.assertNotIn("Laundry", self.titles())

    def test_recently_overdue_task_is_kept(self):
        """Overdue by 11 days is still a real commitment -- do not hide it."""
        self.assertIn("Order a yearbook", self.titles())

    def test_boundary_of_the_staleness_rule(self):
        f = gen._is_stale
        self.assertFalse(f("2026-09-06", TODAY))   # exactly 14 days over
        self.assertTrue(f("2026-09-05", TODAY))    # 15 -> gone
        self.assertFalse(f(None, TODAY))           # undated is never stale
        self.assertFalse(f("2026-12-01", TODAY))   # future

    def test_completed_tasks_are_excluded(self):
        self.assertNotIn("Already done", self.titles())

    def test_due_time_component_is_ignored(self):
        """Google Tasks has no due TIME -- it is always 00:00:00Z. Treating it
        as a real timestamp would shift the date across time zones."""
        items = gen.google_tasks_items(self.gt, "My Tasks")
        picture = next(i for i in items if i["summary"] == "Picture day")
        self.assertEqual(picture["due"], "2026-09-23")

    def test_undated_task_survives_and_sorts_last(self):
        self.assertEqual(self.titles()[-1], "Fix the gate latch")

    def test_unknown_list_title_yields_nothing(self):
        self.assertEqual(gen.google_tasks_items(self.gt, "Nope"), [])

    def test_empty_list_is_handled(self):
        self.assertEqual(gen.google_tasks_items(self.gt, "Chores"), [])


class Panel(unittest.TestCase):
    """The output must fit what MMM-FamilyBrief can actually render."""

    def setUp(self):
        todos = dict(fixture("ha_todos.json"))
        todos["google_tasks"] = {"adult-a": fixture("google_tasks.json")}
        self.lists = [
            {"source": "google_tasks", "account": "adult-a", "list": "My Tasks",
             "owner": "adult-a", "name": "Mine", "panel": True},
            {"source": "ha", "entity": "todo.family_auto", "owner": "family",
             "name": "Suggested", "auto": True, "panel": True},
        ]
        self.doc = gen.build(fixture("calendar_events.json"),
                             fixture("gmail_messages.json"),
                             todos, TODAY, self.lists)

    def test_both_sources_appear_side_by_side(self):
        """One Google Tasks column and one Home Assistant column, together."""
        self.assertEqual([c["name"] for c in self.doc["todos"]],
                         ["Mine", "Suggested"])
        self.assertTrue(all(c["items"] or c["total"] == 0
                            for c in self.doc["todos"]))

    def test_only_the_bot_list_is_flagged_auto(self):
        """The 'auto' badge is what tells a person a machine wrote it."""
        auto = [c["name"] for c in self.doc["todos"] if c["auto"]]
        self.assertEqual(auto, ["Suggested"])

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


class MailCache(unittest.TestCase):
    """The cache is what lets the 15-minute job avoid IMAP entirely."""

    def setUp(self):
        import importlib.util, tempfile
        self.dir = tempfile.mkdtemp()
        os.environ["MAIL_CACHE"] = os.path.join(self.dir, "cache.json")
        spec = importlib.util.spec_from_file_location(
            "fl", os.path.join(ROOT, "brief", "fetch_live.py"))
        self.fl = importlib.util.module_from_spec(spec)
        sys.modules["fl"] = self.fl
        spec.loader.exec_module(self.fl)
        self.calls = []

    def _stub(self, result=None, boom=False):
        def fake(env, **kw):
            self.calls.append(1)
            if boom:
                raise OSError("imap down")
            return result or {"messages": [{"id": "x"}]}
        self.fl.fetch_mail = fake

    def test_fresh_cache_avoids_imap_entirely(self):
        """The whole point: 15-minute ticks must not open a Gmail connection."""
        self._stub()
        self.fl.cached_mail({}, 3600)
        self.fl.cached_mail({}, 3600)
        self.fl.cached_mail({}, 3600)
        self.assertEqual(len(self.calls), 1, "IMAP hit more than once")

    def test_zero_max_age_forces_a_live_fetch(self):
        self._stub()
        self.fl.cached_mail({}, 3600)
        _, how = self.fl.cached_mail({}, 0)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(how, "live")

    def test_stale_cache_is_served_when_imap_fails(self):
        """A slightly old mail list beats an empty one -- the panel cannot tell
        'no mail' from 'could not reach Gmail', so it must not show empty."""
        self._stub()
        self.fl.cached_mail({}, 3600)
        self._stub(boom=True)
        payload, how = self.fl.cached_mail({}, 0)
        self.assertTrue(payload["messages"])
        self.assertTrue(how.startswith("STALE"))

    def test_no_cache_and_imap_down_raises(self):
        """Nothing to fall back on is a real error, not a silent empty."""
        self._stub(boom=True)
        with self.assertRaises(OSError):
            self.fl.cached_mail({}, 3600)


class Horizon(unittest.TestCase):
    """`max_days_ahead` — a list that only shows this week's business."""

    SPEC = {"source": "ha", "entity": "todo.mine", "owner": "jacob",
            "name": "Jacob", "panel": True, "max_days_ahead": 7}

    def cols(self, items, spec=None):
        todos = {"service_response": {"todo.mine": {"items": items}}}
        return gen.todo_columns(todos, TODAY, [spec or self.SPEC])[0]

    def texts(self, items, spec=None):
        return [i["text"] for i in self.cols(items, spec)["items"]]

    def test_inside_the_window_is_kept(self):
        due = (TODAY + timedelta(days=7)).isoformat()
        self.assertEqual(self.texts([{"summary": "Picture day", "due": due}]),
                         ["Picture day"])

    def test_one_day_past_the_window_is_hidden(self):
        due = (TODAY + timedelta(days=8)).isoformat()
        self.assertEqual(self.texts([{"summary": "Later", "due": due}]), [])

    def test_undated_is_hidden_when_a_horizon_is_set(self):
        """"The next 7 days" is a claim about when a thing happens, and an
        undated item makes no such claim."""
        self.assertEqual(self.texts([{"summary": "Someday", "due": None}]), [])

    def test_undated_is_kept_when_no_horizon_is_set(self):
        spec = {k: v for k, v in self.SPEC.items() if k != "max_days_ahead"}
        self.assertEqual(self.texts([{"summary": "Someday", "due": None}], spec),
                         ["Someday"])

    def test_the_horizon_does_not_resurrect_completed_items(self):
        due = (TODAY + timedelta(days=1)).isoformat()
        self.assertEqual(
            self.texts([{"summary": "Done", "due": due, "status": "completed"}]),
            [])

    def test_total_counts_only_what_survived(self):
        near = (TODAY + timedelta(days=2)).isoformat()
        far = (TODAY + timedelta(days=99)).isoformat()
        col = self.cols([{"summary": "Soon", "due": near},
                         {"summary": "Far", "due": far}])
        self.assertEqual(col["total"], 1)


class HeadlineToday(unittest.TestCase):
    """The headline is a claim about TODAY, so only today may feed it."""

    LISTS = [{"source": "ha", "entity": "todo.mine", "owner": "jacob",
              "name": "Jacob", "panel": True}]

    def due(self, items):
        todos = {"service_response": {"todo.mine": {"items": items}}}
        return gen.items_due_today(todos, TODAY, self.LISTS)

    def test_item_due_today_is_todays_business(self):
        self.assertEqual(
            self.due([{"summary": "Pay the deposit", "due": TODAY.isoformat()}]),
            ["Pay the deposit"])

    def test_completed_today_is_not_todays_business(self):
        self.assertEqual(self.due([{"summary": "Done", "due": TODAY.isoformat(),
                                    "status": "completed"}]), [])

    def test_overdue_is_not_today(self):
        old = (TODAY - timedelta(days=10)).isoformat()
        self.assertEqual(self.due([{"summary": "Parent meeting", "due": old}]), [])

    def test_undated_is_not_today(self):
        self.assertEqual(self.due([{"summary": "Someday", "due": None}]), [])

    def test_hidden_lists_do_not_feed_the_headline(self):
        lists = [dict(self.LISTS[0], panel=False)]
        todos = {"service_response": {"todo.mine": {"items": [
            {"summary": "Milk", "due": TODAY.isoformat()}]}}}
        self.assertEqual(gen.items_due_today(todos, TODAY, lists), [])


class Filler(unittest.TestCase):
    """An empty day still has to say something."""

    def test_empty_day_gets_a_filler(self):
        self.assertIn(gen._headline([], [], TODAY), gen.FILLERS)

    def test_a_due_item_beats_the_filler(self):
        self.assertEqual(gen._headline([], ["Pay the deposit"], TODAY),
                         "Pay the deposit is due today.")

    def test_several_due_items_are_counted(self):
        self.assertEqual(gen._headline([], ["A", "B"], TODAY),
                         "2 things due today.")

    def test_events_still_win(self):
        out = gen._headline([{"summary": "Church", "all_day": True}], [], TODAY)
        self.assertEqual(out, "Church.")

    def test_the_same_day_always_gets_the_same_line(self):
        """It is re-rendered every 15 minutes; the wall must not flicker."""
        self.assertEqual(gen.filler_for(TODAY), gen.filler_for(TODAY))

    def test_consecutive_days_differ(self):
        self.assertNotEqual(gen.filler_for(TODAY),
                            gen.filler_for(TODAY + timedelta(days=1)))

    def test_every_filler_fits_the_band(self):
        for f in gen.FILLERS:
            self.assertLessEqual(len(f), 90, f)
            self.assertTrue(f.endswith("."), f)

    def test_fillers_are_unique(self):
        self.assertEqual(len(set(gen.FILLERS)), len(gen.FILLERS))


def _b64(raw: bytes) -> str:
    """Gmail's unpadded base64URL, the shape message_body expects."""
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


# A minimal one-page PDF with a real text layer, built by hand so the test
# needs no fixture file and no PDF library -- only the pdftotext that the
# pipeline itself shells out to.
def _tiny_pdf(line: str) -> bytes:
    content = f"BT /F1 12 Tf 72 720 Td ({line}) Tj ET".encode()
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n"
        + content + b"\nendstream",
    ]
    out, offsets = bytearray(b"%PDF-1.4\n"), []
    for i, body in enumerate(objs, start=1):
        offsets.append(len(out))
        out += str(i).encode() + b" 0 obj\n" + body + b"\nendobj\n"
    start = len(out)
    out += b"xref\n0 " + str(len(objs) + 1).encode() + b"\n0000000000 65535 f \n"
    for off in offsets:
        out += f"{off:010d} 00000 n \n".encode()
    out += (b"trailer\n<< /Size " + str(len(objs) + 1).encode()
            + b" /Root 1 0 R >>\nstartxref\n" + str(start).encode() + b"\n%%EOF\n")
    return bytes(out)


@unittest.skipUnless(shutil.which(gen.PDFTOTEXT), "pdftotext not installed")
class PdfReader(unittest.TestCase):
    """Reading a real PDF, with the real reader."""

    def test_a_pdf_with_text_is_read(self):
        got = gen._pdf_text(_tiny_pdf("Parent meeting September 14"))
        self.assertIn("Parent meeting September 14", " ".join(got.split()))

    def test_rubbish_bytes_yield_nothing_and_do_not_raise(self):
        self.assertEqual(gen._pdf_text(b"this is not a pdf at all"), "")

    def test_empty_input_yields_nothing(self):
        self.assertEqual(gen._pdf_text(b""), "")


class PdfReaderAbsent(unittest.TestCase):
    """A missing reader must degrade, never crash the brief."""

    def test_missing_binary_returns_empty(self):
        real = gen.PDFTOTEXT
        gen.PDFTOTEXT = "/nonexistent/pdftotext"
        try:
            self.assertEqual(gen._pdf_text(b"%PDF-1.4"), "")
        finally:
            gen.PDFTOTEXT = real


class Attachments(unittest.TestCase):
    """How a PDF part reaches the prompt. The reader itself is stubbed, so
    these run anywhere -- only the walking and labelling is under test."""

    def setUp(self):
        self._real = gen._pdf_text
        gen._pdf_text = lambda raw: "Picture day is October 3." if raw else ""

    def tearDown(self):
        gen._pdf_text = self._real

    def msg(self, parts):
        return {"payload": {"mimeType": "multipart/mixed", "parts": parts}}

    TEXT = {"mimeType": "text/plain", "filename": "",
            "body": {"data": _b64(b"See the attached newsletter.")}}
    PDF = {"mimeType": "application/pdf", "filename": "Newsletter-wk4.pdf",
           "body": {"data": _b64(b"%PDF-1.4 pretend")}}

    def test_pdf_text_is_appended_and_labelled(self):
        out = gen.message_body(self.msg([self.TEXT, self.PDF]))
        self.assertIn("See the attached newsletter.", out)
        self.assertIn("--- attached file: Newsletter-wk4.pdf ---", out)
        self.assertIn("Picture day is October 3.", out)

    def test_the_message_text_still_comes_first(self):
        """Evidence quotes must stay locatable: the forward's own words, then
        the document, not interleaved."""
        out = gen.message_body(self.msg([self.TEXT, self.PDF]))
        self.assertLess(out.index("See the attached"), out.index("attached file:"))

    def test_a_pdf_alone_still_produces_a_body(self):
        """The real case: a one-line forward whose dates are all in the PDF."""
        out = gen.message_body(self.msg([self.PDF]))
        self.assertIn("Picture day is October 3.", out)

    def test_pdf_detected_by_extension_when_the_mime_type_is_generic(self):
        part = {"mimeType": "application/octet-stream",
                "filename": "Newsletter-wk4.PDF",
                "body": {"data": _b64(b"%PDF-1.4 pretend")}}
        self.assertIn("Picture day", gen.message_body(self.msg([part])))

    def test_an_unreadable_pdf_is_skipped_not_labelled(self):
        gen._pdf_text = lambda raw: ""
        out = gen.message_body(self.msg([self.TEXT, self.PDF]))
        self.assertIn("See the attached newsletter.", out)
        self.assertNotIn("attached file:", out)

    def test_a_non_pdf_attachment_is_still_ignored(self):
        part = {"mimeType": "image/jpeg", "filename": "photo.jpg",
                "body": {"data": _b64(b"\xff\xd8\xff binary")}}
        out = gen.message_body(self.msg([self.TEXT, part]))
        self.assertEqual(out.strip(), "See the attached newsletter.")

    def test_a_remote_attachment_with_no_data_is_skipped(self):
        part = {"mimeType": "application/pdf", "filename": "big.pdf",
                "body": {"attachmentId": "abc123"}}
        out = gen.message_body(self.msg([self.TEXT, part]))
        self.assertNotIn("attached file:", out)

    def test_the_overall_body_limit_still_applies(self):
        gen._pdf_text = lambda raw: "x" * 50000
        out = gen.message_body(self.msg([self.TEXT, self.PDF]), limit=500)
        self.assertEqual(len(out), 500)


if __name__ == "__main__":
    unittest.main(verbosity=2)
