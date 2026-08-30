#!/usr/bin/env bash
#
# deploy.sh — pull the latest infra + container images and (re)apply the stack.
#
# Runs on the home server, unattended, from a weekly cron entry. jacob is in the
# `docker` group, so no sudo is required. The real WEBUI_SECRET_KEY lives in the
# adjacent .env (git-ignored) and is picked up automatically by docker compose.
#
# -E so the ERR trap below is inherited by functions and subshells; without it a
# failure inside one dies silently, which is the whole bug this trap exists for.
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$0")")"

log() { echo "[deploy $(date -Is)] $*"; }

# Under cron there is no KUBECONFIG, and the ntfy lookup below needs one.
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

# ---------------------------------------------------------------------------
# FAILURE NOTIFICATION
# ---------------------------------------------------------------------------
# This script runs from cron and appends to deploy.log. Nothing reads that file.
# It died every week from 2026-08-16 to 2026-08-30 -- first on a deleted
# monitoring compose file, then on `git pull` with no tracking branch -- and the
# only reason it was ever noticed was someone deploying by hand and seeing the
# containers were behind main. A log with no reader is not monitoring.
#
# The ntfy topic is NOT hardcoded here. It is the only access control on that
# channel, this repo is public, and rebuilding the Pi regenerates the topic. So
# it is resolved at run time from the SAME source of truth verify-services.sh
# uses: the Grafana contact point. One place to change, no secret in git.
notify() { # $1 = title, $2 = body   -- best-effort, never fails the caller
  local pw ep url
  pw=$(kubectl -n monitoring get secret grafana-admin \
        -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\r\n') || true
  [ -n "${pw:-}" ] || { log "notify: no grafana credential -- alert NOT sent"; return 0; }
  ep=$(kubectl -n monitoring get svc kube-prometheus-stack-grafana \
        -o jsonpath='{.spec.clusterIP}' 2>/dev/null) || true
  [ -n "${ep:-}" ] || { log "notify: no grafana endpoint -- alert NOT sent"; return 0; }
  url=$(curl -s --max-time 15 -u "admin:$pw" \
        "http://${ep}:3000/api/v1/provisioning/contact-points" 2>/dev/null | python3 -c '
import sys, json
try: cps = json.load(sys.stdin)
except Exception: raise SystemExit
for c in cps:
    if c.get("name") == "ntfy-critical":
        print(c.get("settings", {}).get("url", "")); break' 2>/dev/null) || true
  [ -n "${url:-}" ] || { log "notify: no ntfy-critical url -- alert NOT sent"; return 0; }
  if curl -s -o /dev/null --max-time 10 \
      -H "Title: $1" -H "Priority: high" -H "Tags: rotating_light" \
      -d "$2" "$url"; then
    log "notify: alert sent"
  else
    log "notify: ntfy POST failed -- alert NOT delivered"
  fi
  return 0
}

# Fires on ANY unexpected non-zero command, which is exactly how the two real
# outages died -- both before the health check was ever reached.
on_err() {
  local rc=$? line=${1:-?}
  log "DEPLOY FAILED - exit $rc at line $line"
  notify "Home server deploy FAILED" \
    "deploy.sh exited $rc at line $line on $(hostname). Stack may be behind main. Log: $(pwd)/deploy.log"
}
trap 'on_err $LINENO' ERR

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
  # Notified explicitly: `exit` does not fire the ERR trap.
  notify "Home server deploy: HEALTH CHECK FAILED" \
    "Deploy applied but a service did not come back on $(hostname). See $(pwd)/deploy.log, then ./scripts/verify-services.sh"
  trap - ERR
  exit 1
fi
log "health check passed"

# 4. Reclaim disk from superseded images.
log "docker image prune -f"
docker image prune -f

log "deploy complete"
