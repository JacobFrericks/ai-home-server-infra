#!/usr/bin/env python3
"""Wire the Home Assistant control tool into Open WebUI's DB. Idempotent.

Run INSIDE the open-webui container (the DB lives in its volume):
    docker cp scripts/openwebui-ha-bridge.py open-webui:/tmp/
    docker exec -e HA_MCP_TOKEN=<token> open-webui python3 /tmp/openwebui-ha-bridge.py
    docker restart open-webui

Adds:
  * a `home-assistant` MCP tool server (streamable-HTTP, HA's /api/mcp,
    bearer-authenticated with a dedicated HA long-lived token)
  * attaches `server:mcp:home-assistant` to the existing `gemma4:31b` workspace
    model WITHOUT disturbing its other tools (e.g. searxng-web).
Mirrors openwebui-image-gen.py. See README "Home Assistant control".

Modes:
  (default)   ensure wiring; requires $HA_MCP_TOKEN if the connection is missing
              or has an empty key.
  --check     print "WIRED" if the connection (with a non-empty bearer key) and
              the gemma4:31b toolId are both present, else "NEEDS_TOKEN".
              Never writes. Used by setup-ha-owui-bridge.sh to decide whether to
              mint a fresh token.
"""
import sqlite3, json, os, sys, time

DB = "/app/backend/data/webui.db"
CHECK = "--check" in sys.argv


def load_conns(cur):
    row = cur.execute("select value from config where key='tool_server.connections'").fetchone()
    return (json.loads(row[0]) if row and row[0] else []), bool(row)


def ha_conn(conns):
    for c in conns:
        if (c.get("info") or {}).get("id") == "home-assistant":
            return c
    return None


def model_toolids(cur):
    m = cur.execute("select meta from model where id='gemma4:31b'").fetchone()
    if not (m and m[0]):
        return None
    return (json.loads(m[0]).get("toolIds") or [])


try:
    c = sqlite3.connect(DB)
except sqlite3.Error as e:
    sys.exit(f"cannot open {DB}: {e}")
cur = c.cursor()

conns, have_row = load_conns(cur)
existing = ha_conn(conns)
tids = model_toolids(cur)
has_conn = bool(existing) and bool((existing.get("key") or "").strip()) \
    and existing.get("auth_type") == "bearer"
has_tool = tids is not None and "server:mcp:home-assistant" in tids

if CHECK:
    print("WIRED" if (has_conn and has_tool) else "NEEDS_TOKEN")
    sys.exit(0)

# --- ensure connection -------------------------------------------------------
if has_conn:
    print("tool_server.connections: home-assistant already present")
else:
    token = (os.environ.get("HA_MCP_TOKEN") or "").strip()
    if not token:
        sys.exit("HA_MCP_TOKEN not set and no existing home-assistant connection; "
                 "cannot wire without a dedicated HA token")
    entry = {
        "type": "mcp",
        "url": "http://127.0.0.1:8123/api/mcp",
        "auth_type": "bearer",
        "key": token,
        "config": {"enable": True, "function_name_filter_list": ""},
        "info": {
            "id": "home-assistant",
            "name": "Home Assistant",
            "description": "Control Home Assistant (lights, media players, shopping list) via Assist",
        },
    }
    if existing:                     # present but keyless/wrong auth: replace in place
        conns = [entry if (x.get("info") or {}).get("id") == "home-assistant" else x
                 for x in conns]
    else:
        conns.append(entry)
    if have_row:
        cur.execute("update config set value=?, updated_at=? where key='tool_server.connections'",
                    (json.dumps(conns), int(time.time())))
    else:
        cur.execute("insert into config (key, value, updated_at) values (?,?,?)",
                    ("tool_server.connections", json.dumps(conns), int(time.time())))
    print("tool_server.connections: added home-assistant (now %d)" % len(conns))

# --- attach tool to gemma4:31b (preserve other toolIds) ----------------------
m = cur.execute("select meta from model where id='gemma4:31b'").fetchone()
if not (m and m[0]):
    sys.exit("model gemma4:31b not found — run the base Open WebUI model setup first")
meta = json.loads(m[0])
tids = meta.get("toolIds") or []
if "server:mcp:home-assistant" in tids:
    print("gemma4:31b: home-assistant tool already attached")
else:
    tids.append("server:mcp:home-assistant")
    meta["toolIds"] = tids
    meta.setdefault("capabilities", {})["builtin_tools"] = True
    cur.execute("update model set meta=?, updated_at=? where id='gemma4:31b'",
                (json.dumps(meta), int(time.time())))
    print("gemma4:31b: attached home-assistant; toolIds now", tids)

c.commit()
c.close()
print("done. Restart open-webui to load the tool connection.")
