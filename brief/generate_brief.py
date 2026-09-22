#!/usr/bin/env python3
"""generate_brief.py — build the fridge panel's brief.json.

Turns three upstream shapes into the one small document MMM-FamilyBrief
renders: Google Calendar `events.list`, Gmail `users.messages.get`, and Home
Assistant's `todo.get_items` service response.

WHY IT READS FIXTURES TODAY
---------------------------
The bot's Google account does not exist yet and there is no Home Assistant
token. Rather than wait, every source is behind a `--source` flag that takes
either a file (a recorded response) or, later, a live client. The transforms
below are the part with the bugs in it, and they are identical either way --
so they are written and tested now, against the REAL published response shapes
rather than invented ones. When credentials land, only the fetch changes.

READING MAIL, AND WHAT REACHES THE WALL
---------------------------------------
These are two different questions and conflating them produces a useless
assistant.

WHAT THE AI READS: the whole body. "Picture day moved to October 3" is in the
body -- so are the date it moved FROM, the form deadline and the retake date.
A subject line cannot produce a to-do. Forwarding a message IS the permission
to read it; anything that should not be read simply is not forwarded. That is
the entire sharing model, and it is the same rule on both doors.

WHAT REACHES THE WALL: the distilled fact, not a paste of the email. That is a
display decision -- the panel is read from across a room and has space for
three lines -- not a restriction on what the AI may see. The panel renders
`headline`, `lines` and `todos`; the body travels in `mail` for the extraction
step and is never rendered.

The one hard rule that IS enforced here: only `household` memories may reach
the panel. This script never opens the memory directory at all, which is the
simplest possible way to hold that line.

Usage:
  ./generate_brief.py --demo                       # fixtures -> stdout
  ./generate_brief.py --events f.json --mail m.json --todos t.json -o brief.json
"""
import argparse
import base64
import binascii
import html as html_mod
import json
import os
import re
import subprocess
import sys
from datetime import date, datetime, timedelta


def _sibling(name: str, filename: str):
    """Load a neighbour in brief/ by path. These files run as scripts from a
    systemd unit, not as an installed package, so a plain import would depend
    on the caller's working directory."""
    import importlib.util
    sp = importlib.util.spec_from_file_location(
        name, os.path.join(os.path.dirname(os.path.abspath(__file__)), filename))
    mod = importlib.util.module_from_spec(sp)
    sp.loader.exec_module(mod)
    return mod


weather = _sibling("weather", "weather.py")

# The panel caps: 3 brief lines, 4 items per column. Measured against the real
# 1920x1080 wall, not chosen by taste -- see MMM-FamilyBrief.css. Emitting more
# than this is not an error, the panel just hides the overflow behind "+N more",
# but trimming here keeps the payload honest about what is actually readable.
MAX_LINES = 3
MAX_ITEMS = 4

# Anything overdue by more than this is not a live commitment -- it is a thing
# somebody forgot in 2013. Without the rule it sorts FIRST (soonest due) and
# permanently occupies the top slot on the kitchen wall, pushing today's real
# items down or off. Found in real data, not imagined.
MAX_OVERDUE_DAYS = 14

# Shown when the day is genuinely empty. The wall is a fixed band: an empty
# headline leaves a hole where a sentence should be, which reads as broken
# rather than as free. Twenty lines, reviewed by the household, chosen by the
# date so the wall says one thing all day instead of changing every 15 minutes.
FILLERS = [
    "Nothing on the calendar today.",
    "A clear day. Nothing booked, nothing due.",
    "No plans today. The day is yours.",
    "Quiet one today -- nothing on the books.",
    "Nothing scheduled. A good day to go slow.",
    "Empty calendar today. Enjoy the gap.",
    "No appointments today. Nobody has to be anywhere.",
    "Today is wide open.",
    "Nothing due today. Take the win.",
    "A free day. Rare, so use it well.",
    "No events today. Good day for a long breakfast.",
    "Clear today. Tomorrow can wait.",
    "Nothing on today -- a good day to get ahead of the week.",
    "Open day. Let the kids pick.",
    "No commitments today. Rest counts.",
    "Nothing booked. Good day to tick off something small.",
    "A blank page today.",
    "Calm day ahead. Nothing needs you yet.",
    "Nothing on. Make something, or make nothing.",
    "Free and clear today.",
]


def filler_for(today: date) -> str:
    """Deterministic in the date, so the sentence is stable for the whole day
    and still differs from yesterday's."""
    return FILLERS[today.toordinal() % len(FILLERS)]

