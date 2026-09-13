#!/usr/bin/env bash
# build-mcp-images.sh — rebuild the two self-built MCP images when, and only
# when, their source has actually moved on main. Idempotent.
#
#   ./scripts/build-mcp-images.sh --check     # read-only: what would it do
#   ./scripts/build-mcp-images.sh --run       # build + push anything stale
#   sudo ./scripts/build-mcp-images.sh --install   # systemd unit + timer
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# comfyui-mcp and memory-mcp are built from THIS repo but deployed from
# ai-home-server-k8s, by DIGEST. So merging a change here changes nothing that
# runs: the cluster keeps the old digest until someone rebuilds, pushes, and
# bumps the digest over there. That gap is not theoretical -- it is exactly what
# happened to the mcp 1.29.1 -> 2.1.1 bump (#71), which sat merged while both
# pods kept running 1.29.1.
#
# ---------------------------------------------------------------------------
# WHY IT RUNS ON THIS HOST AND NOT IN GITHUB ACTIONS OR IN THE CLUSTER
# ---------------------------------------------------------------------------
# GitHub: a GitHub-hosted runner cannot reach the in-cluster registry, by
# design. It can build these images (image-scan.yml does, to scan them) but it
# can never push one here.
#
# In-cluster: building an image inside k3s means BuildKit in a pod with
# seccomp unconfined, plus a registry push credential sealed into the cluster.
# Every other namespace here is `restricted`. That trades a real privilege
# increase for tidiness. This host already has the docker group, the registry
# credential and a checkout -- the job needs no new privilege at all.
#
# ---------------------------------------------------------------------------
# WHY IT DOES NOT OPEN THE PULL REQUEST
# ---------------------------------------------------------------------------
# It would need a GitHub App key with write access, on this box. The since-
# removed setup-vuln-scan.sh looked at that same question and wrote down the
# answer: the App keys live on the operator's laptop, not this server, and
# shipping a second write credential to a second machine "would be a real
# decision, not something to make inside a cron script". Nothing has changed,
# so this script stops at "pushed, and here are the digests" and pushes a
# notification. A human bumps the two digests and opens the PR.
#
# The pinning is the point. An automated build that ALSO moved what runs would
# defeat the reason the manifests carry digests: what runs changes only through
# a reviewed commit.
#
# ---------------------------------------------------------------------------
# "ONLY ON MERGE", FROM A TIMER
# ---------------------------------------------------------------------------
# A timer polls; merges do not call us. So the trigger is derived rather than
# received: an image's tag is the short SHA of the LAST COMMIT ON MAIN THAT
# TOUCHED ITS DIRECTORY. If that tag is already in the registry there is
# nothing to do, and the run exits having built nothing. A merge that does not
# touch these two directories moves no tag and causes no build.
#
# The common path is therefore one `git fetch` and a state-file comparison --
# cheap enough to run every 15 minutes, which is what makes it feel like a
# merge trigger instead of a nightly batch.
set -euo pipefail

STACK_DIR=${STACK_DIR:-/home/jacob/docker/ai-stack}
STATE_DIR=${STATE_DIR:-/var/lib/mcp-image-builder}
STATE_FILE="$STATE_DIR/last-built"
REGISTRY=localhost:5000
REGISTRY_NS=registry               # k8s namespace holding the registry Service
IMAGES=(comfyui-mcp memory-mcp)
UNIT=homeserver-mcp-image-builder

# jacob's own copy, not the root-owned /etc/rancher/k3s/k3s.yaml -- matches what
# verify-services.sh already uses.
export KUBECONFIG=${KUBECONFIG:-/home/jacob/.kube/config}

log() { printf '[mcp-build] %s\n' "$*"; }
die() { printf '[mcp-build] ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# NOTIFICATION
# ---------------------------------------------------------------------------
# Same resolution deploy.sh uses, and for the same reason: the ntfy topic is the
# only access control on that channel, this repo is PUBLIC, and rebuilding the
# Pi regenerates the topic. So it is looked up at run time from the Grafana
# contact point rather than written down here. One place to change, no secret
# in git.
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
      -H "Title: $1" -H "Priority: ${NOTIFY_PRIORITY:-default}" -H "Tags: package" \
      -d "$2" "$url"; then
    log "notify: sent"
  else
    log "notify: ntfy POST failed -- NOT delivered"
  fi
  return 0
}

