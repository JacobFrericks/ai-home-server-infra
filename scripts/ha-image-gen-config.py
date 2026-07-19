#!/usr/bin/env python3
"""Create the ComfyUI AI Task config entry in Home Assistant by driving the
integration's config flow through HA's REST API. Idempotent, NO root needed
(HA performs it as itself; nothing touches root-owned .storage directly).

Robust to a just-restarted HA: it waits for the API to come up and for the
custom integration's config-flow handler to register before creating the entry.

Requires: the `comfyui_generator` component installed and the workflow at
/config/comfyui_workflow_api.json. Reads the HA token from $HA_TOKEN, or falls
back to the prometheus container's ha_token (as verify-services.sh does).

Produces the same entry the UI flow would: ComfyUI 127.0.0.1:8188, that workflow,
node ids prompt=6 / resolution=5 / seed=3 (matching comfyui-mcp/workflow_api.json),
1024x1024, 120s timeout.
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
    """Call the API, retrying on connection errors (HA still starting) until
    retry_secs elapse. If retry_on_http, also retry on 4xx/5xx (handler not yet
    registered). Exits with a clear message once the deadline passes."""
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
    if e.get("domain") == "comfyui_generator":
        print("comfyui_generator config entry already present — nothing to do")
        sys.exit(0)

# Start the flow, retrying while the custom handler registers (up to 60s).
flow = call("POST", "/api/config/config_entries/flow",
            {"handler": "comfyui_generator", "show_advanced_options": False},
            retry_secs=60, retry_on_http=True)
fid = flow["flow_id"]

flow = call("POST", f"/api/config/config_entries/flow/{fid}",
            {"workflow_title": "ComfyUI SDXL",
             "base_url": "http://127.0.0.1:8188",
             "timeout": 120,
             "workflow_path": "/config/comfyui_workflow_api.json"})
if flow.get("errors"):
    sys.exit(f"connection/workflow step failed: {flow['errors']} "
             "(is ComfyUI up and /config/comfyui_workflow_api.json present?)")

flow = call("POST", f"/api/config/config_entries/flow/{fid}",
            {"workflow_prompt_node_id": "6",
             "workflow_resolution_node_id": "5",
             "seed_node_id": "3",
             "image_width": 1024,
             "image_height": 1024})
if flow.get("type") == "create_entry":
    print("created comfyui_generator config entry:", flow.get("title"))
else:
    sys.exit(f"unexpected config-flow result: {json.dumps(flow)[:300]}")