# How much of a message body to keep. This was 4000, which silently cut a real
# school newsletter mid-way -- and the part lost held the one item that
# actually applied to this family. The model has a 64k window; the panel never
# renders the body at all, so the only cost of a generous limit is prompt
# tokens on a call that happens a few times a day.
MAIL_BODY_LIMIT = int(os.environ.get("MAIL_BODY_LIMIT", "24000"))

# A forwarded school newsletter is often a PDF with a one-line "see attached"
# above it -- all of the dates, none of them in the message body. poppler's
# pdftotext is the reader; see _pdf_text for why it is a subprocess.
PDFTOTEXT = os.environ.get("PDFTOTEXT", "pdftotext")
PDF_TIMEOUT = int(os.environ.get("PDF_TIMEOUT", "20"))
# Per attachment, so one enormous file cannot crowd the mail's own text out of
# the prompt. The overall body is capped separately by MAIL_BODY_LIMIT.
PDF_TEXT_LIMIT = int(os.environ.get("PDF_TEXT_LIMIT", "12000"))

# WHO LIVES HERE IS NOT IN THIS REPO.
# ------------------------------------
# This repo is PUBLIC. Household member names -- and the Home Assistant entity
# ids derived from them -- are deployment-identifying, so the real mapping
# lives in a git-ignored config file and only a neutral placeholder ships in
# source. Same reasoning as the prompts/ dir; see prompts/README.md.
#
# Owner keys must match the calendar feed colours in the MagicMirror config and
# the `owner` values in memory-mcp: one vocabulary across the whole wall.
#
# Format (brief/lists.json, git-ignored). Two sources:
#   Home Assistant  {"source":"ha","entity":"todo.<name>", ...}
#   Google Tasks    {"source":"google_tasks","account":"<key>","list":"My Tasks", ...}
# Common keys: owner, name, auto (bot-written), panel (show on the wall),
# and optional max_overdue_days to override the staleness cutoff.
LISTS_FILE = os.environ.get(
    "BRIEF_LISTS", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "lists.json"))

DEFAULT_LISTS = [
    # A personal list read from Google Tasks, READ-ONLY by credential.
    {"source": "google_tasks", "account": "adult-a", "list": "My Tasks",
     "owner": "adult-a", "name": "Adult A", "auto": False, "panel": True},
    # The bot's own list, in Home Assistant. The ONLY list it may write.
    {"source": "ha", "entity": "todo.family_auto", "owner": "family",
     "name": "Suggested", "auto": True, "panel": True},
    {"source": "ha", "entity": "todo.shopping_list", "owner": "family",
     "name": "Shopping", "auto": False, "panel": False},
]


def load_lists(path: str = None) -> list[dict]:
    """The household's to-do lists, from config if present else placeholders.

    Missing config is NOT an error: the fixtures and tests run on the
    placeholders, which is what lets the whole pipeline be developed before
    anyone's real lists exist.
    """
    path = path or LISTS_FILE
    try:
        with open(path, encoding="utf-8") as f:
            cfg = json.load(f)
        lists = cfg.get("lists") or []
        return lists or DEFAULT_LISTS
    except (OSError, ValueError):
        return DEFAULT_LISTS


# --- Google Calendar ---------------------------------------------------------

def _event_start(ev: dict):
    """(date, time_or_None) for an event.

    All-day events carry `start.date`; timed ones carry `start.dateTime`.
    Reading only dateTime silently drops every all-day event -- which on this
    calendar means recycle day and the school closures, the two things most
    worth seeing on a wall.
    """
    start = ev.get("start") or {}
    if start.get("date"):
        return date.fromisoformat(start["date"]), None
    raw = start.get("dateTime")
    if not raw:
        return None, None
    dt = datetime.fromisoformat(raw)
    return dt.date(), dt


def events_for(events: dict, on: date) -> list[dict]:
    """Confirmed events touching `on`, all-day first, then by start time."""
    out = []
    for ev in events.get("items", []):
        # Cancelled events stay in the feed with status "cancelled". Showing
        # one is worse than showing nothing: it sends somebody to a thing that
        # is not happening.
        if ev.get("status") == "cancelled":
            continue
        day, dt = _event_start(ev)
        if day != on:
            continue
        out.append({"summary": (ev.get("summary") or "").strip(),
                    "at": dt, "all_day": dt is None,
                    "location": ev.get("location", "")})
    out.sort(key=lambda e: (e["at"] is not None,
                            e["at"].time() if e["at"] else None))
    return out


