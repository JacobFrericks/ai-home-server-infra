#!/usr/bin/env python3
"""Enable Home Assistant's MCP Server integration by driving its config flow
through HA's REST API. Idempotent, NO root needed (HA performs it as itself;
nothing touches root-owned .storage directly).

This exposes HA's `assist` toolset over Streamable HTTP at /api/mcp so external
MCP clients (Open WebUI) can control HA. Robust to a just-restarted HA: it waits
for the API to come up before acting.

Reads the HA admin token from $HA_TOKEN, or falls back to the prometheus
container's ha_token (as verify-services.sh / ha-image-gen-config.py do).
"""
import json, os, subprocess, sys, time, urllib.request, urllib.error

HA = os.environ.get("HA_URL", "http://127.0.0.1:8123")


def get_token():
    t = os.environ.get("HA_TOKEN")
    if t:
        return t.strip()
    try:
        out = subprocess.run(["docker", "exec", "prometheus", "cat",
                              "/etc/prometheus/ha_token"],
                             capture_output=True, text=True, timeout=15)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    sys.exit("no HA token: set $HA_TOKEN, or ensure the prometheus container has "
             "/etc/prometheus/ha_token")


TOKEN = get_token()


def _call(method, path, body=None):
    req = urllib.request.Request(
        HA + path, method=method,
        headers={"Authorization": "Bearer " + TOKEN,
                 "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or "null")


def call(method, path, body=None, retry_secs=0, retry_on_http=False):
    deadline = time.time() + retry_secs
    while True:
        try:
            return _call(method, path, body)
        except urllib.error.HTTPError as e:
            if retry_on_http and time.time() < deadline:
                time.sleep(3); continue
            sys.exit(f"HA API {method} {path} -> {e.code}: {e.read().decode()[:200]}")
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            if time.time() < deadline:
                time.sleep(3); continue
            sys.exit(f"HA API {method} {path} unreachable: {e}")


# Wait for the HA API (up to 90s), then idempotency check.
entries = call("GET", "/api/config/config_entries/entry", retry_secs=90)
for e in entries:
    if e.get("domain") == "mcp_server":
        print("mcp_server config entry already present — nothing to do")
        sys.exit(0)

# Single-step flow: expose the `assist` LLM API.
flow = call("POST", "/api/config/config_entries/flow",
            {"handler": "mcp_server", "show_advanced_options": False},
            retry_secs=60, retry_on_http=True)
fid = flow["flow_id"]

flow = call("POST", f"/api/config/config_entries/flow/{fid}",
            {"llm_hass_api": ["assist"]})
if flow.get("type") == "create_entry":
    print("created mcp_server config entry:", flow.get("title"))
else:
    sys.exit(f"unexpected config-flow result: {json.dumps(flow)[:300]}")
