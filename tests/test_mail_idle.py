#!/usr/bin/env python3
"""Tests for brief/mail_idle.py.

The IMAP conversation itself is not unit-testable without a server, so what is
covered here is the surrounding logic and the defaults that encode hard
protocol constraints -- the ones that, if quietly changed, produce a watcher
that looks alive and never reports anything.

Run: python3 tests/test_mail_idle.py
"""
import importlib.util
import os
import sys
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("IDLE_HEARTBEAT", "/tmp/test-idle-heartbeat")
spec = importlib.util.spec_from_file_location(
    "mi", os.path.join(ROOT, "brief", "mail_idle.py"))
mi = importlib.util.module_from_spec(spec)
sys.modules["mi"] = mi
spec.loader.exec_module(mi)


class ProtocolConstraints(unittest.TestCase):
    """Defaults that are not preferences -- they are the protocol."""

    def test_renew_is_under_the_29_minute_limit(self):
        """RFC 2177: a client MUST re-issue IDLE at least every 29 minutes,
        and Gmail drops the connection if it does not. Exceeding this gives a
        watcher that silently stops receiving anything."""
        self.assertLess(mi.RENEW, 29 * 60)
        self.assertGreater(mi.RENEW, 60, "renewing constantly defeats the point")

    def test_socket_timeout_exceeds_the_renew_interval(self):
        """If the socket could time out before a renewal is due, every normal
        renewal would look like a connection failure."""
        self.assertGreater(mi.SOCK_TIMEOUT, mi.RENEW)

    def test_backoff_is_capped(self):
        """A permanent failure -- revoked credentials, say -- must keep
        retrying without turning into a login storm."""
        self.assertLessEqual(mi.BACKOFF_MAX, 600)
        self.assertGreater(mi.BACKOFF_MAX, 30)

    def test_debounce_is_meaningful(self):
        """Several messages arrive together; one burst should mean one run."""
        self.assertGreater(mi.DEBOUNCE, 0)


class Heartbeat(unittest.TestCase):
    """The daemon's only evidence of life. A hung watcher is otherwise
    indistinguishable from a quiet mailbox."""

    def test_beat_writes_a_recent_timestamp(self):
        mi.beat()
        with open(mi.HEARTBEAT) as f:
            written = int(f.read())
        self.assertLess(abs(time.time() - written), 5)

    def test_beat_never_raises(self):
        """A heartbeat failure must not take down the watcher it monitors."""
        original = mi.HEARTBEAT
        try:
            mi.HEARTBEAT = "/nonexistent-dir/hb"
            mi.beat()                       # must not raise
        finally:
            mi.HEARTBEAT = original


class Handoff(unittest.TestCase):
    """The daemon decides WHEN, never WHAT."""

    def test_dry_run_never_executes(self):
        calls = []
        real = mi.subprocess.run
        try:
            mi.subprocess.run = lambda *a, **k: calls.append(a)
            mi.run_extract("/bin/true", dry=True)
            self.assertEqual(calls, [])
        finally:
            mi.subprocess.run = real

    def test_runner_failure_is_contained(self):
        """A broken runner must not kill the watcher -- it would stop noticing
        mail entirely, which is far worse than one missed extraction."""
        mi.run_extract("/nonexistent/runner-binary")      # must not raise

    def test_runner_is_invoked_with_the_mail_argument(self):
        """`mail` is what forces a live IMAP refresh rather than the cache."""
        seen = {}
        real = mi.subprocess.run

        class R:
            returncode = 0

        try:
            def fake(cmd, **k):
                seen["cmd"] = cmd
                return R()
            mi.subprocess.run = fake
            mi.run_extract("/bin/true")
            self.assertEqual(seen["cmd"], ["/bin/true", "mail"])
        finally:
            mi.subprocess.run = real


if __name__ == "__main__":
    unittest.main(verbosity=2)
