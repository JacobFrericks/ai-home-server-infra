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
        "content": body.strip(),
    }


def _render(name: str, description: str, mtype: str, content: str) -> str:
    return (
        "---\n"
        f"name: {name}\n"
        f"description: {description}\n"
        f"type: {mtype}\n"
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
            lines.append(f"- [{m['name']}]({m['name']}.md) — {desc}")
        lines.append("")
    _write_atomic(os.path.join(MEMORY_DIR, INDEX), "\n".join(lines).rstrip() + "\n")


# --- tools -------------------------------------------------------------------

@mcp.tool(description=_desc("save_memory"))
def save_memory(content: str, type: str = "user",
                name: str = "", description: str = "") -> str:
    """Save a long-term memory about the user.

    Args:
      content: the fact, as a short clear statement.
      type: one of "user", "household", "project", "reference".
      name: OPTIONAL kebab-case id; derived from the content if omitted.
            Reusing an existing name updates that memory.
      description: OPTIONAL one-line summary; the content is used if omitted.
    """
    content = (content or "").strip()
    if not content:
        return "Nothing to save: content was empty."
    mtype = _norm_type(type)
    slug = _slug(name or content)
    desc = (description or content).strip().splitlines()[0][:200]
    _write_atomic(_path(slug), _render(slug, desc, mtype, content))
    _rebuild_index()
    return f"Saved memory '{slug}' ({mtype})."


@mcp.tool(description=_desc("list_memories"))
def list_memories() -> str:
    """List everything currently in long-term memory about the user, grouped by type."""
    mems = _all()
    if not mems:
        return "No memories saved yet."
    lines = []
    for t in TYPES:
        group = [m for m in mems if m["type"] == t]
        if not group:
            continue
        lines.append(f"[{t}]")
        for m in group:
            lines.append(f"  - {m['name']}: {m['content']}")
    return "\n".join(lines)


@mcp.tool(description=_desc("update_memory"))
def update_memory(name: str, content: str = "", description: str = "",
                  type: str = "") -> str:
    """Update an existing memory by its `name`. Only the fields you pass are changed."""
    slug = _slug(name)
    existing = _parse(_path(slug))
    if not existing:
        return f"No memory named '{slug}'. Use save_memory to create it."
    new_content = content.strip() or existing["content"]
    new_type = _norm_type(type) if type else existing["type"]
    new_desc = (description.strip() or existing["description"]
                or new_content.splitlines()[0][:200])
    _write_atomic(_path(slug), _render(slug, new_desc, new_type, new_content))
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
