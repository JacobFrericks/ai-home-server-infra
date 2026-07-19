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
#    --ignore-buildable skips comfyui-mcp (built locally, no registry image);
#    --build (re)builds it so `up -d` always has a current comfyui-mcp image.
log "docker compose pull --ignore-buildable"
docker compose pull --ignore-buildable
log "docker compose up -d --build"
docker compose up -d --build

# 2b. Bring up the separate monitoring stack (Prometheus/Loki/Grafana), if its
#     server-only secrets are in place. It's a distinct compose project so it
#     can be recreated independently of the app stack above.
if [ -f monitoring/.env ] && [ -f monitoring/prometheus/ha_token ]; then
  log "docker compose -p monitoring pull"
  docker compose -p monitoring -f monitoring/docker-compose.yml pull
  log "docker compose -p monitoring up -d"
  docker compose -p monitoring -f monitoring/docker-compose.yml up -d
else
  log "monitoring/.env or monitoring/prometheus/ha_token missing — skipping monitoring stack (see monitoring/README.md)"
fi

# 3. Health check: Open WebUI, Ollama, Home Assistant, and (once cut over) Plex.
log "health check"
ok=1
curl -fsS -o /dev/null "http://127.0.0.1:8080/health" \
  || curl -fsS -o /dev/null "http://127.0.0.1:8080/" \
  || ok=0
docker compose exec -T ollama ollama list >/dev/null 2>&1 || ok=0
curl -fsS -o /dev/null "http://127.0.0.1:8123/" || ok=0
# Plex check is best-effort: the plex service stays undeployed until the
# manual cutover runbook (README.md) has been run, so don't fail deploys
# over it — just warn.
curl -fsS -o /dev/null "http://127.0.0.1:32400/identity" \
  || log "warning: Plex :32400 not responding (expected until cutover runbook is run)"
# ComfyUI check is best-effort: image gen is optional and its own thing; don't
# fail deploys over it — just warn (e.g. if the SDXL checkpoint isn't in place).
curl -fsS -o /dev/null "http://127.0.0.1:8188/system_stats" \
  || log "warning: ComfyUI :8188 not responding (image generation; see README)"
# Grafana check is best-effort too: the monitoring stack only comes up once
# its server-only secrets exist (see step 2b above).
curl -fsS -o /dev/null "http://127.0.0.1:3000/api/health" \
  || log "warning: Grafana :3000 not responding (monitoring stack may not be deployed yet)"

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
