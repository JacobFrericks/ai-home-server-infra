#!/usr/bin/env python3
"""Fetch the real inputs for the brief, in the exact shapes generate_brief expects.

This is the ONLY file that talks to the network. Everything downstream is the
already-tested transform layer, which is why the fixtures and this module have
to agree on shape -- if they ever drift, the tests pass and the wall goes blank.

Reads credentials from .env.family. Prints no secrets.

  ./fetch_live.py --out /tmp/brief.json      # fetch + build in one step
  ./fetch_live.py --dump-raw /tmp/raw.json   # just the raw upstream payloads
"""
import argparse
import email.utils
import imaplib
import json
import os
import ssl
import sys
import urllib.parse
import urllib.request
import urllib.error
import time
from datetime import date, datetime, timedelta

MAX_AGE_SENTINEL = object()

HERE = os.path.dirname(os.path.abspath(__file__))
ENV = os.environ.get("FAMILY_ENV", os.path.expanduser("~/docker/ai-stack/.env.family"))

# Mail is cached and refreshed on its OWN, much slower schedule.
#
# WHY, so this does not get "simplified" later: the calendar/tasks job runs
# every 15 minutes, and running IMAP with it would be ~96 logins a day from a
# server IP. An app password on this account was already revoked once. Google
# treats frequent automated IMAP auth as the signature of a compromised
# account, and the failure looks like a wrong password rather than a rate
# limit -- so it costs an hour of debugging, not a retry.
#
# Nothing needs minute-level mail. The panel itself only re-reads its file
# every 10 minutes.
# extract.py writes the model's headline here on the hourly run; the 15-minute
# job reuses it and never calls the model itself. A missing or stale file is
# not an error -- generate_brief's deterministic sentence takes over, so the
# wall never goes blank because the GPU was busy.
HEADLINE_CACHE = os.environ.get("HEADLINE_CACHE", "/tmp/brief-headline.txt")
HEADLINE_MAX_AGE = int(os.environ.get("HEADLINE_MAX_AGE", "86400"))

MAIL_CACHE = os.environ.get("MAIL_CACHE", "/tmp/brief-mail-cache.json")
MAIL_MAX_AGE = int(os.environ.get("MAIL_MAX_AGE", "3600"))   # seconds


def load_env(path=ENV) -> dict:
    out = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                out[k.strip()] = v.strip().strip('"').strip("'")
    return out


# --- Google -------------------------------------------------------------------

