#!/usr/bin/env python3
"""Repoint Home Assistant's GPU-tier integrations at the in-cluster Services.

MUST run with Home Assistant STOPPED. HA holds config entries in memory and
rewrites .storage on shutdown, so editing a running instance is silently undone.

HA is a Docker container: it cannot resolve *.svc.cluster.local, so it has to
use ClusterIPs. Both of these are PINNED in the k8s manifests precisely because
HA caches them here and only re-reads on restart -- an unpinned Service that got
recreated would break these days later with nothing pointing at the cause.

Idempotent: re-running reports "already correct".
"""
import json
import shutil
import sys
import time

P = "/home/jacob/Documents/homeassistant/.storage/core.config_entries"

# domain -> (key within entry["data"], new value)
WANT = {
    "ollama":            ("url",      "http://10.43.200.11:11434"),
    "comfyui_generator": ("base_url", "http://10.43.153.145:8188"),
}

backup = f"{P}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(P, backup)
print(f"  backup: {backup}")

with open(P) as f:
    d = json.load(f)

changed = 0
for e in d["data"]["entries"]:
    dom = e.get("domain")
    if dom not in WANT:
        continue
    key, val = WANT[dom]
    old = e.get("data", {}).get(key)
    if old == val:
        print(f"  {dom}.{key}: already correct ({val})")
        continue
    e["data"][key] = val
    # The ollama entry's title is a copy of the URL; keep it honest so the UI
    # does not show a stale address that no longer resolves to anything.
    if e.get("title") == old:
        e["title"] = val
    print(f"  {dom}.{key}: {old} -> {val}")
    changed += 1

if not changed:
    print("  nothing to do")
    sys.exit(0)

tmp = P + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, indent=2)
# Preserve HA's ownership/mode rather than inheriting root's.
shutil.copystat(P, tmp)
import os
st = os.stat(P)
os.chown(tmp, st.st_uid, st.st_gid)
os.replace(tmp, P)
print(f"  wrote {P}; {changed} entr(ies) changed")
