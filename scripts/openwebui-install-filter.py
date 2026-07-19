#!/usr/bin/env python3
# Idempotently install a filter Function into Open WebUI (global + active).
# Runs INSIDE the open-webui container (needs its DB + the filter source):
#   docker cp scripts/<filter>.py open-webui:/tmp/<filter>.py
#   docker cp scripts/openwebui-install-filter.py open-webui:/tmp/openwebui-install-filter.py
#   docker exec open-webui python3 /tmp/openwebui-install-filter.py \
#       <func_id> "<Display Name>" /tmp/<filter>.py "<description>"
import sqlite3, json, time, sys

DB = "/app/backend/data/webui.db"
if len(sys.argv) < 4:
    sys.exit("usage: openwebui-install-filter.py <func_id> <name> <src_path> [description]")
FUNC_ID, NAME, SRC = sys.argv[1], sys.argv[2], sys.argv[3]
DESC = sys.argv[4] if len(sys.argv) > 4 else NAME

try:
    src = open(SRC).read()
except OSError as e:
    sys.exit(f"cannot read filter source {SRC}: {e}")

try:
    c = sqlite3.connect(DB)
except sqlite3.Error as e:
    sys.exit(f"cannot open {DB}: {e}")
cur = c.cursor()

# Owner: first (admin) user, matching the image-gen installer.
row = cur.execute("select id from user order by created_at limit 1").fetchone()
if not row:
    sys.exit("no user found; create the admin account first")
uid = row[0]

meta = {"description": DESC, "manifest": {}}
now = int(time.time())

if cur.execute("select 1 from function where id=?", (FUNC_ID,)).fetchone():
    cur.execute(
        "update function set content=?, meta=?, type='filter', is_active=1, "
        "is_global=1, updated_at=? where id=?",
        (src, json.dumps(meta), now, FUNC_ID),
    )
    print(f"function {FUNC_ID}: updated")
else:
    cur.execute(
        "insert into function (id, user_id, name, type, content, meta, valves, "
        "is_active, is_global, created_at, updated_at) values (?,?,?,?,?,?,?,1,1,?,?)",
        (FUNC_ID, uid, NAME, "filter", src, json.dumps(meta), json.dumps({}), now, now),
    )
    print(f"function {FUNC_ID}: inserted")

c.commit()
print("done. Restart open-webui to load the filter.")
