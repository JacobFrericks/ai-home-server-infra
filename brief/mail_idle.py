#!/usr/bin/env python3
"""mail_idle.py — hold an IMAP IDLE connection and react when mail arrives.

Replaces polling the mailbox on a timer. IDLE is a push: the server tells us
the moment something lands, over a connection that is opened ONCE.

WHY THIS IS SAFER THAN POLLING, not just faster
-----------------------------------------------
The hourly poll exists because repeated LOGINS look like account takeover --
an app password on this account has already been revoked once, and the failure
surfaces as "Invalid credentials", indistinguishable from a wrong password.
IDLE logs in once and holds. That is a long-lived session, not a login storm.
So this is better freshness AND a smaller footprint.

THE FAILURE MODE IS SILENCE
---------------------------
A hung daemon is indistinguishable from a quiet mailbox: no error, no alert,
just nothing ever happening again. Everything defensive here exists for that:

  * A heartbeat file, touched every loop. Something else watches its age.
  * IDLE is re-issued every RENEW seconds. RFC 2177 says a client MUST do this
    at least every 29 minutes, and Gmail drops the connection if it does not.
    The reconnect is the normal path, not the exception.
  * A socket timeout, so a half-open connection cannot block forever. Without
    it a dead TCP session looks exactly like an idle one.
  * The poll is REDUCED, not removed. If this daemon dies quietly, mail is
    late by hours rather than lost entirely.

No third-party dependency on purpose: `python3-imapclient` would be an
unpinned package on the host, in a deployment that pins every container by
digest. The protocol is four lines.
"""
import argparse
import imaplib
import os
import select
import socket
import ssl
import subprocess
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))

# Gmail drops an idle connection at ~29 minutes; RFC 2177 requires the client
# to re-issue before then. Renewing at 24 keeps a safe margin.
RENEW = int(os.environ.get("IDLE_RENEW", "1440"))
# Must exceed RENEW, or every renewal looks like a timeout.
SOCK_TIMEOUT = int(os.environ.get("IDLE_SOCK_TIMEOUT", str(RENEW + 120)))
# Several messages can arrive together; one burst should mean one run.
DEBOUNCE = int(os.environ.get("IDLE_DEBOUNCE", "20"))
HEARTBEAT = os.environ.get("IDLE_HEARTBEAT", "/tmp/brief-idle-heartbeat")
BACKOFF_MAX = 300


