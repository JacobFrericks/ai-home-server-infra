#!/usr/bin/env python3
"""Repoint Open WebUI's PERSISTED endpoint config after the k3s migration. Idempotent.

Run INSIDE the Open WebUI pod:
    kubectl -n ai-stack cp scripts/k8s-repoint-owui.py \
        $(kubectl -n ai-stack get pod -l app=open-webui -o jsonpath='{.items[0].metadata.name}'):/tmp/
    kubectl -n ai-stack exec deploy/open-webui -- python3 /tmp/k8s-repoint-owui.py
    kubectl -n ai-stack rollout restart deploy/open-webui

WHY THIS EXISTS
---------------
Open WebUI seeds OLLAMA_BASE_URL and friends from the environment only on FIRST
init; after that the values live in the `config` table and the env vars are
ignored. A migrated webui.db therefore keeps pointing at the Compose-era
loopback addresses -- which a pod cannot reach -- and the symptom is not an
error but an empty model list: "no models available" in the client, with the
manifest looking perfectly correct.

The MCP tool-server URLs in tool_server.connections have the same problem, for
the same reason, and are fixed here too.

Addresses used, and why:
  * Everything that migrated is reached by in-cluster Service DNS. Open WebUI is
    itself a pod, so DNS is available to it and is preferred over an IP -- it
    survives a Service being deleted and recreated, which a pinned IP does not.
  * Home Assistant is the one remaining Compose dependency. It is host-network,
    so a pod reaches it by NODE IP, with ufw allowing that port from the pod
    CIDR only.

STAGE 5 UPDATE: ollama and comfyui-mcp moved into the cluster, so their node-IP
addresses here went stale in exactly the way this script exists to fix.
The `generate` connection id must NOT change -- Open WebUI prefixes it onto the
MCP server's raw tool name ("image") to build the model-facing "generate_image"
that commit fb81952 tuned. Renaming the connection silently renames the tool.
"""
import json, sqlite3, sys, time

DB = "/app/backend/data/webui.db"
NODE_IP = "192.168.86.63"
OLLAMA = "http://ollama.ai-stack.svc.cluster.local:11434"

CONFIG = {
    "ollama.base_urls":             json.dumps([OLLAMA]),
    "rag.ollama.base_url":          json.dumps(OLLAMA),
    "web.search.searxng_query_url": json.dumps(
        "http://searxng.ai-stack.svc.cluster.local:8080/search?q=<query>"),
}
MCP_URLS = {
    "searxng-web":    "http://searxng-mcp.ai-stack.svc.cluster.local:9200/mcp",
    "memory":         "http://memory-mcp.ai-stack.svc.cluster.local:9400/mcp",
    "home-assistant": f"http://{NODE_IP}:8123/api/mcp",
    "generate":       "http://comfyui-mcp.ai-stack.svc.cluster.local:9300/mcp",
}

try:
    c = sqlite3.connect(DB)
except sqlite3.Error as e:
    sys.exit(f"cannot open {DB}: {e}")
cur, now, changed = c.cursor(), int(time.time()), 0

for key, want in CONFIG.items():
    row = cur.execute("select value from config where key=?", (key,)).fetchone()
    if row is None:
        print(f"config {key}: absent, skipped")
    elif row[0] != want:
        cur.execute("update config set value=?, updated_at=? where key=?", (want, now, key))
        print(f"config {key}: {row[0]} -> {want}")
        changed += 1

row = cur.execute("select value from config where key='tool_server.connections'").fetchone()
if row and row[0]:
    conns = json.loads(row[0])
    for x in conns:
        cid = (x.get("info") or {}).get("id")
        if cid in MCP_URLS and x.get("url") != MCP_URLS[cid]:
            print(f"mcp {cid}: {x.get('url')} -> {MCP_URLS[cid]}")
            x["url"] = MCP_URLS[cid]
            changed += 1
    cur.execute("update config set value=?, updated_at=? where key='tool_server.connections'",
                (json.dumps(conns), now))

c.commit()
c.close()
print(f"done; {changed} value(s) changed"
      + ("" if changed else " (already correct)"))
