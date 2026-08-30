#!/usr/bin/env bash
#
# deploy.sh — pull the latest infra + container images and (re)apply the stack.
#
# Runs on the home server, unattended, from a weekly cron entry. jacob is in the
# `docker` group, so no sudo is required. The real WEBUI_SECRET_KEY lives in the
# adjacent .env (git-ignored) and is picked up automatically by docker compose.
#
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

log() { echo "[deploy $(date -Is)] $*"; }

# 1. Pull the latest infra from git.
#    Always pull origin/main explicitly. A bare `git pull --ff-only` takes its
#    branch from whatever is checked out, so a stray feature-branch checkout
#    made every subsequent deploy die on "no tracking information" while the
#    stack quietly drifted from main. Naming the branch removes that failure.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
   && git remote get-url origin >/dev/null 2>&1; then
  log "git pull --ff-only origin main"
  git pull --ff-only origin main
else
  log "no git remote configured yet — skipping git pull, using local files"
fi

# 2. Pull the pinned images and apply. Only changed services are recreated.
#    --ignore-buildable skips comfyui-mcp (built locally, no registry image);
#    --build (re)builds it so `up -d` always has a current comfyui-mcp image.
log "docker compose pull --ignore-buildable"
docker compose pull --ignore-buildable
log "docker compose up -d --build"
docker compose up -d --build

# 3. Health check: exactly the services this script deploys, and nothing else.
#    Everything below used to be checked here and no longer belongs: Open WebUI
#    (:8080), Ollama (via `compose exec`), ComfyUI (:8188) and Grafana (:3000)
#    all moved into k3s during the migration. They are not compose services and
#    are not on those host ports, so those checks failed unconditionally --
#    two of them setting ok=0, which made a successful deploy report
#    HEALTH CHECK FAILED. The cluster is covered by scripts/verify-services.sh.
log "health check"
ok=1
curl -fsS -o /dev/null "http://127.0.0.1:8123/" || { log "FAIL: Home Assistant :8123"; ok=0; }
curl -fsS -o /dev/null "http://127.0.0.1:32400/identity" || { log "FAIL: Plex :32400"; ok=0; }
for svc in piper whisper; do
  [ "$(docker compose ps -q "$svc" | wc -l)" -eq 1 ] \
    && [ "$(docker inspect -f '{{.State.Running}}' "$(docker compose ps -q "$svc")")" = "true" ] \
    || { log "FAIL: compose service $svc is not running"; ok=0; }
done

if [ "$ok" -ne 1 ]; then
  log "HEALTH CHECK FAILED — inspect: docker compose ps / docker compose logs"
  log "full picture (cluster included): ./scripts/verify-services.sh"
  log "rollback: git reset --hard <previous-sha> && ./deploy.sh"
  exit 1
fi
log "health check passed"

# 4. Reclaim disk from superseded images.
log "docker image prune -f"
docker image prune -f

log "deploy complete"
