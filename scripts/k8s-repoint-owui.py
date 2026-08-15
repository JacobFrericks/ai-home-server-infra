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
  * Ollama and Home Assistant stay on Docker Compose and are host-network, so a
    pod reaches them by NODE IP. ufw allows those ports from the pod CIDR only.
  * SearXNG and memory-mcp migrated, so they are reached by in-cluster Service
    DNS (or ClusterIP where a non-cluster client needs a stable address).
  * comfyui-mcp stays on Compose until ComfyUI migrates; node IP, ufw-gated.
"""
import json, sqlite3, sys, time

DB = "/app/backend/data/webui.db"
NODE_IP = "192.168.86.63"

CONFIG = {
    "ollama.base_urls":             json.dumps([f"http://{NODE_IP}:11434"]),
    "rag.ollama.base_url":          json.dumps(f"http://{NODE_IP}:11434"),
    "web.search.searxng_query_url": json.dumps(
        "http://searxng.ai-stack.svc.cluster.local:8080/search?q=<query>"),
}
MCP_URLS = {
    "searxng-web":    "http://searxng-mcp.ai-stack.svc.cluster.local:9200/mcp",
    "memory":         "http://memory-mcp.ai-stack.svc.cluster.local:9400/mcp",
    "home-assistant": f"http://{NODE_IP}:8123/api/mcp",
    "generate":       f"http://{NODE_IP}:9300/mcp",
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
