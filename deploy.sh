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
#    Skipped automatically until a remote is configured (GitHub auth pending),
#    so for now the stack is applied from the local files already on disk.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
   && git remote get-url origin >/dev/null 2>&1; then
  log "git pull --ff-only"
  git pull --ff-only
else
  log "no git remote configured yet — skipping git pull, using local files"
fi

# 2. Pull the pinned images and apply. Only changed services are recreated.
log "docker compose pull"
docker compose pull
log "docker compose up -d"
docker compose up -d

# 3. Health check: Open WebUI answers and Ollama responds.
log "health check"
ok=1
curl -fsS -o /dev/null "http://127.0.0.1:8080/health" \
  || curl -fsS -o /dev/null "http://127.0.0.1:8080/" \
  || ok=0
docker compose exec -T ollama ollama list >/dev/null 2>&1 || ok=0

if [ "$ok" -ne 1 ]; then
  log "HEALTH CHECK FAILED — inspect: docker compose ps / docker compose logs"
  log "rollback: git reset --hard <previous-sha> && ./deploy.sh"
  exit 1
fi
log "health check passed"

# 4. Reclaim disk from superseded images.
log "docker image prune -f"
docker image prune -f

log "deploy complete"
