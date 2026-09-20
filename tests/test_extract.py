#!/usr/bin/env python3
"""Tests for brief/extract.py — the AI step.

The model itself is not tested here; its judgement is not deterministic. What
IS tested is everything wrapped around it: the grade arithmetic that decides
what "relevant" even means, and the guards that catch the model being wrong.

Run: python3 tests/test_extract.py
"""
import importlib.util
import os
import sys
import unittest
from datetime import date

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "ex", os.path.join(ROOT, "brief", "extract.py"))
ex = importlib.util.module_from_spec(spec)
sys.modules["ex"] = ex
spec.loader.exec_module(ex)

HOUSEHOLD = {
    "children": [
        {"name": "Kid A", "anchor_grade": 2, "anchor_school_year": 2026},
        {"name": "Kid B", "anchor_grade": -1, "anchor_school_year": 2026},
    ],
    "grade_labels": {"-1": "Begindergarten"},
    "school_year_starts_month": 8,
}


class Grades(unittest.TestCase):
    """Grades are computed from an anchor, never stored as a literal.

    A stored "2nd grade" is silently wrong from the next August onwards, and
    the model would filter a whole year of mail against a stale year without
    anything looking broken.
    """

    def labels(self, d):
        return [c["grade_label"] for c in ex.children_now(HOUSEHOLD, d)]

    def test_today(self):
        self.assertEqual(self.labels(date(2026, 9, 20)),
                         ["2nd grade", "Begindergarten"])

    def test_rolls_over_in_august_not_january(self):
        self.assertEqual(self.labels(date(2027, 7, 31)),
                         ["2nd grade", "Begindergarten"])
        self.assertEqual(self.labels(date(2027, 8, 1)),
                         ["3rd grade", "kindergarten"])

    def test_custom_label_belongs_to_the_GRADE_not_the_child(self):
        """Keyed to the child, a five-year-old stays "Begindergarten" forever."""
        self.assertEqual(self.labels(date(2027, 8, 1))[1], "kindergarten")
        self.assertEqual(self.labels(date(2028, 8, 1))[1], "1st grade")

    def test_pre_kindergarten_is_negative(self):
        """Begindergarten comes BEFORE kindergarten, so it is -1, not 0."""
        self.assertEqual(ex.grade_now(-1, 2026, date(2026, 9, 1)), -1)
        self.assertEqual(ex.grade_now(-1, 2026, date(2027, 9, 1)), 0)

    def test_ordinal_suffixes(self):
        f = ex.grade_label
        for g, want in ((1, "1st grade"), (2, "2nd grade"), (3, "3rd grade"),
                        (4, "4th grade"), (11, "11th grade"), (12, "12th grade"),
                        (0, "kindergarten"), (-1, "pre-kindergarten")):
            self.assertEqual(f(g), want)

    def test_school_year_boundary(self):
        self.assertEqual(ex.school_year(date(2026, 7, 31)), 2025)
        self.assertEqual(ex.school_year(date(2026, 8, 1)), 2026)


class EvidenceGuard(unittest.TestCase):
    """The load-bearing guard. It caught a fabricated item on the first real
    run against live mail, before any of this was wired to write anything."""

    SOURCE = ("Grandparents' Day will be held Friday, September 11, from "
              "4:30-6:00 p.m.\nStudents grades Begindergarten through 5th "
              "grade are invited to bring their grandparents.")
    KEYS = ["kid-a", "kid-b"]

    def keep(self, items):
        return [i["title"] for i in
                ex.verify_items(items, self.SOURCE, self.KEYS)[0]]

    def item(self, **kw):
        base = {"title": "Attend Grandparents' Day", "due": "2026-09-11",
                "applies_to": "household",
                "evidence": "Grandparents' Day will be held Friday, September 11"}
        base.update(kw)
        return base

    def test_real_quote_is_kept(self):
        self.assertEqual(self.keep([self.item()]), ["Attend Grandparents' Day"])

    def test_fabricated_quote_is_dropped(self):
        """To invent a task the model must invent a quote -- and that is
        checkable, which is the whole point."""
        self.assertEqual(
            self.keep([self.item(evidence="Bring a permission slip by Friday")]),
            [])

    def test_quote_matches_across_rewrapped_lines(self):
        """Mail is hard-wrapped; a quote spanning a line break is still real."""
        self.assertEqual(
            self.keep([self.item(
                evidence="held Friday, September 11, from 4:30-6:00 p.m.")]),
            ["Attend Grandparents' Day"])

    def test_trivially_short_evidence_is_dropped(self):
        """A two-word quote matches almost anything, so it proves nothing."""
        self.assertEqual(self.keep([self.item(evidence="Day")]), [])

    def test_not_us_is_dropped(self):
        """The Middle School Retreat lands here."""
        self.assertEqual(self.keep([self.item(applies_to=ex.NOT_US)]), [])

    def test_unknown_applies_to_is_dropped(self):
        """Fails closed: an unrecognised classification is not a pass."""
        self.assertEqual(self.keep([self.item(applies_to="kid-z")]), [])

    def test_missing_title_is_dropped(self):
        self.assertEqual(self.keep([self.item(title="  ")]), [])

    def test_bad_date_loses_the_date_not_the_item(self):
        """A malformed due date is the model's error; the item may still be
        real, so it survives without a date rather than vanishing."""
        kept, _ = ex.verify_items([self.item(due="next Friday")],
                                  self.SOURCE, self.KEYS)
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0]["due"], "")

    def test_drop_reasons_are_reported(self):
        """Every rejection is explained, so tuning the prompt is possible."""
        _, dropped = ex.verify_items(
            [self.item(applies_to=ex.NOT_US), self.item(evidence="nope nope nope")],
            self.SOURCE, self.KEYS)
        self.assertEqual(len(dropped), 2)
        self.assertTrue(all(why for _, why in dropped))

    def test_empty_and_none_are_safe(self):
        for bad in (None, []):
            self.assertEqual(ex.verify_items(bad, self.SOURCE, self.KEYS)[0], [])


