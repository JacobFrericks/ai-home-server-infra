#!/usr/bin/env python3
"""Wire the image-generation tool + model into Open WebUI's DB. Idempotent.

Run INSIDE the open-webui container (the DB lives in its volume):
    docker cp scripts/openwebui-image-gen.py open-webui:/tmp/
    docker exec open-webui python3 /tmp/openwebui-image-gen.py
    docker restart open-webui

Adds:
  * a `generate` MCP tool server (streamable-HTTP, 127.0.0.1:9300/mcp),
    whose single tool registers in Open WebUI as `generate_image`
  * a customized `gemma4:12b` workspace model with that tool attached, thinking
    off, and num_ctx pinned to 8192 (so its KV cache stays small next to SDXL).
Mirrors the existing searxng-web / gemma4:31b setup. See README "Image generation".
"""
import sqlite3, json, time, sys

DB = "/app/backend/data/webui.db"

try:
    c = sqlite3.connect(DB)
except sqlite3.Error as e:
    sys.exit(f"cannot open {DB}: {e}")
cur = c.cursor()

# 1) MCP tool server in tool_server.connections (self-healing).
#    Open WebUI registers each MCP tool as "<connection_id>_<mcp_tool_name>" and
#    routes calls by that exact string. A small model mangles a namespaced id:
#    in prompt-based ("legacy") tool calling — which some clients (e.g. the
#    Conduit Android app) force per-request regardless of the model's
#    function_calling setting — gemma drops the server prefix and emits the bare
#    raw name; native calling would use the full prefixed name. To route in BOTH
#    modes the registered name must equal what the model emits either way, so the
#    MCP tool is named "image" (see comfyui-mcp/server.py) and the connection id
#    is "generate" -> registered name "generate_image", the canonical name gemma
#    reproduces verbatim. The MCP server is still invoked by its raw name ("image").
CONN_ID = "generate"
LEGACY_IDS = {"comfyui-image", "comfyui_image"}
row = cur.execute("select value from config where key='tool_server.connections'").fetchone()
conns = json.loads(row[0]) if row and row[0] else []
# Drop any legacy or duplicate entry for this server, then (re)add the canonical one.
conns = [x for x in conns if (x.get("info") or {}).get("id") not in (LEGACY_IDS | {CONN_ID})]
conns.append({
    "type": "mcp",
    "url": "http://127.0.0.1:9300/mcp",
    "auth_type": "none",
    "key": "",
    "config": {"enable": True, "function_name_filter_list": ""},
    "info": {
        "id": CONN_ID,
        "name": "Image Generation (SDXL)",
        "description": "Generate images locally via ComfyUI / SDXL",
    },
})
if row:
    cur.execute("update config set value=?, updated_at=? where key='tool_server.connections'",
                (json.dumps(conns), int(time.time())))
else:
    cur.execute("insert into config (key, value, updated_at) values (?,?,?)",
                ("tool_server.connections", json.dumps(conns), int(time.time())))
print("tool_server.connections: set %s (now %d)" % (CONN_ID, len(conns)))

# 2) Customized gemma4:12b workspace model (idempotent upsert).
uid = cur.execute("select user_id from model where id='gemma4:31b'").fetchone()
if not uid:
    uid = cur.execute("select id from user order by created_at limit 1").fetchone()
if not uid:
    sys.exit("no user found in Open WebUI DB; create the admin user first")
uid = uid[0]

meta = {
    "profile_image_url": "/static/favicon.png",
    "description": "Local image generation (SDXL via ComfyUI). Ask it to draw/create a picture.",
    "capabilities": {
        "vision": True, "file_upload": True, "file_context": True,
        "web_search": False, "image_generation": False, "code_interpreter": False,
        "terminal": False, "citations": True, "status_updates": True,
        "builtin_tools": True,
    },
    "toolIds": ["server:mcp:generate"],
    "tags": [],
}
params = {
    "system": (
        "You can generate images with a local image model. When the user asks you to "
        "create, draw, generate, imagine, paint, or make a picture / image / art, call "
        "the generate_image tool, passing a vivid, detailed English description as the "
        "`prompt` argument (translate the user's request into a rich visual description). "
        "The generated image is shown to the user automatically once the tool finishes "
        "— just add one short sentence saying what you made. Never output JSON or restate "
        "the tool call or its arguments. For anything that is not an image request, just "
        "answer normally."
    ),
    "num_ctx": 8192,
    "think": False,
    # Prefer native (API) function calling. Legacy (prompt-based) makes the small
    # model free-form the tool name as text; some clients force legacy per-request
    # regardless of this setting, so the tool is *named* to route in legacy too
    # (registered name == "generate_image"; see the CONN_ID note above). Native is
    # kept as belt-and-suspenders for clients that honour it.
    "function_calling": "native",
}

now = int(time.time())
if cur.execute("select 1 from model where id='gemma4:12b'").fetchone():
    cur.execute("update model set base_model_id=NULL, name=?, meta=?, params=?, updated_at=?, is_active=1 "
                "where id='gemma4:12b'", ("gemma4:12b", json.dumps(meta), json.dumps(params), now))
    print("model gemma4:12b: updated")
else:
    cur.execute("insert into model (id, user_id, base_model_id, name, meta, params, created_at, updated_at, is_active) "
                "values (?,?,?,?,?,?,?,?,1)",
                ("gemma4:12b", uid, None, "gemma4:12b", json.dumps(meta), json.dumps(params), now, now))
    print("model gemma4:12b: inserted")

c.commit()
c.close()
print("done. Restart open-webui to load the tool connection.")