def _fmt_time(dt: datetime) -> str:
    """4:05p / 9a -- short enough for a wall, unambiguous at a glance."""
    h = dt.hour % 12 or 12
    suffix = "a" if dt.hour < 12 else "p"
    return f"{h}:{dt.minute:02d}{suffix}" if dt.minute else f"{h}{suffix}"


# --- Gmail -------------------------------------------------------------------

def _header(msg: dict, name: str) -> str:
    """Case-insensitive header lookup.

    payload.headers is a LIST of {name, value}, and the casing is whatever the
    sending server used -- the fixture has both "Subject" and "subject".
    Indexing it like a dict is the classic Gmail-API bug.
    """
    want = name.lower()
    for h in (msg.get("payload") or {}).get("headers", []):
        if (h.get("name") or "").lower() == want:
            return (h.get("value") or "").strip()
    return ""


def _sender_name(from_header: str) -> str:
    """"Northside School <office@...>" -> "Northside School"."""
    if "<" in from_header:
        name = from_header.split("<", 1)[0].strip().strip('"')
        if name:
            return name
        return from_header.split("<", 1)[1].rstrip(">").strip()
    return from_header


def _decode(data: str) -> str:
    """Gmail bodies are base64URL (-_ rather than +/) and UNPADDED."""
    if not data:
        return ""
    pad = "=" * (-len(data) % 4)
    try:
        return base64.urlsafe_b64decode(data + pad).decode("utf-8", "replace")
    except (ValueError, binascii.Error):
        return ""


def _decode_bytes(data: str) -> bytes:
    """The same base64URL decode as _decode, stopping before the text step --
    an attachment is bytes and guessing an encoding for it would be nonsense."""
    if not data:
        return b""
    pad = "=" * (-len(data) % 4)
    try:
        return base64.urlsafe_b64decode(data + pad)
    except (ValueError, binascii.Error):
        return b""


