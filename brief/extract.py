#!/usr/bin/env python3
"""extract.py — the step that actually uses the AI.

Reads unread mail in the bot's mailbox, asks the local model which parts are
real, actionable, and relevant to THIS household, and writes what survives to
`todo.family_suggested`.

WHY THIS FILE EXISTS
--------------------
Everything else in brief/ is plumbing: fetch, clean, reshape. None of it
decides anything. A forwarded school newsletter arrives with a Labor Day
closure, a gala deadline, a middle-school retreat, a table of sports ticket
prices and a Grandparents' Day invitation for two specific grades -- and only
some of that is a task, and only some of THAT applies to this family.
Separating them is a judgement call, which is the one thing a model is for.

NOTHING HERE TRUSTS THE MODEL
-----------------------------
Three guards run on its output, in order, and each is mechanical:

  1. EVIDENCE MUST BE REAL. Every item must carry a verbatim quote from the
     email, and the quote is checked against the source. To invent a task the
     model must also invent a quote, and that is checkable. This is the guard
     that matters, and it caught a fabricated item on the very first real run.
  2. RELEVANCE. The model classifies every item, including as NOT_US, and we
     drop those. Asking it to classify and filtering afterwards beats hoping
     it stays quiet -- and it lets us log what was rejected and why.
  3. SHAPE. A malformed date is discarded rather than trusted.

  There is deliberately NO "is this really a task?" flag. An earlier version
  had one and the model used it to talk itself out of Grandparents' Day, a
  gala deadline and a parent meeting. Selection happens once, when the item is
  emitted -- asking twice just gives it a second chance to be wrong.

BLAST RADIUS
------------
Anyone can email the bot, so this reads attacker-influenceable text and then
acts. The only action available is "add an item to todo.family_suggested". It
cannot write a personal to-do list (those are read with tasks.readonly and
Google refuses a write), cannot touch a real calendar (the bot owns only the
family one), and can reach nothing else. The worst case for a prompt-injected
email is one junk line on the kitchen wall, in amber, labelled `auto`, one
click from gone.
"""
import argparse
import imaplib
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from datetime import date, datetime

HERE = os.path.dirname(os.path.abspath(__file__))

# Ollama's ClusterIP is pinned in the k8s manifest precisely so it can be
# relied on; the host reaches ClusterIPs through Cilium. No auth -- which is
# why that Service has no externalIP.
OLLAMA = os.environ.get("OLLAMA_URL", "http://10.43.200.11:11434")
# `assistant` is an Open WebUI construct and does not exist in ollama.
MODEL = os.environ.get("BRIEF_MODEL", "gemma4:26b")
NUM_CTX = int(os.environ.get("BRIEF_NUM_CTX", "65536"))
# A cold load of a 17 GB model is slow; this matches verify-services.sh.
TIMEOUT = int(os.environ.get("BRIEF_TIMEOUT", "240"))

HOUSEHOLD_FILE = os.environ.get(
    "BRIEF_HOUSEHOLD", os.path.join(HERE, "household.json"))
SUGGESTED_ENTITY = os.environ.get("SUGGESTED_ENTITY", "todo.family_suggested")

NOT_US = "NOT_US"


# --- who may put things on the wall ------------------------------------------

def _addresses(value: str) -> list[str]:
    """Every bare address in a header value, lowercased."""
    return [a.lower() for a in
            re.findall(r"[\w.+-]+@[\w-]+\.[\w.-]+", value or "")]


# Google writes this itself at delivery, after receiving the message. A sender
# has no control over it, which is exactly what makes it worth reading.
AUTHSERV = "mx.google.com"


def _auth_results(raw_headers: list, authserv: str = AUTHSERV) -> str:
    """The Authentication-Results line OUR mail server wrote.

    A hostile message can carry its own forged Authentication-Results header,
    so the authserv-id is checked: only the line stamped by the server that
    actually received the mail counts. Taking "the first one" would be a real
    bug the day someone bothers to try it.
    """
    for h in raw_headers or []:
        if (h.get("name") or "").lower() != "authentication-results":
            continue
        val = h.get("value") or ""
        if val.strip().lower().startswith(authserv):
            return val
    return ""


def _domain(addr: str) -> str:
    return addr.rsplit("@", 1)[-1].lower() if "@" in addr else ""