on_err() {
  local rc=$? line=${1:-?}
  log "FAILED - exit $rc at line $line"
  NOTIFY_PRIORITY=high notify "MCP image build FAILED" \
    "build-mcp-images.sh exited $rc at line $line on $(hostname). The cluster is UNAFFECTED -- it keeps running the digests already pinned in ai-home-server-k8s. Log: journalctl -u ${UNIT}.service"
}

# ---------------------------------------------------------------------------
# REGISTRY ACCESS
# ---------------------------------------------------------------------------
# ⚠️ `docker push localhost:5000/...` does NOT work from this host any more.
# The registry Deployment lost its hostPort on 2026-08-31 (Cilium's eBPF
# implementation was publishing it to the LAN), so nothing listens on host port
# 5000 and the push dies with "connect: connection refused". The Service is
# ClusterIP-only now.
#
# So we port-forward it back to 127.0.0.1:5000 for the duration of the run.
# Forwarding to the SAME name matters: the stored docker credential is keyed on
# "localhost:5000", and pushing to the ClusterIP instead would miss it and need
# a second copy of the password.
PF_PID=""
stop_pf() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true; PF_PID=""; }
start_pf() {
  [ -n "$PF_PID" ] && return 0
  kubectl port-forward -n "$REGISTRY_NS" svc/registry 5000:5000 >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 40); do
    curl -s -o /dev/null -m 2 "http://127.0.0.1:5000/v2/" && return 0
    sleep 0.5
  done
  die "registry did not answer on 127.0.0.1:5000 after port-forward"
}

# The stored credential is read straight out of the docker config and used as a
# header. It is never printed, never placed in argv, and lives only in this
# variable for the life of the process.
reg_auth() {
  python3 -c 'import json,sys
try:
    print(json.load(open("/home/jacob/.docker/config.json"))["auths"]["localhost:5000"]["auth"])
except Exception:
    sys.exit("no stored credential for localhost:5000 -- run: docker login localhost:5000")'
}

# These are OCI image indexes. Asking only for the docker v2 manifest type
# returns 404 for a tag that is present -- a lie that has cost time before
# (ai-home-server-k8s#18), so ask for the index types too.
REG_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

tag_exists() { # $1 = repo, $2 = tag  -> 0 if present
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 \
          -H "Authorization: Basic $AUTH" -H "Accept: $REG_ACCEPT" \
          "http://127.0.0.1:5000/v2/$1/manifests/$2")
  [ "$code" = "200" ]
}

# ---------------------------------------------------------------------------
# WHAT SHOULD BE BUILT
# ---------------------------------------------------------------------------
# Tag per image, not one tag for the repo: an image's identity is its own
# source. A merge that only touches memory-mcp/ must not invalidate the
# comfyui-mcp build, or every unrelated commit rebuilds both and the "only on
# merge" property degrades into "on every commit".
#
# Read from origin/main, never from the working tree. deploy.sh moves this
# checkout on its own schedule and a human may have left it anywhere; building
# whatever happens to be checked out is how you ship a half-finished branch.
wanted_tags() {
  local img
  for img in "${IMAGES[@]}"; do
    printf '%s %s\n' "$img" "$(git -C "$STACK_DIR" log -1 --format=%h origin/main -- "$img")"
  done
}

do_fetch() {
  [ -d "$STACK_DIR/.git" ] || die "$STACK_DIR is not a git checkout"
  git -C "$STACK_DIR" fetch --quiet origin main
}

do_check() {
  do_fetch
  local img tag line
  log "origin/main is $(git -C "$STACK_DIR" rev-parse --short origin/main)"
  AUTH=$(reg_auth)
  start_pf
  while read -r img tag; do
    if tag_exists "$img" "$tag"; then
      log "  $img: tag $tag already pushed -- nothing to do"
    else
      log "  $img: tag $tag NOT in registry -- would build and push"
    fi
  done < <(wanted_tags)
  stop_pf
}

