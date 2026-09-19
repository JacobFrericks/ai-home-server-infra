"""
title: Memory Recall
author: ai-home-server-infra
description: Injects the local AI's persistent memories (markdown files written by
    memory-mcp) into the system prompt at the start of every turn, so the model
    recalls what it knows about the user with no tool call — the read half of a
    Claude-style memory loop. Scoped per person: each account sees the shared
    household facts plus its own, and nobody else's.
version: 2.0.0
required_open_webui_version: 0.5.0
"""

# WHY THIS EXISTS
# --------------
# memory-mcp (127.0.0.1:9400) gives the model tools to SAVE facts as markdown
# files in /memory (a read-only bind mount of the server's memory-data/ dir).
# This inlet filter is the RECALL half: before each real user turn it reads all
# those files and prepends a <memory_context> block to the system prompt, so the
# model already "knows" the user without having to call a tool. We load the whole
# set (it is small — dozens of household facts); if it ever outgrows the context
# window, swap this whole-file load for an embedding search over the same files.
#
# It runs on the inlet, is idempotent (strips any prior <memory_context> before
# re-injecting so newly saved facts appear next turn), and skips Open WebUI's
# internal task requests (title / tag / follow-up generation) which set
# metadata['task'] and should stay memory-free.
#
# THIS FILE IS THE PRIVACY BOUNDARY (v2)
# --------------------------------------
# Every memory carries an `owner`: "household" (shared) or one person's key.
# memory-mcp cannot enforce that on write -- MCP tool calls carry no caller
# identity, so a model could label a fact with anyone's name. This filter is
# where the rule is actually kept, because Open WebUI DOES tell us who is
# asking, via __user__.
#
# The rule: inject `household` + the current person's own. Nothing else, ever.
# It FAILS CLOSED -- an unknown or missing __user__ gets the household pool
# only, never the full set. That way a bug or a future code path that forgets
# to pass __user__ under-shares rather than leaking.

import os
import re

MEMORY_DIR = os.environ.get("MEMORY_DIR", "/memory")

# The instruction sentence that heads the injected block is a system prompt, and
# this repo is public — so it is NOT stored here. openwebui-install-filter.py
# --prompt-file substitutes prompts/memory-recall-header.txt for this token when
# it writes the filter into Open WebUI's DB (see prompts/README.md). If the token
# is still present at runtime the substitution did not happen, and we inject the
# memories with no header rather than leaking a placeholder into the prompt.
RECALL_HEADER = "@@RECALL_HEADER@@"
if RECALL_HEADER.startswith("@@"):
    RECALL_HEADER = ""

OPEN = "<memory_context>"
CLOSE = "</memory_context>"
HOUSEHOLD = "household"
TYPES = ("user", "household", "project", "reference")
_TYPE_LABEL = {
    "user": "About the user",
    "household": "Household / home",
    "project": "Ongoing projects",
    "reference": "References",
}


def _slug(text: str) -> str:
    """Same slug rule as memory-mcp, so owner keys match on both sides."""
    return re.sub(r"[^a-z0-9]+", "-", (text or "").strip().lower()).strip("-")[:64]


def _owner_key(user: dict | None) -> str:
    """Stable per-person key from Open WebUI's __user__, or "" if unknown.

    Derived from the email local-part (alex@example.com -> "alex") because it
    is stable, human-readable in the saved file, and survives a display-name
    change. Falls back to the account id, which is opaque but unique. Returns
    "" when there is no usable identity -- callers must then treat the request
    as household-only.
    """
    if not isinstance(user, dict):
        return ""
    email = (user.get("email") or "").strip()
    if "@" in email:
        key = _slug(email.split("@", 1)[0])
        if key:
            return key
    return _slug(str(user.get("id") or ""))


def _visible_to(memories: list[dict], owner: str) -> list[dict]:
    """The shared pool plus `owner`'s own. FAIL CLOSED on an empty owner."""
    who = owner or HOUSEHOLD
    return [m for m in memories if m["owner"] in (HOUSEHOLD, who)]


