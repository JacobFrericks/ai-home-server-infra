#!/usr/bin/env python3
"""Wire the persistent-memory MCP tool into Open WebUI's DB. Idempotent.

Run INSIDE the open-webui container (the DB lives in its volume):
    docker cp scripts/openwebui-memory.py open-webui:/tmp/
    docker exec open-webui python3 /tmp/openwebui-memory.py
    docker restart open-webui

Does three things, all as in-place upserts that PRESERVE existing config:
  1. registers the `memory` MCP tool server (streamable-HTTP, 127.0.0.1:9400/mcp)
     in tool_server.connections;
  2. appends `server:mcp:memory` to the assistant model's meta.toolIds
     (keeping searxng-web / home-assistant) and ensures builtin_tools is on;
  3. appends a short memory paragraph to that model's system prompt (once).

The read half of the loop is the memory_recall inlet filter; see README "Memory".
Targets the `assistant` model (gemma4:26b-backed); other models are left alone.
"""
import sqlite3, json, time, sys, os

DB = "/app/backend/data/webui.db"
CONN_ID = "memory"
TOOL_ID = "server:mcp:memory"
MODEL = "assistant"

# The prompt text itself lives in the git-ignored prompts/ dir (see prompts/README.md):
# this repo is public, and a system prompt is configuration, not source. setup-memory.sh
# docker-cp's it to /tmp/memory-system.txt alongside this script.
PROMPT_FILE = os.environ.get("MEMORY_PROMPT_FILE", "/tmp/memory-system.txt")
try:
    _prompt = open(PROMPT_FILE, encoding="utf-8").read().strip()
except OSError as e:
    sys.exit(f"cannot read memory system prompt {PROMPT_FILE}: {e}\n"
             f"Expected prompts/memory-system.txt to be copied in; see prompts/README.md")
if not _prompt:
    sys.exit(f"{PROMPT_FILE} is empty; refusing to install a blank memory prompt")

PROMPT_ADDITION = "\n\n" + _prompt
# Idempotency marker: a slice of the prompt itself, so no fragment of the text has
# to be duplicated here (it is server-only; see prompts/README.md).
PROMPT_MARKER = _prompt[:40]

try:
    c = sqlite3.connect(DB)
except sqlite3.Error as e:
    sys.exit(f"cannot open {DB}: {e}")
cur = c.cursor()

# 1) MCP tool server (self-healing: drop any stale entry, then add canonical).
row = cur.execute("select value from config where key='tool_server.connections'").fetchone()
conns = json.loads(row[0]) if row and row[0] else []
conns = [x for x in conns if (x.get("info") or {}).get("id") != CONN_ID]
conns.append({
    "type": "mcp",
    "url": "http://127.0.0.1:9400/mcp",
    "auth_type": "none",
    "key": "",
    "config": {"enable": True, "function_name_filter_list": ""},
    "info": {
        "id": CONN_ID,
        "name": "Persistent Memory",
        "description": "Save/recall long-term memories (markdown files via memory-mcp)",
    },
})
now = int(time.time())
if row:
    cur.execute("update config set value=?, updated_at=? where key='tool_server.connections'",
                (json.dumps(conns), now))
else:
    cur.execute("insert into config (key, value, updated_at) values (?,?,?)",
                ("tool_server.connections", json.dumps(conns), now))
print(f"tool_server.connections: ensured '{CONN_ID}' (now {len(conns)})")

# 2) + 3) assistant model row — extend, don't clobber.
r = cur.execute("select user_id, meta, params from model where id=?", (MODEL,)).fetchone()
if not r:
    sys.exit(f"model row '{MODEL}' not found; wire the base chat model first")
uid, meta_s, params_s = r
meta = json.loads(meta_s or "{}")
params = json.loads(params_s or "{}")

tool_ids = meta.get("toolIds") or []
if TOOL_ID not in tool_ids:
    tool_ids.append(TOOL_ID)
meta["toolIds"] = tool_ids
caps = meta.get("capabilities") or {}
caps["builtin_tools"] = True
meta["capabilities"] = caps

system = params.get("system") or ""
if PROMPT_MARKER not in system:
    system = (system.rstrip() + PROMPT_ADDITION).strip()
params["system"] = system

cur.execute("update model set meta=?, params=?, updated_at=?, is_active=1 where id=?",
            (json.dumps(meta), json.dumps(params), now, MODEL))
print(f"model {MODEL}: toolIds={tool_ids}; memory prompt "
      f"{'added' if PROMPT_MARKER in system else 'MISSING'}")

c.commit()
c.close()
print("done. Restart open-webui to load the tool connection.")
