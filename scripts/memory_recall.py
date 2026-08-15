"""
title: Memory Recall
author: ai-home-server-infra
description: Injects the local AI's persistent memories (markdown files written by
    memory-mcp) into the system prompt at the start of every turn, so the model
    recalls what it knows about the user with no tool call — the read half of a
    Claude-style memory loop.
version: 1.0.0
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

import os

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
TYPES = ("user", "household", "project", "reference")
_TYPE_LABEL = {
    "user": "About the user",
    "household": "Household / home",
    "project": "Ongoing projects",
    "reference": "References",
}


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


def _render_block(memories: list[dict]) -> str:
    lines = [OPEN]
    if RECALL_HEADER:
        lines.append(RECALL_HEADER)
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

    async def inlet(self, body: dict, __metadata__=None, **kwargs) -> dict:
        metadata = __metadata__ or {}
        # Internal generations (title/tags/follow-up/etc.) must stay memory-free.
        if metadata.get("task"):
            return body

        messages = body.get("messages")
        if not isinstance(messages, list):
            return body

        memories = _load_memories()

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

        block = _render_block(memories)

        if sys_msg is not None and isinstance(sys_msg.get("content"), str):
            base = _strip_prior(sys_msg["content"]).strip()
            sys_msg["content"] = f"{block}\n\n{base}".strip() if base else block
        else:
            messages.insert(0, {"role": "system", "content": block})

        body["messages"] = messages
        return body