def _parse(path: str) -> dict | None:
    try:
        with open(path) as f:
            raw = f.read()
    except OSError:
        return None
    meta, body = {}, raw
    if raw.startswith("---"):
        end = raw.find("\n---", 3)
        if end != -1:
            for line in raw[3:end].strip().splitlines():
                if ":" in line:
                    k, _, v = line.partition(":")
                    meta[k.strip()] = v.strip()
            body = raw[end + 4:].lstrip("\n")
    t = (meta.get("type") or "").strip().lower()
    return {
        "type": t if t in TYPES else "reference",
        # No `owner:` line means the file predates multi-user support, when
        # there was only one person it could belong to -- shared is correct.
        "owner": _slug(meta.get("owner", "")) or HOUSEHOLD,
        "content": body.strip(),
    }


def _load_memories() -> list[dict]:
    if not os.path.isdir(MEMORY_DIR):
        return []
    out = []
    for fn in sorted(os.listdir(MEMORY_DIR)):
        if not fn.endswith(".md") or fn == "MEMORY.md":
            continue
        m = _parse(os.path.join(MEMORY_DIR, fn))
        if m and m["content"]:
            out.append(m)
    return out


def _render_block(memories: list[dict], owner: str = "") -> str:
    lines = [OPEN]
    if RECALL_HEADER:
        lines.append(RECALL_HEADER)
    # Naming the person here is what lets save_memory be called with the right
    # `owner`. memory-mcp has no way to know who is talking; this line is how
    # the model finds out. Omitted when we could not identify the account --
    # better no name than a wrong one attached to a saved fact.
    if owner:
        lines.append(f"You are talking to {owner}. When you save a personal "
                     f"fact about them, pass owner=\"{owner}\"; use "
                     f"owner=\"{HOUSEHOLD}\" for facts the whole house shares.")
    for t in TYPES:
        group = [m for m in memories if m["type"] == t]
        if not group:
            continue
        lines.append(f"\n{_TYPE_LABEL[t]}:")
        for m in group:
            lines.append(f"- {m['content']}")
    lines.append(CLOSE)
    return "\n".join(lines)


def _strip_prior(text: str) -> str:
    """Remove any previously injected <memory_context>...</memory_context>."""
    while OPEN in text:
        start = text.find(OPEN)
        end = text.find(CLOSE, start)
        if end == -1:
            break
        text = (text[:start] + text[end + len(CLOSE):]).strip()
    return text


class Filter:
    def __init__(self):
        pass

    async def inlet(self, body: dict, __user__=None, __metadata__=None,
                    **kwargs) -> dict:
        metadata = __metadata__ or {}
        # Internal generations (title/tags/follow-up/etc.) must stay memory-free.
        if metadata.get("task"):
            return body

        messages = body.get("messages")
        if not isinstance(messages, list):
            return body

        # THE PRIVACY BOUNDARY. Everything below sees only what this person is
        # allowed to see. An unknown account yields "" and therefore the
        # household pool alone -- never the full set.
        owner = _owner_key(__user__)
        memories = _visible_to(_load_memories(), owner)

        # Find an existing system message.
        sys_msg = next(
            (m for m in messages
             if isinstance(m, dict) and m.get("role") == "system"),
            None,
        )

        if not memories:
            # Nothing to inject; clean up any stale block we left before.
            if sys_msg and isinstance(sys_msg.get("content"), str) and OPEN in sys_msg["content"]:
                sys_msg["content"] = _strip_prior(sys_msg["content"])
            return body

        block = _render_block(memories, owner)

        if sys_msg is not None and isinstance(sys_msg.get("content"), str):
            base = _strip_prior(sys_msg["content"]).strip()
            sys_msg["content"] = f"{block}\n\n{base}".strip() if base else block
        else:
            messages.insert(0, {"role": "system", "content": block})

        body["messages"] = messages
        return body
