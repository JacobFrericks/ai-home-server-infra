#!/usr/bin/env bash
#
# setup-image-gen.sh — provision the local image-generation feature end to end.
#
# Idempotent: every step is a no-op if already done, so this is the "start over"
# button. Run it AFTER deploy.sh has brought the stack up. It:
#   1. pulls gemma4:12b (the image-gen orchestrator) if missing
#   2. brings up ComfyUI, fixes the first-run volume ownership, downloads the
#      SDXL checkpoint (~6.9 GB) if absent
#   3. builds + starts comfyui-mcp
#   4. wires Open WebUI (comfyui-image tool + gemma4:12b model) via its DB
#   5. installs the vendored Home Assistant AI Task component + workflow and
#      creates its config entry via HA's config-flow API
#
# Env overrides: HA_CONFIG_DIR (default /home/jacob/Documents/homeassistant).
# Requires: docker (jacob is in the docker group). No sudo needed.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

log() { echo "[setup-image-gen $(date +%H:%M:%S)] $*"; }

# wait_for NAME URL [TIMEOUT_SECS] — poll URL until it responds, or fail hard.
wait_for() {
  local name="$1" url="$2" timeout="${3:-200}" waited=0
  log "waiting for ${name} (timeout ${timeout}s)..."
  until curl -fsS -o /dev/null --max-time 5 "$url" 2>/dev/null; do
    sleep 5; waited=$((waited + 5))
    if [ "$waited" -ge "$timeout" ]; then
      log "ERROR: ${name} not ready after ${timeout}s (${url})"; exit 1
    fi
  done
}

HA_CFG="${HA_CONFIG_DIR:-/home/jacob/Documents/homeassistant}"
CKPT="sd_xl_base_1.0.safetensors"
CKPT_URL="https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/${CKPT}"

# --- 1. gemma4:12b -----------------------------------------------------------
if docker exec ollama ollama list 2>/dev/null | grep -q '^gemma4:12b'; then
  log "gemma4:12b already present"
else
  log "pulling gemma4:12b (~7.6 GB)..."
  docker exec ollama ollama pull gemma4:12b
fi

# --- 2. ComfyUI + volume perms + SDXL checkpoint -----------------------------
log "starting comfyui..."
docker compose up -d comfyui || true   # first run creates the volume, may crash on perms
VOL=$(docker volume ls -q | grep -E 'comfyui-data$' | head -1)
if [ -n "$VOL" ]; then
  # Fresh named volumes are root-owned; the ComfyUI image wants 1000:1000.
  docker run --rm -v "$VOL":/mnt busybox sh -c \
    'test "$(stat -c %u /mnt)" = 1000 || { echo "chown volume -> 1000:1000"; chown -R 1000:1000 /mnt; }'
fi
docker compose up -d --force-recreate comfyui
wait_for "ComfyUI" "http://127.0.0.1:8188/system_stats" 240

if docker exec -u 1000 comfyui test -f "/comfy/mnt/ComfyUI/models/checkpoints/${CKPT}"; then
  log "SDXL checkpoint already present"
else
  log "downloading SDXL checkpoint (~6.9 GB)..."
  docker exec -u 1000 comfyui bash -lc \
    "cd /comfy/mnt/ComfyUI/models/checkpoints && curl -fL --retry 3 -o '${CKPT}' '${CKPT_URL}'"
fi

# --- 3. comfyui-mcp ----------------------------------------------------------
log "building + starting comfyui-mcp..."
docker compose up -d --build comfyui-mcp

# --- 4. Open WebUI wiring ----------------------------------------------------
log "wiring Open WebUI (comfyui-image tool + gemma4:12b model)..."
docker cp scripts/openwebui-image-gen.py open-webui:/tmp/openwebui-image-gen.py
docker exec open-webui python3 /tmp/openwebui-image-gen.py
# Filters (installed via the generic installer; both global + active):
#  - render_tool_images (outlet): injects the tool's absolute-URL image markdown
#    into the assistant message so generated images render in all clients (incl.
#    Conduit, which cannot resolve relative tool-call image URLs).
#  - ensure_model_tools (inlet): re-attaches the model's configured toolIds when
#    the client omits them, so tools keep working on follow-up turns (Conduit
#    only sends tool_ids on the first message of a chat).
docker cp scripts/openwebui-install-filter.py open-webui:/tmp/openwebui-install-filter.py
docker cp scripts/render_tool_images.py open-webui:/tmp/render_tool_images.py
docker exec open-webui python3 /tmp/openwebui-install-filter.py render_tool_images "Render Tool Images" /tmp/render_tool_images.py "Appends absolute-URL tool-call image markdown into the assistant message so generated images render in all clients (incl. Conduit)."
docker cp scripts/ensure_model_tools.py open-webui:/tmp/ensure_model_tools.py
docker exec open-webui python3 /tmp/openwebui-install-filter.py ensure_model_tools "Ensure Model Tools" /tmp/ensure_model_tools.py "Re-attaches a model configured tools when the client omits them (e.g. Conduit follow-up turns)."
docker restart open-webui >/dev/null

# --- 5. Home Assistant AI Task component + config (no root needed) -----------
log "installing vendored HA component + workflow..."
mkdir -p "$HA_CFG/custom_components"
cp -r homeassistant/custom_components/comfyui_generator "$HA_CFG/custom_components/"
cp comfyui-mcp/workflow_api.json "$HA_CFG/comfyui_workflow_api.json"
log "restarting HA to load the component..."
docker restart homeassistant >/dev/null
log "creating HA ComfyUI AI Task config entry (via config-flow API; waits for HA)..."
python3 scripts/ha-image-gen-config.py

log "done. Verify with: scripts/verify-services.sh"