def authenticated_as(raw_headers: list, address: str) -> tuple:
    """(ok, why) — did our mail server verify this came from `address`'s domain?

    ALIGNMENT IS THE WHOLE POINT. `dkim=pass` on its own means "some domain
    signed this and the signature checks out" -- an attacker sending from
    evil.com with a perfectly valid evil.com key gets `dkim=pass` too. What
    matters is whether the domain that SIGNED it is the domain the message
    claims to be FROM. Checking the pass without the alignment is the classic
    way to build a check that feels strong and stops nothing.

    SPF is accepted as an alternative because it authenticates the envelope
    sender, which is what matters for a direct send. Either is sufficient;
    DMARC is precisely "at least one of these, aligned".
    """
    want = _domain(address)
    if not want:
        return False, "no domain in address"
    ar = _auth_results(raw_headers)
    if not ar:
        return False, f"no Authentication-Results from {AUTHSERV}"
    flat = re.sub(r"\s+", " ", ar)

    # dkim=pass ... header.i=@domain  (or header.d=domain)
    for m in re.finditer(r"dkim=pass([^;]*)", flat, re.I):
        tail = m.group(1)
        signed = re.search(r"header\.(?:i=@?|d=)([\w.-]+)", tail, re.I)
        if signed and signed.group(1).lower() == want:
            return True, f"dkim=pass aligned to {want}"

    # spf=pass (... domain of user@domain designates ...)
    for m in re.finditer(r"spf=pass([^;]*)", flat, re.I):
        if re.search(r"domain of [\w.+-]+@" + re.escape(want) + r"\b", m.group(1), re.I):
            return True, f"spf=pass aligned to {want}"

    if re.search(r"\barc=pass\b", flat, re.I):
        return True, "arc=pass (forwarded; original signature expected to break)"

    return False, f"no aligned dkim/spf for {want}"


def sender_allowed(msg_headers: dict, trusted: list[str],
                   raw_headers: list = None, require_auth: bool = False) -> tuple:
    """(allowed, reason). Empty `trusted` allows everything, loudly.

    WHY THIS EXISTS: the bot has a public email address, so without it anyone
    who learns that address can put a line on this family's kitchen wall, and
    the model will dutifully read their text looking for instructions. The
    allowlist is the boundary; the guards in verify_items are what happens
    after something is already inside it.

    Checked against `From`, `Return-Path` (the SMTP envelope sender, which the
    receiving server sets rather than the sender asserting it), and
    `X-Forwarded-For`. That last one matters for Gmail FILTER forwarding:
    auto-forwarded mail keeps the ORIGINAL sender in From, so a From-only
    check would reject exactly the mail the filters exist to deliver.

    With `require_auth` (the default), the allowlist is only the first gate:
    the address must ALSO be one the receiving mail server cryptographically
    verified, via aligned DKIM or SPF. The allowlist says who a message claims
    to be from; authenticated_as says whether that claim was checked by
    someone the sender cannot influence.
    """
    if not trusted:
        return True, "no allowlist configured (everything accepted)"
    allow = {t.lower() for t in trusted}

    def _auth(addr, via):
        """Second gate: the allowlist says WHO, this says PROVE IT."""
        if not require_auth:
            return True, via
        ok, why = authenticated_as(raw_headers or [], addr)
        return (True, f"{via} + {why}") if ok else (False, f"{via} but {why}")

    for a in _addresses(msg_headers.get("From", "")):
        if a in allow:
            return _auth(a, "From")

    # Envelope sender: set by the receiving server, not asserted by the client.
    for a in _addresses(msg_headers.get("Return-Path", "")):
        if a in allow:
            return _auth(a, "Return-Path")

    # Gmail filter auto-forwarding keeps the ORIGINAL sender in From and
    # records the chain here. Forwarding routinely BREAKS the original DKIM
    # signature -- that is normal and is why ARC exists -- so the alignment
    # check is against the forwarding account, not the original sender.
    for a in _addresses(msg_headers.get("X-Forwarded-For", "")):
        if a in allow:
            return _auth(a, "X-Forwarded-For")

    frm = _addresses(msg_headers.get("From", ""))
    return False, f"sender not trusted ({', '.join(frm) or 'unknown'})"


# --- who lives here ----------------------------------------------------------