class SenderAllowlist(unittest.TestCase):
    """The outer boundary. The bot has a public address, so without this
    anyone who learns it can put a line on the family's kitchen wall and have
    the model read their text looking for instructions."""

    TRUSTED = ["parent-a@example.com", "parent-b@example.com"]

    def allowed(self, headers):
        return ex.sender_allowed(headers, self.TRUSTED)[0]

    def test_trusted_sender_accepted(self):
        self.assertTrue(self.allowed({"From": "A <parent-a@example.com>"}))

    def test_stranger_refused(self):
        self.assertFalse(self.allowed({"From": "Someone <stranger@example.com>"}))

    def test_lookalike_domain_refused(self):
        """The address appears as a SUBSTRING of a hostile domain. A naive
        `in` check passes this; matching whole addresses does not."""
        self.assertFalse(self.allowed(
            {"From": "A <parent-a@example.com.evil.test>"}))

    def test_school_writing_direct_is_refused(self):
        """Forwarding is the permission. A sender the family never chose does
        not get in just by being legitimate."""
        self.assertFalse(self.allowed({"From": "School <office@school.example.edu>"}))

    def test_gmail_filter_forwarding_is_accepted(self):
        """Auto-forwarded mail keeps the ORIGINAL sender in From, so a
        From-only check would reject exactly the mail the filters exist to
        deliver. The forwarding chain is what proves a trusted account sent it."""
        self.assertTrue(self.allowed({
            "From": "School <office@school.example.edu>",
            "X-Forwarded-For": "parent-a@example.com bot@example.com"}))

    def test_envelope_sender_counts(self):
        """Return-Path is set by the receiving server, not asserted by the
        client, so it is the stronger of the two when they disagree."""
        self.assertTrue(self.allowed(
            {"From": "Display Name Only", "Return-Path": "<parent-b@example.com>"}))

    def test_case_is_ignored(self):
        self.assertTrue(self.allowed({"From": "<PARENT-A@Example.COM>"}))

    def test_empty_allowlist_accepts_everything(self):
        """Backwards-compatible, and main() warns loudly when it happens --
        silently accepting everything would be the worse failure."""
        ok, why = ex.sender_allowed({"From": "anyone@anywhere.test"}, [])
        self.assertTrue(ok)
        self.assertIn("no allowlist", why)

    def test_missing_headers_refused(self):
        for h in ({}, {"From": ""}, {"From": "not an address"}):
            self.assertFalse(self.allowed(h), f"accepted {h!r}")

    def test_refusal_says_why(self):
        _, why = ex.sender_allowed({"From": "x@bad.test"}, self.TRUSTED)
        self.assertIn("x@bad.test", why)


def ar(value):
    return [{"name": "Authentication-Results", "value": value}]