def log(msg):
    print(f"{datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)


def beat():
    """Touch the heartbeat. Its AGE is the only evidence this is alive."""
    try:
        with open(HEARTBEAT, "w") as f:
            f.write(str(int(time.time())))
    except OSError:
        pass


class IdleSession:
    """One IMAP connection, held open in IDLE."""

    def __init__(self, env):
        self.env = env
        self.M = None

    def connect(self):
        self.M = imaplib.IMAP4_SSL("imap.gmail.com", 993,
                                   ssl_context=ssl.create_default_context())
        self.M.login(self.env["BOT_EMAIL"],
                     self.env["BOT_IMAP_APP_PASSWORD"].replace(" ", ""))
        # READ-ONLY: watching for mail must never mark anything seen. Only the
        # extraction step, after it has actually processed a message, does that.
        self.M.select("INBOX", readonly=True)
        if "IDLE" not in self.M.capabilities:
            raise RuntimeError("server does not advertise IDLE")
        self.M.sock.settimeout(SOCK_TIMEOUT)
        log(f"connected as {self.env['BOT_EMAIL']}; IDLE supported")

    def close(self):
        try:
            self.M.logout()
        except Exception:
            pass
        self.M = None

    def wait(self) -> bool:
        """Enter IDLE and block. True if mail arrived, False on renewal.

        imaplib has no idle() in this Python, so the protocol is driven
        directly. It is small: send IDLE, expect a continuation, read untagged
        responses until something interesting, then DONE.
        """
        tag = self.M._new_tag()
        self.M.send(tag + b" IDLE\r\n")
        resp = self.M._get_line()
        if not resp.startswith(b"+"):
            raise RuntimeError(f"IDLE refused: {resp!r}")

        deadline = time.monotonic() + RENEW
        got_mail = False
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break                       # renewal, not a failure

                # select() rather than a socket timeout. Letting the read
                # itself time out poisons imaplib's buffered reader -- the
                # next call raises "cannot read from timed out object", the
                # whole session gets torn down, and every renewal becomes a
                # fresh LOGIN. That is the login storm this design exists to
                # avoid, reintroduced at 24-minute intervals. Waiting for
                # readability first means the socket never enters that state.
                ready, _, _ = select.select([self.M.sock], [], [], remaining)
                if not ready:
                    break                       # nothing arrived; renew

                line = self.M._get_line()
                beat()
                # EXISTS accompanies an arrival. RECENT is also emitted, but
                # EXISTS is the one that is always present.
                if b"EXISTS" in line:
                    log(f"mail: {line.decode(errors='replace').strip()}")
                    got_mail = True
                    break
        finally:
            # Leave IDLE cleanly so the SAME connection serves the next cycle.
            self.M.send(b"DONE\r\n")
            for _ in range(20):
                if self.M._get_line().startswith(tag):
                    break
        return got_mail


def run_extract(runner: str, dry: bool = False) -> None:
    """Hand off to the existing pipeline. This daemon decides WHEN, never WHAT.

    Kept deliberately thin: everything about reading mail, judging relevance
    and writing to-dos already exists, is tested, and is reachable from the
    timer as well. Duplicating any of it here would create a second path that
    drifts.
    """
    if dry:
        log("DRY RUN: would trigger the brief runner")
        return
    try:
        r = subprocess.run([runner, "mail"], timeout=900,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log(f"runner exited {r.returncode}")
    except subprocess.TimeoutExpired:
        log("runner TIMED OUT after 900s")
    except Exception as e:
        log(f"runner failed: {type(e).__name__}: {e}")


def main(argv=None) -> int:
    import importlib.util
    sp = importlib.util.spec_from_file_location(
        "fl", os.path.join(HERE, "fetch_live.py"))
    fl = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(fl)

    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--runner",
                   default=os.path.expanduser("~/bin/fridge-brief-run"),
                   help="what to run when mail arrives")
    p.add_argument("--dry-run", action="store_true",
                   help="watch and log, but never trigger the runner")
    p.add_argument("--once", action="store_true",
                   help="exit after one IDLE cycle (for testing)")
    a = p.parse_args(argv)

    env = fl.load_env()
    session = IdleSession(env)
    backoff = 5
    pending_since = None

    log(f"starting; renew={RENEW}s debounce={DEBOUNCE}s heartbeat={HEARTBEAT}")
    while True:
        try:
            if session.M is None:
                session.connect()
                backoff = 5              # a good connection resets the penalty
            beat()
            got = session.wait()

            if got:
                # Several messages often land together -- a forwarded batch, a
                # newsletter and its reply. One burst should mean one run, not
                # one run per message.
                if pending_since is None:
                    pending_since = time.monotonic()
                time.sleep(DEBOUNCE)
                beat()
                run_extract(a.runner, a.dry_run)
                pending_since = None

            if a.once:
                session.close()
                return 0

        except KeyboardInterrupt:
            log("interrupted")
            session.close()
            return 0
        except Exception as e:
            # Every failure path lands here: dropped TCP, expired credentials,
            # Gmail maintenance. Reconnecting with a ceiling means a permanent
            # problem retries forever without hammering, and a transient one
            # recovers in seconds.
            log(f"ERROR {type(e).__name__}: {e}; reconnecting in {backoff}s")
            session.close()
            beat()                        # still alive, just not connected
            time.sleep(backoff)
            backoff = min(backoff * 2, BACKOFF_MAX)


if __name__ == "__main__":
    raise SystemExit(main())
