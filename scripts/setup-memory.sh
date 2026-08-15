#!/usr/bin/env bash
#
# setup-memory.sh — provision the persistent-memory feature end to end.
#
# Idempotent: every step is a no-op if already done, so this is the "start over"
# button. Run it AFTER deploy.sh has brought the stack up. It:
#   1. creates the server-only memory-data/ dir (git-ignored; holds the markdown
#      memory files, one fact per file + a MEMORY.md index)
#   2. builds + starts memory-mcp (loopback 127.0.0.1:9400)
#   3. wires Open WebUI: registers the `memory` MCP tool on assistant and
#      installs the memory_recall inlet filter (auto-recall into the prompt)
#
# Requires: docker (jacob is in the docker group). No sudo needed.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

log() { echo "[setup-memory $(date +%H:%M:%S)] $*"; }

# --- 1. memory-data dir ------------------------------------------------------
# Owned by the invoking user (uid 1000 / jacob); memory-mcp runs as 1000:1000 so
# the files it writes stay hand-editable, and open-webui bind-mounts it read-only.
log "ensuring memory-data/ exists..."
mkdir -p memory-data

# --- 2. memory-mcp -----------------------------------------------------------
log "building + starting memory-mcp..."
docker compose up -d --build memory-mcp
# open-webui gets the read-only mount only once the compose file adds it; make
# sure it is running with the current definition.
docker compose up -d open-webui

# --- 3. Open WebUI wiring ----------------------------------------------------
# Prompt text is server-only (git-ignored prompts/ dir; this repo is public).
# Fail early and clearly rather than installing a prompt-less assistant.
for p in prompts/memory-system.txt prompts/memory-recall-header.txt; do
  [ -s "$p" ] || { echo "FATAL: missing $p -- see prompts/README.md" >&2; exit 1; }
done

log "wiring Open WebUI (memory tool on assistant + recall filter)..."
# The `assistant` model row must exist before we wire tools onto it. Idempotent,
# so it is safe here even though the other setup script does the same.
docker cp scripts/openwebui-assistant-model.py open-webui:/tmp/openwebui-assistant-model.py >/dev/null
docker exec open-webui python3 /tmp/openwebui-assistant-model.py
docker cp prompts/memory-system.txt open-webui:/tmp/memory-system.txt
docker cp scripts/openwebui-memory.py open-webui:/tmp/openwebui-memory.py
docker exec open-webui python3 /tmp/openwebui-memory.py
docker cp scripts/openwebui-install-filter.py open-webui:/tmp/openwebui-install-filter.py
docker cp scripts/memory_recall.py open-webui:/tmp/memory_recall.py
docker cp prompts/memory-recall-header.txt open-webui:/tmp/memory-recall-header.txt
docker exec open-webui python3 /tmp/openwebui-install-filter.py memory_recall "Memory Recall" /tmp/memory_recall.py "Injects the AI's persistent memories into the system prompt at the start of each turn (read half of the memory loop; memory-mcp is the write half)." --models assistant --prompt-file RECALL_HEADER=/tmp/memory-recall-header.txt
docker restart open-webui >/dev/null

log "done. Verify with: scripts/verify-services.sh"