class Authentication(unittest.TestCase):
    """The second gate. The allowlist says who a message CLAIMS to be from;
    this says whether the receiving server verified that claim."""

    TRUSTED = ["parent@gmail.com"]
    GOOD = ar("mx.google.com; dkim=pass header.i=@gmail.com header.s=x; "
              "spf=pass (google.com: domain of parent@gmail.com designates "
              "1.2.3.4 as permitted sender); dmarc=pass")

    def check(self, headers, raw):
        return ex.sender_allowed(headers, self.TRUSTED, raw, require_auth=True)

    def test_aligned_dkim_accepted(self):
        ok, why = self.check({"From": "P <parent@gmail.com>"}, self.GOOD)
        self.assertTrue(ok)
        self.assertIn("aligned", why)

    def test_valid_signature_for_the_WRONG_domain_is_refused(self):
        """THE attack this exists to stop. An attacker can sign their own mail
        perfectly and get dkim=pass -- for THEIR domain. Checking the pass
        without checking the alignment is a gate that feels strong and stops
        nothing."""
        ok, _ = self.check({"From": "P <parent@gmail.com>"},
                           ar("mx.google.com; dkim=pass header.i=@evil.test "
                              "header.s=k1; spf=pass (google.com: domain of "
                              "bot@evil.test designates 9.9.9.9 as permitted sender)"))
        self.assertFalse(ok)

    def test_sender_injected_results_are_ignored(self):
        """A message can carry its own Authentication-Results. Only the one
        stamped by the server that actually received the mail counts."""
        ok, why = self.check({"From": "P <parent@gmail.com>"},
                             ar("attacker-controlled; dkim=pass header.i=@gmail.com"))
        self.assertFalse(ok)
        self.assertIn("mx.google.com", why)

    def test_forged_header_before_the_real_one(self):
        """Taking "the first Authentication-Results" would pass this."""
        raw = (ar("evil.test; dkim=pass header.i=@gmail.com")
               + ar("mx.google.com; dkim=pass header.i=@evil.test"))
        self.assertFalse(self.check({"From": "P <parent@gmail.com>"}, raw)[0])

    def test_no_auth_headers_refused(self):
        self.assertFalse(self.check({"From": "P <parent@gmail.com>"}, [])[0])

    def test_dkim_fail_refused(self):
        self.assertFalse(self.check(
            {"From": "P <parent@gmail.com>"},
            ar("mx.google.com; dkim=fail header.i=@gmail.com; spf=fail"))[0])

    def test_aligned_spf_alone_is_enough(self):
        """DMARC is 'at least one aligned mechanism'. SPF authenticates the
        envelope sender, which is what matters for a direct send."""
        ok, why = self.check({"From": "P <parent@gmail.com>"},
                             ar("mx.google.com; spf=pass (google.com: domain of "
                                "parent@gmail.com designates 1.2.3.4 as "
                                "permitted sender)"))
        self.assertTrue(ok)
        self.assertIn("spf", why)

    def test_arc_pass_covers_forwarded_mail(self):
        """Forwarding routinely BREAKS the original DKIM signature -- that is
        normal, and is the reason ARC exists. Without this, turning
        verification on would silently kill auto-forwarded mail."""
        ok, why = ex.sender_allowed(
            {"From": "School <office@school.example.edu>",
             "X-Forwarded-For": "parent@gmail.com bot@example.com"},
            self.TRUSTED, ar("mx.google.com; dkim=fail; spf=softfail; arc=pass (i=1)"),
            require_auth=True)
        self.assertTrue(ok)
        self.assertIn("arc", why)

    def test_verification_can_be_turned_off(self):
        """Off is a deliberate choice, and main() warns on every run."""
        self.assertTrue(ex.sender_allowed(
            {"From": "P <parent@gmail.com>"}, self.TRUSTED, [], require_auth=False)[0])

    def test_untrusted_sender_still_refused_even_if_authenticated(self):
        """Being cryptographically genuine is not the same as being welcome."""
        ok, _ = self.check({"From": "Stranger <someone@gmail.com>"}, self.GOOD)
        self.assertFalse(ok)

    def test_default_config_requires_authentication(self):
        self.assertTrue(ex.DEFAULT_HOUSEHOLD["require_authentication"])


class Schema(unittest.TestCase):
    def test_applies_to_enum_is_built_from_the_household(self):
        sch = ex._schema(["kid-a", "kid-b"])
        enum = sch["properties"]["items"]["items"]["properties"]["applies_to"]["enum"]
        self.assertEqual(enum, ["kid-a", "kid-b", "household", ex.NOT_US])

    def test_no_actionable_flag(self):
        """Removed deliberately: the model used it to talk itself out of
        Grandparents' Day, a gala deadline and a parent meeting."""
        req = ex._schema(["kid-a"])["properties"]["items"]["items"]["required"]
        self.assertNotIn("action_needed", req)

    def test_prompt_names_the_children_and_their_grades(self):
        kids = ex.children_now(HOUSEHOLD, date(2026, 9, 20))
        p = ex.build_prompt({"subject": "s", "body": "b"}, kids, date(2026, 9, 20))
        self.assertIn("Begindergarten", p)
        self.assertIn("2nd grade", p)
        self.assertIn("2026-09-20", p)


class Config(unittest.TestCase):
    def test_missing_config_falls_back_to_placeholders(self):
        """Real names are git-ignored; the tests must run without them."""
        hh = ex.load_household("/nonexistent/household.json")
        self.assertEqual(hh, ex.DEFAULT_HOUSEHOLD)
        self.assertTrue(ex.children_now(hh, date(2026, 9, 20)))

    def test_default_config_carries_no_real_names(self):
        for c in ex.DEFAULT_HOUSEHOLD["children"]:
            self.assertTrue(c["name"].startswith("Child"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