do_run() {
  do_fetch

  # Fast path. The registry is the source of truth, but consulting it costs a
  # port-forward; the state file makes the common "nothing changed" run cost
  # one fetch and one string compare. A missing or stale state file only makes
  # the run slower, never wrong -- the registry is still checked below.
  local want
  want=$(wanted_tags)
  if [ -f "$STATE_FILE" ] && [ "$want" = "$(cat "$STATE_FILE")" ]; then
    log "no MCP source change on origin/main since last run -- nothing to do"
    return 0
  fi

  AUTH=$(reg_auth)
  start_pf

  local img tag work built=() report=""
  while read -r img tag; do
    if tag_exists "$img" "$tag"; then
      log "$img: $tag already pushed -- skipping"
      continue
    fi
    log "$img: building $tag"

    # `git archive` instead of a checkout or a worktree: it materialises exactly
    # one directory at exactly one commit, touches nothing in $STACK_DIR, and
    # leaves no state behind if this run dies. deploy.sh shares that checkout.
    work=$(mktemp -d)
    git -C "$STACK_DIR" archive origin/main "$img" | tar -x -C "$work"
    docker build -t "$REGISTRY/$img:$tag" "$work/$img"
    rm -rf "$work"

    # The digest that matters is the one the REGISTRY assigns, not the local
    # image id. It is what goes in the manifest, so read it back from the push.
    local digest
    digest=$(docker push "$REGISTRY/$img:$tag" | sed -n 's/.*digest: \(sha256:[0-9a-f]*\).*/\1/p')
    [ -n "$digest" ] || die "$img: push produced no digest"
    tag_exists "$img" "$digest" || die "$img: pushed digest $digest does not resolve in the registry"

    log "$img: pushed $tag -> $digest"
    built+=("$img")
    report="${report}${img}  ${digest}"$'\n'
  done < <(wanted_tags)

  stop_pf

  mkdir -p "$STATE_DIR"
  printf '%s\n' "$want" > "$STATE_FILE"

  if [ ${#built[@]} -eq 0 ]; then
    log "everything already pushed -- nothing to do"
    return 0
  fi

  printf '%s' "$report" > "$STATE_DIR/last-digests"
  log "built: ${built[*]}"
  log "$report"

  # This is the whole point of the run: the cluster does NOT move until a human
  # bumps these. A build nobody hears about is the gap this script exists to
  # close, so say it out loud rather than leaving it in a journal nobody reads.
  notify "MCP images rebuilt — digest bump needed" \
"$(printf 'Built from ai-home-server-infra origin/main and pushed to the in-cluster registry.\n\n%s\nThe cluster still runs the OLD digests. Bump them in ai-home-server-k8s and open a PR:\n  workloads/gpu-tier/comfyui-mcp.yaml\n  workloads/web-tier/memory-mcp.yaml' "$report")"
}

do_install() {
  [[ $EUID -eq 0 ]] || die "--install must run as root (writes systemd units)"
  local self; self=$(readlink -f "$0")

  install -d -o jacob -g jacob -m 0755 "$STATE_DIR"

  # Runs as jacob, NOT root. Both credentials this needs are jacob's: the
  # docker group membership that reaches the daemon, and ~/.docker/config.json
  # for the registry. Running as root would find neither and fail on auth.
  cat > "/etc/systemd/system/${UNIT}.service" <<UNITEOF
[Unit]
Description=Rebuild the self-built MCP images when their source moves on main
Documentation=https://github.com/JacobFrericks/ai-home-server-infra
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=jacob
Group=jacob
ExecStart=${self} --run
# A build is minutes at worst; anything longer is stuck, and a stuck run holds
# the port-forward open.
TimeoutStartSec=1800
Nice=10
IOSchedulingClass=idle
UNITEOF

  # Every 15 minutes, not nightly. The no-op path is one git fetch, so a short
  # interval is what makes this behave like a merge trigger rather than a batch
  # job -- without needing an inbound webhook or a credential to receive one.
  # Persistent=true so a run missed while the box was off happens at boot.
  cat > "/etc/systemd/system/${UNIT}.timer" <<'TIMEREOF'
[Unit]
Description=Check main for MCP source changes every 15 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=15min
RandomizedDelaySec=2min
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

  systemctl daemon-reload
  systemctl enable --now "${UNIT}.timer"
  log "installed and enabled ${UNIT}.timer"
  systemctl list-timers --no-pager "${UNIT}.timer" || true
}

case "${1:-}" in
  --check)   do_check ;;
  --run)     trap 'on_err $LINENO' ERR; trap stop_pf EXIT; do_run ;;
  --install) do_install ;;
  *) die "usage: $0 --check | --run | --install" ;;
esac
