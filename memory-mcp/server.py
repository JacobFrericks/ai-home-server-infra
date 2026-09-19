#!/usr/bin/env python3
"""
memory-mcp — a tiny MCP server giving the local AI a persistent, Claude-style
memory. It exposes save/update/delete/list tools that the Open WebUI chat model
(assistant) calls, and it stores each fact as a HUMAN-READABLE markdown file
with YAML-ish frontmatter — the same shape as Claude Code's own memory dir, so
the files can be opened, grepped, hand-edited, and backed up as plain text.

Mirrors the searxng-mcp / comfyui-mcp pattern in this stack: MCPServer over
streamable-HTTP, bound on LOOPBACK ONLY (127.0.0.1), host networking so the
host-networked open-webui can reach it. It never touches Ollama or the LAN.

Two halves of the memory loop:
  * SAVE (this server): the model calls `save_memory` when it learns something
    worth keeping (a preference, a person, an ongoing project) or when the user
    says "remember ...". Files land in MEMORY_DIR, one fact per file, plus a
    MEMORY.md index for humans.
  * RECALL (the memory_recall inlet filter in open-webui): at the start of every
    turn it reads these same files and injects them into the system prompt, so
    the model already "knows" the user with no tool call. See scripts/memory_recall.py.

Files are written as uid 1000 (see docker-compose `user: "1000:1000"`) so they
are owned by `jacob` on the host and stay hand-editable.
"""
import json
import os
import re
import time
import tempfile

from mcp.server.mcpserver import MCPServer

MEMORY_DIR = os.environ.get("MEMORY_DIR", "/data/memory")
HOST = os.environ.get("MCP_HTTP_HOST", "127.0.0.1")
PORT = int(os.environ.get("MCP_HTTP_PORT", "9400"))
INDEX = "MEMORY.md"

# Taxonomy tuned for a home assistant. Unknown types fold to "reference".
TYPES = ("user", "household", "project", "reference")

# WHOSE FACT IS THIS? Every memory carries an `owner`. HOUSEHOLD is the shared
# pool everyone sees; anything else is one person's own and is shown only to
# them. The read side (scripts/memory_recall.py) is what ENFORCES this -- see
# the note on save_memory below for why the write side cannot.
HOUSEHOLD = "household"


def _norm_owner(o: str) -> str:
    """Owner keys are slugs. Empty or unsluggable input folds to the shared pool.

    Deliberately NOT _slug(): that one invents a unique `memory-<timestamp>`
    name when its input slugs to nothing, which is right for naming a file and
    wrong here -- it would mint an owner key no account can ever match, and the
    memory would be silently invisible to every single person.
    """
    o = re.sub(r"[^a-z0-9]+", "-", (o or "").strip().lower()).strip("-")[:64]
    return o or HOUSEHOLD

mcp = MCPServer("memory")

# A tool's description is prompt engineering: it is the text the model reads when
# deciding whether and how to call the tool. This repo is public, so the tuned
# wording lives in the git-ignored prompts/ dir (bind-mounted read-only at
# /prompts; see prompts/README.md) and only a short factual fallback ships in
# source. If the file is absent the server still starts and the tools still work
# -- the model just gets less guidance -- because a crash-looping memory server
# is a worse outcome than a terser tool description.
TOOL_DESC_FILE = os.environ.get("TOOL_DESC_FILE", "/prompts/memory-mcp-tools.json")
try:
    with open(TOOL_DESC_FILE, encoding="utf-8") as _f:
        _TOOL_DESC = json.load(_f)
except (OSError, ValueError):
    _TOOL_DESC = {}


def _desc(name: str):
    """Tuned description for `name`, or None to fall back to the docstring."""
    return _TOOL_DESC.get(name) or None


# --- storage helpers ---------------------------------------------------------

