#!/usr/bin/env python3
"""Create the `assistant` Open WebUI model, backed by gemma4:26b. Idempotent.

Run INSIDE the open-webui container (the DB lives in its volume):
    docker cp scripts/openwebui-assistant-model.py open-webui:/tmp/
    docker exec open-webui python3 /tmp/openwebui-assistant-model.py
    docker restart open-webui

WHY A SEPARATE ROW, not `base_model_id` on the existing gemma4:31b row:
Open WebUI skips a custom model whose id collides with a real backend model id
once it has a base_model_id set — utils/models.py:

    elif custom_model.is_active:
        if custom_model.id in existing_ids:
            continue

Setting base_model_id on the `gemma4:31b` row would therefore drop its name,
toolIds, filterIds and info from the model list. Chat would still route to the
base model (routers/ollama.py), but the assistant would silently lose its tools
and the memory_recall filter. A row with a NEW id takes the working path.

WHY 26b: on a 24 GB card gemma4:31b runs 32k context at 21 GB and still spills
~9% to CPU, leaving <1 GB free. gemma4:26b runs 65,536 context at 17 GB, 100% on
GPU, with ~4.3 GB free — its embedding length is 2,816 vs 5,376, so KV cache
costs roughly half per token. More context AND no CPU spill; see the README.

num_ctx must be set HERE: a derived row's own params are applied, the base row's
are not (routers/ollama.py applies model_info.params for the requested id only).

Copies the system prompt, tools and filter scope from the gemma4:31b row, which
is left intact as a fallback.
"""
import sqlite3, json, time, sys

DB = "/app/backend/data/webui.db"
SRC = "gemma4:31b"          # config donor, left untouched
NEW = "assistant"
BASE = "gemma4:26b"         # weights actually used
NUM_CTX = 65536
TOOL_IDS = ["server:mcp:searxng-web", "server:mcp:home-assistant", "server:mcp:memory"]
FILTER_IDS = ["memory_recall"]

try:
    c = sqlite3.connect(DB)
except sqlite3.Error as e:
    sys.exit(f"cannot open {DB}: {e}")
cur = c.cursor()

# Donor row — we need its user_id (owner) and system prompt.
src = cur.execute("select user_id, meta, params from model where id=?", (SRC,)).fetchone()
if not src:
    sys.exit(f"model row '{SRC}' not found; wire the base chat model first")
src_uid, src_meta_s, src_params_s = src
src_params = json.loads(src_params_s or "{}")
src_meta = json.loads(src_meta_s or "{}")

system = src_params.get("system") or ""
if not system:
    sys.exit(f"'{SRC}' has no system prompt to copy; refusing to create a bare assistant")

# Sanity-check the base model exists as a row, so a typo doesn't create a model
# that silently 404s at chat time.
if not cur.execute("select 1 from model where id=?", (BASE,)).fetchone():
    print(f"WARNING: no '{BASE}' row in the model table — verify the Ollama model is pulled")

now = int(time.time())
existing = cur.execute("select meta, params from model where id=?", (NEW,)).fetchone()

if existing:
    # Reconcile in place — extend, don't clobber anything added by hand.
    meta = json.loads(existing[0] or "{}")
    params = json.loads(existing[1] or "{}")
else:
    meta = dict(src_meta)          # inherit capabilities/description/tags
    params = {}

tool_ids = meta.get("toolIds") or []
for t in TOOL_IDS:
    if t not in tool_ids:
        tool_ids.append(t)
meta["toolIds"] = tool_ids

filter_ids = meta.get("filterIds") or []
for f in FILTER_IDS:
    if f not in filter_ids:
        filter_ids.append(f)
meta["filterIds"] = filter_ids

caps = meta.get("capabilities") or {}
caps["builtin_tools"] = True
meta["capabilities"] = caps
meta["description"] = "Chat assistant (tools + memory), running on " + BASE

params["system"] = system
params["num_ctx"] = NUM_CTX

if existing:
    cur.execute(
        "update model set base_model_id=?, name=?, meta=?, params=?, updated_at=?, is_active=1 "
        "where id=?",
        (BASE, NEW, json.dumps(meta), json.dumps(params), now, NEW))
    print(f"model '{NEW}': reconciled")
else:
    cur.execute(
        "insert into model (id, user_id, base_model_id, name, meta, params, "
        "created_at, updated_at, is_active) values (?,?,?,?,?,?,?,?,1)",
        (NEW, src_uid, BASE, NEW, json.dumps(meta), json.dumps(params), now, now))
    print(f"model '{NEW}': created")

print(f"  base_model_id : {BASE}")
print(f"  num_ctx       : {NUM_CTX}")
print(f"  toolIds       : {tool_ids}")
print(f"  filterIds     : {filter_ids}")
print(f"  system prompt : copied from {SRC} ({len(system)} chars)")

c.commit()
c.close()
print(f"done. Restart open-webui, then select '{NEW}' in your client.")
