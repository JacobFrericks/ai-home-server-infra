#!/usr/bin/env bash
#
# setup-memory.sh — provision the persistent-memory feature end to end.
#
# Idempotent: every step is a no-op if already done, so this is the "start over"
# button. It:
#   1. ensures the server-only memory-data/ dir exists (git-ignored; holds the
#      markdown memory files, one fact per file + a MEMORY.md index)
#   2. checks memory-mcp is actually running the digest the manifests pin
#   3. wires Open WebUI: registers the `memory` MCP tool on assistant and
#      installs the memory_recall inlet filter (the read half, and the half that
#      enforces per-person privacy)
#
# ---------------------------------------------------------------------------
# THIS SCRIPT TARGETS k3s, NOT COMPOSE
# ---------------------------------------------------------------------------
# It used to run `docker compose up -d --build memory-mcp` and `docker cp` into
# an `open-webui` container. Both moved into k3s during the Stage 5/6 cutover
# and the script was never updated, so it died at "no such service: memory-mcp"
# the next time anyone needed it -- which was the deploy of the per-person
# memory change, i.e. exactly when it mattered. Workloads live in
# ai-home-server-k8s now; this script configures them, it does not create them.
#
# Building and rolling the IMAGE is deliberately not done here: that is
# scripts/build-mcp-images.sh plus a reviewed digest bump in the k8s repo. What
# this script owns is the Open WebUI database wiring, which is not in git and
# has no other home.
#
# Requires: a kubeconfig jacob can read (no sudo — see the KUBECONFIG note in
# setup-assist-location.sh for why sudo is wrong in scripts that cron runs).
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

log() { echo "[setup-memory $(date +%H:%M:%S)] $*"; }
die() { echo "[setup-memory] ERROR: $*" >&2; exit 1; }

export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
NS=ai-stack

kubectl version --client >/dev/null 2>&1 || die "kubectl not usable"

# --- 1. memory-data dir ------------------------------------------------------
# Still created here for the Compose-era bind mount and for hand-editing; under
# k3s the live copy is the memory-data PVC, which memory-mcp owns.
log "ensuring memory-data/ exists..."
mkdir -p memory-data

# --- 2. memory-mcp -----------------------------------------------------------
log "checking memory-mcp..."
kubectl -n "$NS" rollout status deploy/memory-mcp --timeout=120s >/dev/null \
  || die "memory-mcp is not rolled out; check the k8s repo digest"
RUNNING=$(kubectl -n "$NS" get pod -l app=memory-mcp \
  -o jsonpath='{.items[0].status.containerStatuses[0].imageID}')
log "memory-mcp running ${RUNNING##*@}"

# A merged source change does nothing until the image is rebuilt AND the digest
# bumped in the k8s repo. Say so loudly rather than "wiring" a stale image and
# reporting success -- that gap has bitten this repo twice.
WANT=$(kubectl -n "$NS" get deploy memory-mcp \
  -o jsonpath='{.spec.template.spec.containers[0].image}')
case "$RUNNING" in
  *"${WANT##*@}") : ;;
  *) die "running digest != manifest digest; run scripts/build-mcp-images.sh --check" ;;
esac

# --- 3. Open WebUI wiring ----------------------------------------------------
# Prompt text is server-only (git-ignored prompts/ dir; this repo is public).
# Fail early and clearly rather than installing a prompt-less assistant.
for p in prompts/memory-system.txt prompts/memory-recall-header.txt; do
  [ -s "$p" ] || die "missing $p -- see prompts/README.md"
done

POD=$(kubectl -n "$NS" get pod -l app=open-webui \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || die "no open-webui pod"

log "wiring Open WebUI (memory tool on assistant + recall filter) in $POD..."

push() { kubectl -n "$NS" cp "$1" "$POD:$2"; }
run()  { kubectl -n "$NS" exec "$POD" -- python3 "$@"; }

# The `assistant` model row must exist before we wire tools onto it. Idempotent,
# so it is safe here even though the other setup script does the same.
push scripts/openwebui-assistant-model.py /tmp/openwebui-assistant-model.py
run /tmp/openwebui-assistant-model.py

push prompts/memory-system.txt /tmp/memory-system.txt
push scripts/openwebui-memory.py /tmp/openwebui-memory.py
run /tmp/openwebui-memory.py

push scripts/openwebui-install-filter.py /tmp/openwebui-install-filter.py
push scripts/memory_recall.py /tmp/memory_recall.py
push prompts/memory-recall-header.txt /tmp/memory-recall-header.txt
run /tmp/openwebui-install-filter.py memory_recall "Memory Recall" \
  /tmp/memory_recall.py \
  "Injects the AI's persistent memories into the system prompt at the start of each turn (read half of the memory loop; memory-mcp is the write half)." \
  --models assistant --prompt-file RECALL_HEADER=/tmp/memory-recall-header.txt

# Open WebUI loads filter code at startup, so the DB row alone changes nothing.
log "restarting open-webui to load the filter..."
kubectl -n "$NS" rollout restart deploy/open-webui >/dev/null
kubectl -n "$NS" rollout status deploy/open-webui --timeout=180s >/dev/null

log "done. Verify with: scripts/verify-services.sh"
