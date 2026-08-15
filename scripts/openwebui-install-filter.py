#!/usr/bin/env python3
# Idempotently install a filter Function into Open WebUI (active; global by default).
# Runs INSIDE the open-webui container (needs its DB + the filter source):
#   docker cp scripts/<filter>.py open-webui:/tmp/<filter>.py
#   docker cp scripts/openwebui-install-filter.py open-webui:/tmp/openwebui-install-filter.py
#   docker exec open-webui python3 /tmp/openwebui-install-filter.py \
#       <func_id> "<Display Name>" /tmp/<filter>.py "<description>" [--models a,b]
#
# --models scopes the filter to specific models instead of running it for every
# model: it clears is_global and adds the filter id to each listed model's
# meta.filterIds. Open WebUI resolves the union of global filters and the
# model's own filterIds (utils/filter.py get_sorted_filter_ids), so one or the
# other is enough -- setting both would run it everywhere anyway.
# Without --models the filter stays global, which is what render_tool_images and
# ensure_model_tools rely on.
import sqlite3, json, time, sys

DB = "/app/backend/data/webui.db"

argv = sys.argv[1:]
models = []
if "--models" in argv:
    i = argv.index("--models")
    try:
        models = [m.strip() for m in argv[i + 1].split(",") if m.strip()]
    except IndexError:
        sys.exit("--models needs a comma-separated model id list")
    del argv[i:i + 2]

# --prompt-file <token>=<path>: substitute @@<token>@@ in the filter source with the
# file's contents at install time. Prompt text is server-only (the git-ignored
# prompts/ dir -- see prompts/README.md) because this repo is public, so the tracked
# filter source carries a placeholder and the real sentence only ever reaches the DB.
prompt_subs = []
while "--prompt-file" in argv:
    i = argv.index("--prompt-file")
    try:
        token, _, path = argv[i + 1].partition("=")
    except IndexError:
        sys.exit("--prompt-file needs <TOKEN>=<path>")
    if not token or not path:
        sys.exit(f"--prompt-file wants <TOKEN>=<path>, got {argv[i + 1]!r}")
    prompt_subs.append((token, path))
    del argv[i:i + 2]

if len(argv) < 3:
    sys.exit("usage: openwebui-install-filter.py <func_id> <name> <src_path> [description] "
             "[--models a,b] [--prompt-file TOKEN=path]")
FUNC_ID, NAME, SRC = argv[0], argv[1], argv[2]
DESC = argv[3] if len(argv) > 3 else NAME

try:
    src = open(SRC, encoding="utf-8").read()
except OSError as e:
    sys.exit(f"cannot read filter source {SRC}: {e}")

for token, path in prompt_subs:
    placeholder = f"@@{token}@@"
    if placeholder not in src:
        sys.exit(f"{SRC} has no {placeholder} to substitute; refusing to install "
                 f"a filter whose prompt would silently go missing")
    try:
        text = open(path, encoding="utf-8").read().strip()
    except OSError as e:
        sys.exit(f"cannot read prompt file {path}: {e}\nSee prompts/README.md")
    if not text:
        sys.exit(f"prompt file {path} is empty; refusing to install a blank prompt")
    # The filter source is Python: the value lands inside a "..." literal, so escape
    # backslashes, quotes and newlines rather than pasting raw text into the source.
    src = src.replace(placeholder,
                      text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n"))
    print(f"substituted {placeholder} <- {path} ({len(text)} chars)")

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
is_global = 0 if models else 1

if cur.execute("select 1 from function where id=?", (FUNC_ID,)).fetchone():
    cur.execute(
        "update function set content=?, meta=?, type='filter', is_active=1, "
        "is_global=?, updated_at=? where id=?",
        (src, json.dumps(meta), is_global, now, FUNC_ID),
    )
    print(f"function {FUNC_ID}: updated (is_global={is_global})")
else:
    cur.execute(
        "insert into function (id, user_id, name, type, content, meta, valves, "
        "is_active, is_global, created_at, updated_at) values (?,?,?,?,?,?,?,1,?,?,?)",
        (FUNC_ID, uid, NAME, "filter", src, json.dumps(meta), json.dumps({}), is_global, now, now),
    )
    print(f"function {FUNC_ID}: inserted (is_global={is_global})")

# When scoping, attach to the named models and detach from every other model, so
# re-running after a scope change converges instead of leaving the filter behind
# on a model it was previously attached to.
if models:
    for (mid, meta_s) in cur.execute("select id, meta from model").fetchall():
        mmeta = json.loads(meta_s or "{}")
        fids = list(mmeta.get("filterIds") or [])
        want = mid in models
        if want and FUNC_ID not in fids:
            fids.append(FUNC_ID)
        elif not want and FUNC_ID in fids:
            fids = [f for f in fids if f != FUNC_ID]
        else:
            continue
        mmeta["filterIds"] = fids
        cur.execute("update model set meta=?, updated_at=? where id=?",
                    (json.dumps(mmeta), now, mid))
        print(f"model {mid}: filterIds -> {fids}")

    missing = [m for m in models
               if not cur.execute("select 1 from model where id=?", (m,)).fetchone()]
    if missing:
        print(f"WARNING: no model row for {missing} -- filter will not run for them")

c.commit()
print("done. Restart open-webui to load the filter.")