def _pdf_text(raw: bytes) -> str:
    """The text layer of a PDF, or "" if there isn't one to be had.

    Shells out to poppler's pdftotext rather than taking a Python PDF
    dependency: it is already on the host, it is the reference implementation,
    and running it as a separate short-lived process means a malformed file
    from the internet crashes a subprocess instead of the brief.

    Returns "" for every failure -- missing binary, timeout, scanned pages with
    no text layer. A PDF that cannot be read is not an error here; the mail's
    own body is still extracted and the run continues.
    """
    if not raw:
        return ""
    try:
        out = subprocess.run(
            # No -layout: it preserves visual columns, which interleaves two
            # columns of prose into nonsense lines. The default reading order
            # keeps sentences whole, and whole sentences are what the model has
            # to quote back as evidence.
            [PDFTOTEXT, "-q", "-", "-"],
            input=raw, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=PDF_TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.decode("utf-8", "replace") if out.returncode == 0 else ""


def _strip_html(html: str) -> str:
    """Crude but sufficient: these are school newsletters, not documents."""
    text = re.sub(r"(?is)<(script|style).*?</\1>", " ", html)
    text = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>", "\n", text)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html_mod.unescape(text)
    text = re.sub(r"[ \t]+", " ", text)
    return re.sub(r"\n\s*\n\s*\n+", "\n\n", text).strip()


# Everything below the first line matching one of these is boilerplate. Real
# newsletters put the useful sentence at the top and the legal furniture at the
# bottom, so cutting at the first hit loses nothing and removes a lot.
_FOOTER_RE = re.compile(
    r"(?im)^\s*(unsubscribe|manage preferences|privacy policy|"
    r"sent with love from|you are receiving this|"
    r"view this email in your browser|--\s*$)")

# Tracking URLs in a forwarded newsletter run to hundreds of characters of
# opaque token, which is pure noise to a model and crowds out real content.
_URL_RE = re.compile(r"<?https?://[^\s>]+>?")
_IMG_RE = re.compile(r"(?im)^\s*\[image:[^\]]*\]\s*$")


def clean_body(text: str, keep_short_urls: bool = True) -> str:
    """Strip the furniture from a newsletter so the useful sentence survives.

    Measured on a real forwarded school newsletter: 1651 characters in, and the
    single fact that mattered ("Picture Day is coming up on September 24")
    was one line of it. The rest was tracking URLs, an unsubscribe block, a
    street address and image placeholders. Feeding all of that to the model
    wastes context and hands it more ways to latch onto the wrong thing.

    Deliberately conservative: it cuts known boilerplate, never guesses at
    prose. A short bare link is kept because it is occasionally the content
    (a meeting link, a form).
    """
    if not text:
        return ""
    cut = _FOOTER_RE.search(text)
    if cut:
        text = text[:cut.start()]
    text = _IMG_RE.sub("", text)

    def _url(m):
        u = m.group(0).strip("<>")
        return u if keep_short_urls and len(u) <= 60 else ""

    text = _URL_RE.sub(_url, text)
    # Collapse the whitespace the removals leave behind.
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return "\n".join(l.rstrip() for l in text.splitlines()).strip()


def message_body(msg: dict, limit: int = MAIL_BODY_LIMIT) -> str:
    """The readable text of a Gmail message.

    Three things make this more than a one-liner, and each is a real trap:

      * The body lives in payload.body.data for a SIMPLE message but in
        payload.parts[] for a multipart one -- and parts NEST. A
        multipart/mixed carrying a PDF keeps the actual text one level down
        inside a multipart/alternative, so this has to recurse.
      * text/plain is preferred over text/html. Both are usually present and
        the HTML one is a wall of layout markup.
      * Attachment parts carry body.attachmentId and NO data. Reading them as
        text yields nothing useful; a PDF must be fetched separately if it is
        ever wanted.

    Also note format=metadata returns no body at all -- the client must request
    format=full or this is empty through no fault of the parsing.
    """
    plain, html, docs = [], [], []

    def walk(part):
        mime = (part.get("mimeType") or "").lower()
        name = part.get("filename") or ""
        body = part.get("body") or {}
        if part.get("parts"):
            for sub in part["parts"]:
                walk(sub)
            return
        # An attachment has an id instead of inline data. Skip it.
        if body.get("attachmentId") and not body.get("data"):
            return
        if mime == "application/pdf" or name.lower().endswith(".pdf"):
            got = _pdf_text(_decode_bytes(body.get("data", "")))
            if got.strip():
                docs.append((name or "attachment.pdf",
                             clean_body(got, keep_short_urls=False)[:PDF_TEXT_LIMIT]))
            return
        text = _decode(body.get("data", ""))
        if not text:
            return
        if mime == "text/plain":
            plain.append(text)
        elif mime == "text/html":
            html.append(_strip_html(text))

    walk(msg.get("payload") or {})
    text = clean_body("\n".join(plain) if plain else "\n".join(html))
    # Attachments go AFTER the message text and are labelled, so the model can
    # tell "the school wrote this" from "somebody typed this in the forward",
    # and so the evidence quote it must produce still points at something a
    # human can find. The quote is checked against this whole string, so a PDF
    # is grounded exactly as the body is.
    for name, got in docs:
        text += f"\n\n--- attached file: {name} ---\n{got}"
    return text[:limit]


def mail_summaries(mail: dict, unread_only: bool = True,
                   with_body: bool = True) -> list[dict]:
    """Sender, subject, date -- and the body.

    THE BODY IS THE POINT. "Picture day moved to Oct 3" is in the body; the
    subject line alone cannot produce a to-do. Forwarding a message IS the
    permission to read it, so if something should not be read, it does not get
    forwarded. That is the whole sharing model.

    What this does NOT do is put the body on the wall. The panel renders the
    distilled fact, not a paste of the email -- that is a display decision (a
    wall is read from across a room), not a restriction on what the AI may see.

    One entry per THREAD -- a six-reply chain about one event is one thing
    happening, not six. Bodies of the later replies are joined in, so a
    correction sent as a reply is not lost.
    """
    order, threads = [], {}
    for msg in mail.get("messages", []):
        if unread_only and "UNREAD" not in (msg.get("labelIds") or []):
            continue
        tid = msg.get("threadId") or msg.get("id")
        if tid not in threads:
            order.append(tid)
            threads[tid] = {
                "from": _sender_name(_header(msg, "From")),
                "subject": _header(msg, "Subject"),
                # internalDate is epoch MILLISECONDS, as a string.
                "received": datetime.fromtimestamp(
                    int(msg.get("internalDate", "0")) / 1000).date().isoformat(),
                "body": "",
            }
        if with_body:
            extra = message_body(msg)
            if extra:
                cur = threads[tid]["body"]
                threads[tid]["body"] = f"{cur}\n\n---\n\n{extra}" if cur else extra
    out = [threads[t] for t in order]
    if not with_body:
        for m in out:
            m.pop("body", None)
    return out


# --- Home Assistant to-dos ---------------------------------------------------

def _due_key(item: dict):
    """Sort key for a `due` that may be absent, a date, or a datetime."""
    due = item.get("due")
    if not due:
        return (1, "")          # undated items sort last, not first
    return (0, due)


def _is_stale(due: str | None, today: date, max_days: int = MAX_OVERDUE_DAYS) -> bool:
    """True for something overdue past the point of being a real commitment."""
    if not due:
        return False            # no date means no deadline to have missed
    try:
        d = date.fromisoformat(due[:10])
    except ValueError:
        return False
    return (today - d).days > max_days


def _beyond_horizon(due: str | None, today: date, max_ahead: int | None) -> bool:
    """True for something too far out to be this week's business.

    A list with no horizon keeps everything, which is the old behaviour. When a
    horizon IS set, an undated item is hidden too: "the next 7 days" is a claim
    about when a thing happens, and an item with no date makes no such claim.
    """
    if max_ahead is None:
        return False
    if not due:
        return True
    try:
        d = date.fromisoformat(due[:10])
    except ValueError:
        return False            # a bad date loses the date, not the item
    return (d - today).days > max_ahead


def _open_items(items: list[dict], today: date, max_days: int,
                max_ahead: int | None = None) -> list[dict]:
    """Not completed, not ancient, not far-off, soonest-due first."""
    live = [i for i in items
            if i.get("status") != "completed"
            and not _is_stale(i.get("due"), today, max_days)
            and not _beyond_horizon(i.get("due"), today, max_ahead)]
    live.sort(key=_due_key)
    return live


def _due_today(items: list[dict], today: date) -> list[dict]:
    """Open items dated exactly today. Overdue is not today, done is not today."""
    return [i for i in items
            if i.get("status") != "completed"
            and (i.get("due") or "")[:10] == today.isoformat()]


def _due_label(due: str | None, today: date) -> str:
    if not due:
        return ""
    d = date.fromisoformat(due[:10])
    delta = (d - today).days
    if delta == 0:
        return "today"
    if delta == 1:
        return "tomorrow"
    if 0 < delta < 7:
        return d.strftime("%a")
    return d.strftime("%b ") + str(d.day)


def google_tasks_items(tasks_doc: dict, list_title: str) -> list[dict]:
    """Normalise a Google Tasks list into the same shape as an HA to-do list.

    Two Google-specific details:
      * `due` is RFC3339 with a time, but Google Tasks has NO due TIME -- it is
        always 00:00:00Z and meaningless. Only the date part is used, and
        treating it as a real timestamp would shift dates across time zones.
      * Completed tasks are absent unless showCompleted=true, but a stored
        fixture or a cached response may still carry them, so status is
        checked regardless.
    """
    lists = (tasks_doc.get("tasklists") or {}).get("items", [])
    match = next((L for L in lists if L.get("title") == list_title), None)
    if not match:
        return []
    raw = ((tasks_doc.get("tasks") or {}).get(match["id"]) or {}).get("items", [])
    out = []
    for t in raw:
        due = t.get("due")
        out.append({
            "summary": t.get("title", ""),
            "status": t.get("status", "needsAction"),
            "due": due[:10] if due else None,
        })
    return out


def _raw_items(todos: dict, spec: dict) -> list[dict]:
    """One list spec's items, whichever source it names."""
    if spec.get("source", "ha") == "google_tasks":
        doc = (todos.get("google_tasks") or {}).get(spec.get("account", ""), {})
        return google_tasks_items(doc, spec["list"])
    # Home Assistant: todo.get_items nests under service_response.
    resp = todos.get("service_response", todos)
    return (resp.get(spec["entity"]) or {}).get("items", [])


def items_due_today(todos: dict, today: date,
                    lists: list[dict] = None) -> list[str]:
    """Titles of every open to-do dated today, across the panel's lists.

    This is what "today" means for the headline. The previous input was every
    item the extractor pulled out of the morning's mail, which included items
    it went on to skip as duplicates -- so a task finished last week could
    still headline the wall.
    """
    out = []
    for spec in (lists if lists is not None else load_lists()):
        if not spec.get("panel", True):
            continue
        for i in _due_today(_raw_items(todos, spec), today):
            title = (i.get("summary") or "").strip()
            if title and title not in out:
                out.append(title)
    return out


def todo_columns(todos: dict, today: date, lists: list[dict] = None) -> list[dict]:
    """The panel's columns, open items only, soonest-due first."""
    cols = []
    for spec in (lists if lists is not None else load_lists()):
        if not spec.get("panel", True):
            continue
        owner, name, auto = spec["owner"], spec["name"], spec.get("auto", False)
        max_days = spec.get("max_overdue_days", MAX_OVERDUE_DAYS)

        items = _open_items(_raw_items(todos, spec), today, max_days,
                            spec.get("max_days_ahead"))
        cols.append({
            "owner": owner, "name": name, "auto": auto,
            "items": [{"text": i.get("summary", ""),
                       "due": _due_label(i.get("due"), today)}
                      for i in items[:MAX_ITEMS]],
            # The panel renders "+N more" from the full count.
            "total": len(items),
        })
    return cols


# --- assembly ----------------------------------------------------------------

def build(events: dict, mail: dict, todos: dict, today: date,
          lists: list[dict] = None, weather_raw: dict = None) -> dict:
    todays = events_for(events, today)

    lines = []
    for ev in todays[:MAX_LINES]:
        when = "" if ev["all_day"] else f" {_fmt_time(ev['at'])}"
        # All-day items are household by definition; timed ones are not
        # attributable from the calendar alone, so they take the shared colour
        # too. Per-person colouring needs the source calendar, which arrives
        # with the real client.
        lines.append({"owner": "family", "text": f"{ev['summary']}{when}".strip()})

    headline = _headline(todays, items_due_today(todos, today, lists), today)
    return {
        "generated": datetime.now().isoformat(timespec="seconds"),
        "date": today.isoformat(),
        "headline": headline,
        "lines": lines,
        "todos": todo_columns(todos, today, lists),
        # The next few hours, from whichever provider brief/weather.py is
        # pointed at. An empty list is a legitimate answer -- the panel simply
        # renders no strip -- so a dead forecast never costs the wall its brief.
        "weather": weather.hours(weather_raw),
        # Not rendered by the panel today. Carried so the mail path is exercised
        # end to end, and so a later "what did the bot read?" view has it.
        "mail": mail_summaries(mail),
    }


def _headline(todays: list[dict], due_today: list[str], today: date) -> str:
    """One plain sentence. A real deployment can hand this to the model instead;
    this fallback exists so the panel is never blank when the model is down."""
    timed = [e for e in todays if not e["all_day"]]
    if not todays and not due_today:
        return filler_for(today)
    if not todays:
        if len(due_today) == 1:
            return f"{due_today[0]} is due today."
        return f"{len(due_today)} things due today."
    if not timed:
        return todays[0]["summary"] + "."
    first, last = timed[0], timed[-1]
    if len(timed) == 1:
        return f"{first['summary']} at {_fmt_time(first['at'])}."
    return (f"{len(timed)} things today, {_fmt_time(first['at'])} "
            f"to {_fmt_time(last['at'])}.")


def _load(path: str) -> dict:
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def main(argv=None) -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    fix = os.path.join(here, "fixtures")
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--demo", action="store_true",
                   help="use the recorded fixtures (no credentials needed)")
    p.add_argument("--events"); p.add_argument("--mail"); p.add_argument("--todos")
    p.add_argument("--today", help="YYYY-MM-DD; defaults to the fixture day under --demo")
    p.add_argument("-o", "--out", help="write here instead of stdout")
    a = p.parse_args(argv)

    if a.demo:
        a.events = a.events or os.path.join(fix, "calendar_events.json")
        a.mail = a.mail or os.path.join(fix, "gmail_messages.json")
        a.todos = a.todos or os.path.join(fix, "ha_todos.json")
        # The fixtures describe one specific day; pinning it keeps --demo
        # deterministic instead of going empty the day after it was written.
        a.today = a.today or "2026-09-20"
    if not (a.events and a.mail and a.todos):
        p.error("need --demo, or all of --events/--mail/--todos")

    today = date.fromisoformat(a.today) if a.today else date.today()
    doc = build(_load(a.events), _load(a.mail), _load(a.todos), today)
    text = json.dumps(doc, indent=2)
    if a.out:
        tmp = a.out + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text + "\n")
        os.replace(tmp, a.out)   # the Pi may be fetching mid-write
        print(f"wrote {a.out}", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