# Grade numbering: 0 is kindergarten, 1 is first grade, and NEGATIVE numbers
# are the years before kindergarten. A school may run a transitional year
# below kindergarten under its own name (-1), so the labels are config rather
# than constants -- the model should read the word the school actually uses.
DEFAULT_HOUSEHOLD = {
    # Empty means "accept anything", which is the old behaviour. A real
    # deployment fills this in; see household.example.json.
    "trusted_senders": [],
    "require_authentication": True,
    "children": [
        {"name": "Child A", "anchor_grade": 2, "anchor_school_year": 2026},
        {"name": "Child B", "anchor_grade": -1, "anchor_school_year": 2026},
    ],
    "grade_labels": {"-1": "pre-kindergarten"},
    "school_year_starts_month": 8,
}


def load_household(path: str = None) -> dict:
    """Household config, or neutral placeholders.

    Real names and grades are deployment-identifying and this repo is public,
    so the live file is git-ignored -- same pattern as brief/lists.json and
    prompts/. Missing config is not an error: the tests run on the defaults.
    """
    try:
        with open(path or HOUSEHOLD_FILE, encoding="utf-8") as f:
            cfg = json.load(f)
        return cfg if cfg.get("children") else DEFAULT_HOUSEHOLD
    except (OSError, ValueError):
        return DEFAULT_HOUSEHOLD


def school_year(d: date, starts_month: int = 8) -> int:
    """The school year a date falls in. August starts a new one."""
    return d.year if d.month >= starts_month else d.year - 1


def grade_now(anchor_grade: int, anchor_year: int, d: date,
              starts_month: int = 8) -> int:
    """Current grade, computed rather than stored.

    Storing a literal "2nd grade" is wrong from the following August and
    nothing would notice -- the model would confidently filter against a stale
    year for twelve months. Storing the grade WITH the school year it was true
    in makes it self-correcting forever.
    """
    return anchor_grade + (school_year(d, starts_month) - anchor_year)


def grade_label(grade: int, labels: dict = None) -> str:
    """Human name for a grade, with per-school overrides.

    Overrides are keyed BY GRADE NUMBER, not by child. A label names a year of
    school, not a person -- attaching it to the child would leave them called
    "Begindergarten" forever, which is the stale-forever bug the anchor maths
    exists to prevent. Keyed by grade, a child simply moves out of it.
    """
    if labels:
        hit = labels.get(str(grade))
        if hit:
            return hit
    if grade < -1:
        return "preschool"
    if grade == -1:
        return "pre-kindergarten"
    if grade == 0:
        return "kindergarten"
    suffix = {1: "st", 2: "nd", 3: "rd"}.get(
        grade if grade < 20 else grade % 10, "th")
    if 11 <= grade <= 13:
        suffix = "th"
    return f"{grade}{suffix} grade"


def children_now(household: dict, today: date) -> list[dict]:
    """[{key, name, grade, grade_label}] as of `today`."""
    starts = household.get("school_year_starts_month", 8)
    labels = household.get("grade_labels", {})
    out = []
    for c in household.get("children", []):
        g = grade_now(c["anchor_grade"], c["anchor_school_year"], today, starts)
        out.append({
            "key": re.sub(r"[^a-z0-9]+", "-", c["name"].lower()).strip("-"),
            "name": c["name"],
            "grade": g,
            "grade_label": grade_label(g, labels),
        })
    return out


# --- the model call ----------------------------------------------------------

def _schema(child_keys: list[str]) -> dict:
    """JSON schema for the model's answer.

    Constrained decoding (ollama >= 0.5) means the SHAPE cannot drift -- no
    prose preamble, no markdown fence, no missing field. That removes a whole
    class of parsing failure and leaves only the judgement to check.

    `applies_to` is an enum including NOT_US on purpose: the model classifies
    everything and we filter, rather than hoping it silently omits what does
    not apply. A dropped item is then loggable, with a reason.
    """
    return {
        "type": "object",
        "properties": {
            "items": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string"},
                        "due": {"type": "string"},
                        "applies_to": {"type": "string",
                                       "enum": child_keys + ["household", NOT_US]},
                        "evidence": {"type": "string"},
                    },
                    "required": ["title", "due", "applies_to", "evidence"],
                },
            }
        },
        "required": ["items"],
    }


