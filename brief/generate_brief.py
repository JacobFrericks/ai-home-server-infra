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

WHAT GOES ON A KITCHEN WALL
---------------------------
The panel is read by anyone standing in the kitchen, guests included. Two
rules follow, and they are enforced here rather than trusted to a prompt:

  * Forwarded mail is SUMMARISED to sender + subject + date, never quoted. A
    school email may carry another family's details in a reply chain.
  * Only `household` memories may reach it. This script never reads the memory
    directory at all, which is the simplest possible way to hold that line.

Usage:
  ./generate_brief.py --demo                       # fixtures -> stdout
  ./generate_brief.py --events f.json --mail m.json --todos t.json -o brief.json
"""
import argparse
import json
import os
import sys
from datetime import date, datetime, timedelta

# The panel caps: 3 brief lines, 4 items per column. Measured against the real
# 1920x1080 wall, not chosen by taste -- see MMM-FamilyBrief.css. Emitting more
# than this is not an error, the panel just hides the overflow behind "+N more",
# but trimming here keeps the payload honest about what is actually readable.
MAX_LINES = 3
MAX_ITEMS = 4

# Owner keys must match the calendar feed colours in the MagicMirror config and
# the `owner` values in memory-mcp. One vocabulary across the whole wall.
LIST_OWNERS = {
    "todo.jacob": ("jacob", "Jacob", False),
    "todo.cassie": ("cassie", "Cassie", False),
    "todo.family_auto": ("family", "Suggested", True),
    "todo.shopping_list": ("family", "Shopping", False),
}
PANEL_LISTS = ("todo.jacob", "todo.cassie", "todo.family_auto")


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
    """"Ankeny Christian Academy <office@...>" -> "Ankeny Christian Academy"."""
    if "<" in from_header:
        name = from_header.split("<", 1)[0].strip().strip('"')
        if name:
            return name
        return from_header.split("<", 1)[1].rstrip(">").strip()
    return from_header


def mail_summaries(mail: dict, unread_only: bool = True) -> list[dict]:
    """Sender + subject + date. NEVER the body or the snippet.

    A forwarded school email can carry a reply chain with other families'
    names and numbers in it. Summarising to three fields is what makes it safe
    to put on a wall that guests can read, and the snippet field is exactly the
    thing that would leak, so it is not read here at all.

    One entry per THREAD -- a six-reply chain about one event is one thing
    happening, not six.
    """
    seen, out = set(), []
    for msg in mail.get("messages", []):
        if unread_only and "UNREAD" not in (msg.get("labelIds") or []):
            continue
        tid = msg.get("threadId") or msg.get("id")
        if tid in seen:
            continue
        seen.add(tid)
        out.append({
            "from": _sender_name(_header(msg, "From")),
            "subject": _header(msg, "Subject"),
            # internalDate is epoch MILLISECONDS, as a string.
            "received": datetime.fromtimestamp(
                int(msg.get("internalDate", "0")) / 1000).date().isoformat(),
        })
    return out


# --- Home Assistant to-dos ---------------------------------------------------

def _due_key(item: dict):
    """Sort key for a `due` that may be absent, a date, or a datetime."""
    due = item.get("due")
    if not due:
        return (1, "")          # undated items sort last, not first
    return (0, due)


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


def todo_columns(todos: dict, today: date) -> list[dict]:
    """The panel's columns, open items only, soonest-due first."""
    resp = todos.get("service_response", todos)
    cols = []
    for entity in PANEL_LISTS:
        owner, name, auto = LIST_OWNERS[entity]
        raw = (resp.get(entity) or {}).get("items", [])
        # `completed` items stay in the response. A wall full of finished tasks
        # is noise, and worse, it hides the open ones below the cut.
        items = [i for i in raw if i.get("status") != "completed"]
        items.sort(key=_due_key)
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

def build(events: dict, mail: dict, todos: dict, today: date) -> dict:
    todays = events_for(events, today)

    lines = []
    for ev in todays[:MAX_LINES]:
        when = "" if ev["all_day"] else f" {_fmt_time(ev['at'])}"
        # All-day items are household by definition; timed ones are not
        # attributable from the calendar alone, so they take the shared colour
        # too. Per-person colouring needs the source calendar, which arrives
        # with the real client.
        lines.append({"owner": "family", "text": f"{ev['summary']}{when}".strip()})

    headline = _headline(todays)
    return {
        "generated": datetime.now().isoformat(timespec="seconds"),
        "date": today.isoformat(),
        "headline": headline,
        "lines": lines,
        "todos": todo_columns(todos, today),
        # Not rendered by the panel today. Carried so the mail path is exercised
        # end to end, and so a later "what did the bot read?" view has it.
        "mail": mail_summaries(mail),
    }


def _headline(todays: list[dict]) -> str:
    """One plain sentence. A real deployment can hand this to the model instead;
    this fallback exists so the panel is never blank when the model is down."""
    timed = [e for e in todays if not e["all_day"]]
    if not todays:
        return "Nothing on the calendar today."
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