def _slug(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").strip().lower()).strip("-")
    return s[:64] or f"memory-{int(time.time())}"


def _norm_type(t: str) -> str:
    t = (t or "").strip().lower()
    return t if t in TYPES else "reference"


def _path(slug: str) -> str:
    return os.path.join(MEMORY_DIR, f"{slug}.md")


def _write_atomic(path: str, text: str) -> None:
    """Write via temp+rename so the recall filter never reads a half-written file."""
    os.makedirs(MEMORY_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=MEMORY_DIR, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(tmp, 0o644)  # world-readable so the recall filter reads it regardless of open-webui's uid
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def _parse(path: str) -> dict | None:
    """Parse a memory file into {name, description, type, content}. Minimal
    frontmatter parser (no PyYAML dep) matching what _render writes."""
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
    return {
        "name": meta.get("name") or os.path.splitext(os.path.basename(path))[0],
        "description": meta.get("description", ""),
        "type": _norm_type(meta.get("type", "")),
        # Files written before multi-user support have no `owner:` line. They
        # predate any second account, so folding them to the shared pool is
        # correct -- there was only one person for them to belong to.
        "owner": _norm_owner(meta.get("owner", "")),
        "content": body.strip(),
    }


def _render(name: str, description: str, mtype: str, content: str,
            owner: str = HOUSEHOLD) -> str:
    return (
        "---\n"
        f"name: {name}\n"
        f"description: {description}\n"
        f"type: {mtype}\n"
        f"owner: {owner}\n"
        "---\n\n"
        f"{content.strip()}\n"
    )


def _all() -> list[dict]:
    if not os.path.isdir(MEMORY_DIR):
        return []
    out = []
    for fn in sorted(os.listdir(MEMORY_DIR)):
        if not fn.endswith(".md") or fn == INDEX:
            continue
        m = _parse(os.path.join(MEMORY_DIR, fn))
        if m:
            out.append(m)
    return out


def _visible_to(mems: list[dict], owner: str) -> list[dict]:
    """The shared pool, plus `owner`'s own facts.

    FAIL CLOSED: with no owner (an unauthenticated or unrecognised caller) this
    returns the shared pool ONLY -- never everything. The same rule is
    duplicated in scripts/memory_recall.py, which is the half that actually
    guards the chat; keep the two in step.
    """
    who = _norm_owner(owner) if owner else HOUSEHOLD
    return [m for m in mems if m["owner"] in (HOUSEHOLD, who)]


def _rebuild_index() -> None:
    """Maintain MEMORY.md — a human-browsable index, one line per fact."""
    mems = _all()
    lines = ["# MEMORY", "",
             "Persistent memory for the local AI. One fact per file; this index is",
             "auto-generated by memory-mcp. Files are plain markdown — hand-edit freely.",
             ""]
    for t in TYPES:
        group = [m for m in mems if m["type"] == t]
        if not group:
            continue
        lines.append(f"## {t}")
        for m in group:
            desc = m["description"] or (m["content"][:80])
            # The owner is shown for personal facts only -- tagging every shared
            # fact "(household)" would be noise on what is mostly a shared index.
            who = "" if m["owner"] == HOUSEHOLD else f" _({m['owner']})_"
            lines.append(f"- [{m['name']}]({m['name']}.md){who} — {desc}")
        lines.append("")
    _write_atomic(os.path.join(MEMORY_DIR, INDEX), "\n".join(lines).rstrip() + "\n")


# --- tools -------------------------------------------------------------------

@mcp.tool(description=_desc("save_memory"))
def save_memory(content: str, type: str = "user",
                name: str = "", description: str = "",
                owner: str = HOUSEHOLD) -> str:
    """Save a long-term memory about the user.

    Args:
      content: the fact, as a short clear statement.
      type: one of "user", "household", "project", "reference".
      name: OPTIONAL kebab-case id; derived from the content if omitted.
            Reusing an existing name updates that memory.
      description: OPTIONAL one-line summary; the content is used if omitted.
      owner: "household" (everyone in the house sees it — the default) or the
             key of the person it belongs to, which the recall block names as
             "You are talking to <key>". Use the person's key for anything
             personal; use "household" for shared facts.
    """
    content = (content or "").strip()
    if not content:
        return "Nothing to save: content was empty."
    mtype = _norm_type(type)
    slug = _slug(name or content)
    desc = (description or content).strip().splitlines()[0][:200]
    who = _norm_owner(owner)
    _write_atomic(_path(slug), _render(slug, desc, mtype, content, who))
    _rebuild_index()
    return f"Saved memory '{slug}' ({mtype}, owner: {who})."


@mcp.tool(description=_desc("list_memories"))
def list_memories(owner: str = "") -> str:
    """List long-term memories, grouped by type.

    Args:
      owner: OPTIONAL. Pass the current person's key to see the shared
             household facts plus that person's own. Omit to list the shared
             facts only.
    """
    mems = _visible_to(_all(), owner)
    if not mems:
        return "No memories saved yet."
    lines = []
    for t in TYPES:
        group = [m for m in mems if m["type"] == t]
        if not group:
            continue
        lines.append(f"[{t}]")
        for m in group:
            who = "" if m["owner"] == HOUSEHOLD else f" ({m['owner']})"
            lines.append(f"  - {m['name']}{who}: {m['content']}")
    return "\n".join(lines)


@mcp.tool(description=_desc("update_memory"))
def update_memory(name: str, content: str = "", description: str = "",
                  type: str = "", owner: str = "") -> str:
    """Update an existing memory by its `name`. Only the fields you pass are changed."""
    slug = _slug(name)
    existing = _parse(_path(slug))
    if not existing:
        return f"No memory named '{slug}'. Use save_memory to create it."
    new_content = content.strip() or existing["content"]
    new_type = _norm_type(type) if type else existing["type"]
    new_owner = _norm_owner(owner) if owner else existing["owner"]
    new_desc = (description.strip() or existing["description"]
                or new_content.splitlines()[0][:200])
    _write_atomic(_path(slug),
                  _render(slug, new_desc, new_type, new_content, new_owner))
    _rebuild_index()
    return f"Updated memory '{slug}'."


@mcp.tool(description=_desc("delete_memory"))
def delete_memory(name: str) -> str:
    """Delete a memory permanently by its `name`."""
    slug = _slug(name)
    p = _path(slug)
    if not os.path.exists(p):
        return f"No memory named '{slug}'."
    os.remove(p)
    _rebuild_index()
    return f"Deleted memory '{slug}'."


if __name__ == "__main__":
    os.makedirs(MEMORY_DIR, exist_ok=True)
    _rebuild_index()
    # host/port are `run` kwargs in mcp 2.x, not constructor args. They must be
    # passed: the default host is 127.0.0.1, which in a container means nothing
    # outside the pod can reach it.
    mcp.run(transport="streamable-http", host=HOST, port=PORT)