def build_prompt(msg: dict, kids: list[dict], today: date) -> str:
    """The prompt, tuned against a real school newsletter.

    First version pulled NINE items out of one newsletter and missed the two
    that mattered. It treated every optional invitation -- donate a basket,
    sign up to pray, join the lunch team -- as a task, while skipping
    Grandparents' Day (which named the children's grades) and a lost-and-found
    deadline. The panel shows four items, so over-extraction does not just add
    noise, it pushes the real things off the wall.

    Hence the two rules doing the work below: a deadline is what makes
    something a task, and a grade range must be read against the children.
    """
    who = "\n".join(
        f'  - {c["name"]} (key "{c["key"]}") is in {c["grade_label"]}'
        for c in kids)
    return f"""You read a household's forwarded mail and pull out only the things \
someone actually has to DO.

Today is {today.strftime('%A, %Y-%m-%d')}.

The children in this household:
{who}

WHAT COUNTS AS AN ITEM
- Something with a DEADLINE or a DATE attached. That is the strongest signal.
- Something the family must bring, send, pay, sign, or turn up to.
- An event the children are invited to, INCLUDING when the invitation is
  written as a grade range. Work out whether a child's grade falls inside the
  range and include it if so.

WHAT IS NOT AN ITEM
- A standing invitation with no deadline: "we are always looking for
  volunteers", "reach out if interested", "donations welcome". Skip these.
  If it has a real cut-off date, it IS an item.
- Information with nothing to do: price lists, scripture, recaps of past
  events, mission statements, staff introductions.
- Anything aimed at grades or groups this family is not in -> "{NOT_US}".

RULES
- Be selective. At most 6 items. If you have more, keep the ones with dates.
- If you are unsure whether something belongs, include it: a wrong item on a
  wall is deleted in one click, a missing one is never seen at all.
- applies_to: a child's key when it is for that child's grade; "household"
  for the whole school or the parents; "{NOT_US}" for other grades/groups.
- evidence: a VERBATIM span copied from the message, long enough to locate,
  proving both the item and its date. Never paraphrase it.
- due: YYYY-MM-DD, or "" if genuinely undated. Resolve relative dates
  ("next Friday", "one week left", "by end of day Tuesday") against today.
- title: short and imperative. "Buy gala tickets", not "There is a gala".

Message
From: {msg.get('from', '')}
Date: {msg.get('received', '')}
Subject: {msg.get('subject', '')}

{msg.get('body', '')}
"""