def access_token(env: dict, prefix: str) -> str:
    """Trade a refresh token for a short-lived access token."""
    data = urllib.parse.urlencode({
        "client_id": env[f"{prefix}_CLIENT_ID"],
        "client_secret": env[f"{prefix}_CLIENT_SECRET"],
        "refresh_token": env[f"{prefix}_REFRESH_TOKEN"],
        "grant_type": "refresh_token",
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)["access_token"]


def _get(url: str, token: str) -> dict:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def fetch_calendar(env: dict, days: int = 2) -> dict:
    """Events from now to +days, already expanded and ordered.

    singleEvents=true matters: without it a weekly recurrence comes back as one
    master event with an RRULE, and today's instance is simply absent.
    """
    tok = access_token(env, "GOOGLE")
    now = datetime.now().astimezone()
    q = urllib.parse.urlencode({
        "timeMin": now.replace(hour=0, minute=0, second=0, microsecond=0).isoformat(),
        "timeMax": (now + timedelta(days=days)).isoformat(),
        "singleEvents": "true",
        "orderBy": "startTime",
        "maxResults": "50",
    })
    cal = urllib.parse.quote(env["FAMILY_CALENDAR_ID"], safe="")
    return _get(f"https://www.googleapis.com/calendar/v3/calendars/{cal}/events?{q}", tok)


def fetch_google_tasks(env: dict, account: str) -> dict:
    """tasklists.list plus tasks.list per list, in the fixture's shape."""
    tok = access_token(env, f"TASKS_{account.upper().replace('-', '_')}")
    lists = _get("https://tasks.googleapis.com/tasks/v1/users/@me/lists", tok)
    tasks = {}
    for L in lists.get("items", []):
        q = urllib.parse.urlencode({"showCompleted": "false", "maxResults": "100"})
        tasks[L["id"]] = _get(
            f"https://tasks.googleapis.com/tasks/v1/lists/{L['id']}/tasks?{q}", tok)
    return {"tasklists": lists, "tasks": tasks}


# --- Gmail over IMAP ----------------------------------------------------------

def cached_mail(env: dict, max_age: int = MAX_AGE_SENTINEL) -> tuple:
    """(payload, source) -- reuse the cache unless it is older than max_age.

    Returns the cache even when STALE if a live fetch fails: a slightly old
    mail list on the wall beats an empty one, and the panel has no way to tell
    the difference between "no mail" and "could not reach Gmail".
    """
    max_age = MAIL_MAX_AGE if max_age is MAX_AGE_SENTINEL else max_age
    cached, age = None, None
    try:
        age = time.time() - os.path.getmtime(MAIL_CACHE)
        with open(MAIL_CACHE) as f:
            cached = json.load(f)
    except (OSError, ValueError):
        pass

    if cached is not None and age is not None and age < max_age:
        return cached, f"cache ({int(age // 60)}m old)"

    try:
        fresh = fetch_mail(env)
        tmp = MAIL_CACHE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(fresh, f)
        os.replace(tmp, MAIL_CACHE)
        return fresh, "live"
    except Exception as e:
        if cached is not None:
            return cached, f"STALE cache ({int(age // 60)}m) -- {type(e).__name__}"
        raise


def fetch_mail(env: dict, since_days: int = 2, limit: int = 20) -> dict:
    """Recent messages, shaped like the Gmail API fixture.

    IMAP is used rather than the Gmail API on purpose: reading mail through the
    API is a *restricted* scope and can require a paid security assessment. An
    app password over IMAP gives the same full message bodies with none of that.

    The mailbox is opened READ-ONLY so fetching never marks anything as seen --
    a person forwarding mail here should still see it unread in their own copy.
    """
    M = imaplib.IMAP4_SSL("imap.gmail.com", 993, ssl_context=ssl.create_default_context())
    M.login(env["BOT_EMAIL"], env["BOT_IMAP_APP_PASSWORD"].replace(" ", ""))
    M.select("INBOX", readonly=True)
    since = (date.today() - timedelta(days=since_days)).strftime("%d-%b-%Y")
    # UID rather than sequence number: sequence numbers shift as the mailbox
    # changes, and extract.py flags these messages from a different session.
    ok, data = M.uid("SEARCH", None, f'(SINCE "{since}")')
    ids = (data[0].split() if ok == "OK" and data[0] else [])[-limit:]

    msgs = []
    for i in ids:
        ok, raw = M.uid("FETCH", i, "(BODY.PEEK[])")   # PEEK: do not set \\Seen
        if ok != "OK" or not raw or not raw[0]:
            continue
        import email as _email
        m = _email.message_from_bytes(raw[0][1])

        # Re-shape into the Gmail API structure the transforms already parse,
        # so one code path serves both fixtures and live mail.
        def part(p):
            # `filename` is part of the Gmail API part shape too, so carrying it
            # keeps one code path over fixtures and live mail. It is what labels
            # an attachment's text in the prompt.
            d = {"mimeType": p.get_content_type(),
                 "filename": p.get_filename() or "", "body": {}}
            if p.is_multipart():
                d["parts"] = [part(x) for x in p.get_payload()]
            else:
                payload = p.get_payload(decode=True) or b""
                import base64
                d["body"] = {"size": len(payload),
                             "data": base64.urlsafe_b64encode(payload).decode().rstrip("=")}
            return d

        hdrs = [{"name": k, "value": v} for k, v in m.items()]
        dt = email.utils.parsedate_to_datetime(m.get("Date")) if m.get("Date") else None
        payload = part(m)
        payload["headers"] = hdrs
        msgs.append({
            # The IMAP UID, so extract.py can flag exactly this message later.
            "_uid": i.decode() if isinstance(i, bytes) else str(i),
            "id": m.get("Message-ID", str(i)),
            "threadId": (m.get("In-Reply-To") or m.get("Message-ID") or str(i)),
            "labelIds": ["UNREAD"],
            "internalDate": str(int(dt.timestamp() * 1000)) if dt else "0",
            "payload": payload,
        })
    M.logout()
    return {"messages": msgs}


# --- Home Assistant -----------------------------------------------------------

def fetch_ha_todos(env: dict, entities: list) -> dict:
    """todo.get_items, in the service_response shape the transforms expect."""
    if not entities:
        return {"service_response": {}}
    body = json.dumps({"entity_id": entities}).encode()
    req = urllib.request.Request(
        f"{env['HA_URL']}/api/services/todo/get_items?return_response",
        data=body, method="POST",
        headers={"Authorization": f"Bearer {env['HA_TOKEN']}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


# --- assembly -----------------------------------------------------------------

def main(argv=None) -> int:
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "gen", os.path.join(HERE, "generate_brief.py"))
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)
    wx = gen.weather

    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-o", "--out", help="write brief.json here (atomic)")
    p.add_argument("--dump-raw", help="write the raw upstream payloads here instead")
    p.add_argument("--env", default=ENV)
    p.add_argument("--refresh-mail", action="store_true",
                   help="force an IMAP fetch; without it the cache is reused "
                        "while younger than MAIL_MAX_AGE (default 1h)")
    a = p.parse_args(argv)

    env = load_env(a.env)
    lists = gen.load_lists()

    # Each source is fetched independently and a failure is contained: a dead
    # IMAP connection must not cost the wall its calendar. The panel keeps its
    # last good payload anyway, but partial fresh data beats none.
    raw = {"calendar": {"items": []}, "mail": {"messages": []},
           "todos": {"service_response": {}, "google_tasks": {}},
           "weather": None}
    errs = []

    try:
        raw["calendar"] = fetch_calendar(env)
        print(f"calendar : {len(raw['calendar'].get('items', []))} event(s)", file=sys.stderr)
    except Exception as e:
        errs.append(f"calendar: {type(e).__name__}")

    try:
        raw["mail"], how = cached_mail(env, 0 if a.refresh_mail else MAIL_MAX_AGE)
        print(f"mail     : {len(raw['mail']['messages'])} message(s) [{how}]", file=sys.stderr)
        if how.startswith("STALE"):
            errs.append(f"mail: serving stale cache")
    except Exception as e:
        errs.append(f"mail: {type(e).__name__}")

    ents = [s["entity"] for s in lists if s.get("source", "ha") == "ha" and s.get("entity")]
    try:
        raw["todos"].update(fetch_ha_todos(env, ents))
        print(f"ha todos : {len(raw['todos'].get('service_response', {}))} list(s)", file=sys.stderr)
    except Exception as e:
        errs.append(f"ha: {type(e).__name__}")

    for acct in {s["account"] for s in lists if s.get("source") == "google_tasks"}:
        try:
            raw["todos"].setdefault("google_tasks", {})[acct] = fetch_google_tasks(env, acct)
            print(f"tasks[{acct}]: ok", file=sys.stderr)
        except Exception as e:
            errs.append(f"tasks[{acct}]: {type(e).__name__}")

    try:
        raw["weather"] = wx.fetch(env)
        got = len((wx.hours(raw["weather"]) or {}).get("hours", []))
        print(f"weather  : {got} hour(s) [{raw['weather']['provider']}]", file=sys.stderr)
    except Exception as e:
        errs.append(f"weather: {type(e).__name__}")

    for e in errs:
        print(f"WARN {e}", file=sys.stderr)

    if a.dump_raw:
        with open(a.dump_raw, "w") as f:
            json.dump(raw, f, indent=2)
        print(f"wrote {a.dump_raw}", file=sys.stderr)
        return 0

    doc = gen.build(raw["calendar"], raw["mail"], raw["todos"], date.today(),
                    lists, raw.get("weather"))

    # Prefer the model's sentence when there is a fresh one.
    # Same-day AND fresh. The age limit alone let a sentence written at 23:50
    # introduce the following morning, naming things that had already happened.
    try:
        written = datetime.fromtimestamp(os.path.getmtime(HEADLINE_CACHE))
        if (written.date() == date.today()
                and time.time() - written.timestamp() < HEADLINE_MAX_AGE):
            with open(HEADLINE_CACHE) as f:
                h = f.read().strip()
            if h:
                doc["headline"] = h
                print("headline : from model", file=sys.stderr)
    except OSError:
        print("headline : generated (no model headline cached)", file=sys.stderr)
    if errs:
        doc["warnings"] = errs
    text = json.dumps(doc, indent=2)
    if a.out:
        tmp = a.out + ".tmp"
        with open(tmp, "w") as f:
            f.write(text + "\n")
        os.replace(tmp, a.out)        # the Pi may be fetching mid-write
        print(f"wrote {a.out}", file=sys.stderr)
    else:
        print(text)
    # A total failure is worth a non-zero exit so a CronJob shows red.
    return 1 if len(errs) >= 3 else 0


if __name__ == "__main__":
    raise SystemExit(main())