def ask_model(prompt: str, child_keys: list[str]) -> dict:
    body = json.dumps({
        "model": MODEL,
        "prompt": prompt,
        "stream": False,
        # MANDATORY with `format`. gemma4:26b is a reasoning model and letting
        # it think alongside constrained decoding is a known way to get
        # schema-violating output.
        "think": False,
        "format": _schema(child_keys),
        "options": {"num_ctx": NUM_CTX, "temperature": 0},
    }).encode()
    req = urllib.request.Request(f"{OLLAMA}/api/generate", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        out = json.load(r)
    if out.get("error"):
        raise RuntimeError(out["error"])
    return json.loads(out.get("response") or "{}")


# --- the guards --------------------------------------------------------------

def _normalise(text: str) -> str:
    """Collapse whitespace so a quote still matches across rewrapped lines."""
    return re.sub(r"\s+", " ", text or "").strip().lower()


def verify_items(raw: list[dict], source: str, child_keys: list[str],
                 min_evidence: int = 12) -> tuple:
    """Apply the three guards. Returns (kept, [(item, why_dropped), ...]).

    The evidence check is the load-bearing one. A hallucinated task needs a
    hallucinated quote to go with it, and the quote is checked against the
    actual message -- so invention is caught mechanically rather than by
    trusting a tone of confidence.
    """
    hay = _normalise(source)
    kept, dropped = [], []
    for it in raw or []:
        title = (it.get("title") or "").strip()
        if not title:
            dropped.append((it, "no title"))
            continue
        where = it.get("applies_to") or NOT_US
        if where == NOT_US or where not in child_keys + ["household"]:
            dropped.append((it, f"not for us ({where})"))
            continue
        ev = _normalise(it.get("evidence"))
        if len(ev) < min_evidence:
            dropped.append((it, "evidence too short to verify"))
            continue
        if ev not in hay:
            dropped.append((it, "evidence not found in the message"))
            continue
        due = (it.get("due") or "").strip()
        if due:
            try:
                date.fromisoformat(due[:10])
            except ValueError:
                due = ""          # a bad date is dropped, the item survives
        kept.append({"title": title, "due": due, "applies_to": where,
                     "evidence": it.get("evidence", "").strip()})
    return kept, dropped


# --- writing back ------------------------------------------------------------

def ha_call(env: dict, service: str, payload: dict, response: bool = False):
    url = f"{env['HA_URL']}/api/services/todo/{service}"
    if response:
        url += "?return_response"
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), method="POST",
        headers={"Authorization": f"Bearer {env['HA_TOKEN']}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def existing_titles(env: dict) -> set:
    """What is already on the suggested list.

    A half-failed run must not be able to duplicate an item on the wall. The
    mark-as-read below is the primary defence; this is the belt to its braces.
    """
    try:
        d = ha_call(env, "get_items", {"entity_id": SUGGESTED_ENTITY}, True)
        items = (d.get("service_response", {}).get(SUGGESTED_ENTITY, {})
                 .get("items", []))
        return {_normalise(i.get("summary")) for i in items}
    except Exception:
        return set()


def add_todo(env: dict, item: dict, provenance: str) -> None:
    """Add ONE item, to the bot's own list. The entity is not a parameter the
    model can influence -- it is fixed at module scope."""
    payload = {"entity_id": SUGGESTED_ENTITY, "item": item["title"],
               "description": provenance}
    if item.get("due"):
        payload["due_date"] = item["due"]
    ha_call(env, "add_item", payload)


def mark_read(env: dict, uids: list) -> int:
    """Flag processed messages \\Seen in the bot's mailbox.

    This is the idempotency mechanism AND the audit trail: open the bot's
    inbox and unread means "not yet looked at". It is the one place the IMAP
    connection is not read-only -- fetch_mail stays PEEK-only so ordinary
    fetches never change state.
    """
    if not uids:
        return 0
    M = imaplib.IMAP4_SSL("imap.gmail.com", 993,
                          ssl_context=ssl.create_default_context())
    try:
        M.login(env["BOT_EMAIL"], env["BOT_IMAP_APP_PASSWORD"].replace(" ", ""))
        M.select("INBOX")                      # writable, deliberately
        n = 0
        for uid in uids:
            ok, _ = M.store(uid, "+FLAGS", "\\Seen")
            n += 1 if ok == "OK" else 0
        return n
    finally:
        try:
            M.logout()
        except Exception:
            pass


# --- headline ----------------------------------------------------------------

def write_headline(events: list, items: list, kids: list, today: date) -> str:
    """One sentence for the top of the wall. Returns "" if the model is not
    usable -- the caller then keeps generate_brief's deterministic fallback,
    because the wall must never go blank over a busy GPU."""
    lines = [f"- {e}" for e in events] + [f"- {i['title']}" for i in items]
    if not lines:
        return ""
    who = ", ".join(f'{c["name"]} ({c["grade_label"]})' for c in kids)
    prompt = (
        f"Today is {today.strftime('%A, %B %-d')}. Household: {who}.\n"
        "Write ONE short sentence for a kitchen wall display summarising the "
        "day. Name what matters and when. Do NOT restate today's date -- the "
        "display already shows it. No greeting, no emoji, no lead-in, under "
        "90 characters. Reply with the sentence only.\n\n"
        + "\n".join(lines))
    try:
        body = json.dumps({"model": MODEL, "prompt": prompt, "stream": False,
                           "think": False,
                           "options": {"num_ctx": NUM_CTX, "temperature": 0.2,
                                       "num_predict": 60}}).encode()
        req = urllib.request.Request(f"{OLLAMA}/api/generate", data=body,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            txt = (json.load(r).get("response") or "").strip()
    except Exception:
        return ""
    txt = txt.strip().strip('"').splitlines()[0].strip() if txt else ""
    # A model that ignores "one short sentence" gets overruled rather than
    # allowed to overflow the band.
    return txt if 0 < len(txt) <= 120 else ""


# --- runner ------------------------------------------------------------------

def main(argv=None) -> int:
    import importlib.util
    def _load(name, path):
        sp = importlib.util.spec_from_file_location(name, os.path.join(HERE, path))
        m = importlib.util.module_from_spec(sp)
        sp.loader.exec_module(m)
        return m
    fl = _load("fl", "fetch_live.py")
    gen = _load("gen", "generate_brief.py")

    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dry-run", action="store_true",
                   help="show what would be added; write nothing, mark nothing")
    p.add_argument("--all-mail", action="store_true",
                   help="reprocess read mail too (for testing)")
    p.add_argument("--headline-out", help="write the generated headline here")
    a = p.parse_args(argv)

    env = fl.load_env()
    household = load_household()
    today = date.today()
    kids = children_now(household, today)
    keys = [c["key"] for c in kids]
    print("children  : " + ", ".join(f'{c["name"]}={c["grade_label"]}' for c in kids),
          file=sys.stderr)

    mail = fl.fetch_mail(env, since_days=7, limit=25)

    # Filter BY SENDER FIRST, before the body ever reaches the model. This is
    # the boundary: everything past it is treated as text the household chose
    # to hand over. Rejected mail is left UNREAD on purpose -- it costs one
    # header check per run, and it means adding a sender to the allowlist
    # later picks up what was already refused instead of losing it.
    trusted = household.get("trusted_senders", [])
    # Default ON. Being allowlisted says who a message CLAIMS to be from;
    # this says the receiving server verified it. Off is a deliberate choice.
    require_auth = household.get("require_authentication", True)
    if not trusted:
        print("WARNING: no trusted_senders configured -- accepting any sender",
              file=sys.stderr)
    elif not require_auth:
        print("WARNING: require_authentication is off -- From headers are "
              "taken at face value", file=sys.stderr)
    allowed_raw, refused = [], []
    for m in mail["messages"]:
        raw = (m.get("payload") or {}).get("headers", [])
        hdrs = {h["name"]: h["value"] for h in raw}
        ok, why = sender_allowed(hdrs, trusted, raw, require_auth)
        (allowed_raw if ok else refused).append((m, why))
    for m, why in refused:
        print(f"  refused: {gen._header(m, 'Subject')[:44]!r} ({why})",
              file=sys.stderr)
    if refused:
        print(f"refused   : {len(refused)} message(s) from untrusted senders",
              file=sys.stderr)

    mail = {"messages": [m for m, _ in allowed_raw]}
    by_uid = {m["_uid"]: m for m in mail["messages"]}
    msgs = gen.mail_summaries(mail, unread_only=not a.all_mail)
    # mail_summaries collapses threads; map each back to its UIDs to flag later.
    subj_uids = {}
    for uid, raw in by_uid.items():
        subj_uids.setdefault(gen._header(raw, "Subject"), []).append(uid)

    if not msgs:
        print("nothing to do", file=sys.stderr)
        return 0
    print(f"unread    : {len(msgs)} message(s)", file=sys.stderr)

    already = existing_titles(env)
    added, processed_uids, all_kept = 0, [], []

    for m in msgs:
        try:
            raw = ask_model(build_prompt(m, kids, today), keys)
        except Exception as e:
            print(f"  MODEL FAILED on {m['subject'][:50]!r}: {type(e).__name__}",
                  file=sys.stderr)
            continue        # leave it unread so the next run retries it
        kept, dropped = verify_items(raw.get("items"), m.get("body", ""), keys)
        print(f'\n  "{m["subject"][:60]}"', file=sys.stderr)
        for it, why in dropped:
            print(f"    drop: {str(it.get('title'))[:44]:<46} ({why})", file=sys.stderr)
        for it in kept:
            if _normalise(it["title"]) in already:
                print(f"    dupe: {it['title']}", file=sys.stderr)
                continue
            print(f"    KEEP: {it['title']:<46} due={it['due'] or '-'}"
                  f"  [{it['applies_to']}]", file=sys.stderr)
            if not a.dry_run:
                add_todo(env, it, f"From {m['from']}, {m['received']}")
            already.add(_normalise(it["title"]))
            added += 1
        all_kept.extend(kept)
        processed_uids.extend(subj_uids.get(m["subject"], []))

    if a.headline_out:
        evs = [e["summary"] for e in
               gen.events_for(fl.fetch_calendar(env), today)]
        h = write_headline(evs, all_kept, kids, today)
        if h:
            with open(a.headline_out, "w") as f:
                f.write(h + "\n")
            print(f"\nheadline  : {h}", file=sys.stderr)

    if a.dry_run:
        print(f"\nDRY RUN -- would add {added} item(s), would mark "
              f"{len(set(processed_uids))} message(s) read", file=sys.stderr)
        return 0

    n = mark_read(env, sorted(set(processed_uids)))
    print(f"\nadded {added} item(s); marked {n} message(s) read", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
