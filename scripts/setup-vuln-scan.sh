#!/usr/bin/env bash
# setup-vuln-scan.sh — nightly trivy scan of the LIVE k3s cluster. Idempotent.
#
#   sudo ./scripts/setup-vuln-scan.sh --check          # read-only: trivy, kubeconfig, baseline
#   sudo ./scripts/setup-vuln-scan.sh --run            # one scan now
#   sudo ./scripts/setup-vuln-scan.sh --install        # systemd unit + timer
#   sudo ./scripts/setup-vuln-scan.sh --seed-baseline  # scan, and accept today's counts
#
# ---------------------------------------------------------------------------
# WHY THIS RUNS HERE AND NOT IN GITHUB ACTIONS
# ---------------------------------------------------------------------------
# Step 2 of the security-scanning-ci plan (ai-home-server-k8s PR) gates PRs
# with `trivy config` against rendered manifests. That catches a bad CHANGE.
# It cannot catch a CVE disclosed today against an image that was merged last
# month -- git did not change, the risk did. That is what this covers, and it
# has to run against what is actually deployed, not the manifests:
#   - images are already pulled into containerd here (no pull cost, and a
#     GitHub-hosted runner cannot reach this cluster or its in-cluster
#     registry at localhost:5000 anyway)
#   - it scans what is ACTUALLY running, which after a manual `kubectl set
#     image` or a stuck rollout is not necessarily what the manifests say
#
# ---------------------------------------------------------------------------
# WHY ONLY THE IMAGE (CVE) BASELINE, NOT THE K8S REPO'S CONFIG BASELINE TOO
# ---------------------------------------------------------------------------
# security-scanning-ci.md's design table gives "Container image CVEs" a
# `delta vs baseline` gate, but "Live cluster posture" (misconfig/RBAC) only
# `report -> alert` -- no baseline column. That distinction is also what
# keeps this script self-contained: ai-home-server-k8s is a PRIVATE repo
# (confirmed via `gh api ... -q .private` 2026-08-31); the GitHub App keys
# that read it live only on the operator's laptop, not this server. Reading
# THIS repo's own local checkout (security/baseline/live-cluster.json) needs no
# network call and no second credential shipped to a second machine -- that
# would be a real decision, not something to make inside a cron script.
# Misconfig/RBAC findings are still scanned and printed to the unit log
# every run (systemd journal), satisfying "report"; the Grafana rules added
# alongside this cover "alert" for staleness and new image CVEs.
#
# ---------------------------------------------------------------------------
# NOTIFICATION, NOT JUST A SCAN
# ---------------------------------------------------------------------------
# This household has twice shipped a check that fired into a void (seven
# PrometheusRule alerts with no Alertmanager; a BackupJobFailing alert sitting
# in an unmerged PR while a backup silently failed for a day). So this writes
# node-exporter textfile metrics on every run, success or failure of the
# INNER scan step -- the failure path below still stamps a stale timestamp
# rather than silently leaving last-run's numbers looking current.
set -euo pipefail

STACK_DIR=/home/jacob/docker/ai-stack
KUBECONFIG_PATH=/home/jacob/.kube/config   # jacob's own copy, not the root-owned
                                             # /etc/rancher/k3s/k3s.yaml -- root can
                                             # read it fine (root bypasses the 0600
                                             # bit), and this matches what
                                             # verify-services.sh already uses.
export KUBECONFIG="$KUBECONFIG_PATH"

TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
TRIVY_VERSION=0.74.0    # matches the pin in ai-home-server-k8s's ci.yml
SCAN_DIR=/var/lib/vuln-scan
TRIVY_BIN=/usr/local/bin/trivy

log() { printf '[vuln-scan] %s\n' "$*"; }
die() { printf '[vuln-scan] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (writes the textfile collector, installs systemd units)"

do_check() {
  local fail=0
  command -v "$TRIVY_BIN" >/dev/null 2>&1 || { log "FAIL: trivy not installed at $TRIVY_BIN"; fail=1; }
  [[ -r "$KUBECONFIG_PATH" ]] || { log "FAIL: kubeconfig not readable at $KUBECONFIG_PATH"; fail=1; }
  if command -v "$TRIVY_BIN" >/dev/null 2>&1 && [[ -r "$KUBECONFIG_PATH" ]]; then
    if kubectl get --raw='/readyz' >/dev/null 2>&1; then
      log "OK:   cluster API reachable"
    else
      log "FAIL: cluster API not reachable via $KUBECONFIG_PATH"; fail=1
    fi
  fi
  # The LIVE-CLUSTER baseline, not the per-image ones -- see do_run(). Its
  # absence is a WARN, not a FAIL: the very first run legitimately has none,
  # and --seed-baseline is how you create it. But say plainly what that costs,
  # because an unseeded baseline reads every fixable CVE as alertable and
  # pages the phone the first night (observed 2026-09-02: 913 of them).
  if [[ -r "$STACK_DIR/security/baseline/live-cluster.json" ]]; then
    log "OK:   live-cluster baseline present"
  else
    log "WARN: no live-cluster baseline yet -- run --seed-baseline once, or the"
    log "      first nightly run reports every fixable CVE as new and alerts."
  fi
  [[ -d "$TEXTFILE_DIR" ]] && log "OK:   textfile collector dir exists" \
    || log "WARN: $TEXTFILE_DIR missing -- will be created by --install"
  return $fail
}

do_run() {
  command -v "$TRIVY_BIN" >/dev/null || die "trivy not installed -- run --install first"
  mkdir -p "$STACK_DIR/security/baseline"
  mkdir -p "$SCAN_DIR"; chmod 700 "$SCAN_DIR"

  log "scanning live image CVEs (trivy k8s --scanners vuln)..."
  # --disable-node-collector here too: see the posture scan below for why the
  # collector Job cannot run on this cluster. This scan tolerated its failure
  # (image CVEs come from containerd, not the collector) but still paid ~2min
  # waiting on a Job that admission was always going to deny.
  "$TRIVY_BIN" k8s --scanners vuln --severity HIGH,CRITICAL --timeout 15m \
    --disable-node-collector \
    -f json -o "$SCAN_DIR/vuln.json" \
    || { log "WARN: vuln scan failed -- metrics will NOT be updated this run"; return 1; }

  # --disable-node-collector: trivy's default posture scan schedules an
  # in-cluster node-collector Job that wants hostPID, and this cluster's
  # `deny-host-access` ValidatingAdmissionPolicy refuses it -- correctly:
  # hostPID exposes /proc/<pid>/environ for every host process, and this
  # cluster passes secrets as container env vars. Verified by the first real
  # run on 2026-09-02, which failed exactly there. Relaxing the policy to
  # please a scanner would be backwards, so the scanner gives up the part it
  # cannot have: node-level OS misconfig findings. Everything else in the
  # posture scan (workload misconfig + RBAC) still runs, and the node's own
  # OS packages are covered by unattended-upgrades plus the vuln scan above.
  log "scanning live cluster posture (trivy k8s --scanners misconfig,rbac)..."
  "$TRIVY_BIN" k8s --scanners misconfig,rbac --severity HIGH,CRITICAL --timeout 15m \
    --disable-node-collector \
    -f json -o "$SCAN_DIR/posture.json" \
    || { log "WARN: posture scan failed -- metrics will NOT be updated this run"; return 1; }

  mkdir -p "$TEXTFILE_DIR"; chmod 755 "$TEXTFILE_DIR"
  # --baseline is the LIVE-CLUSTER count baseline, not the per-image ones in
  # security/baseline/images/ -- those cover only the 2 self-built images CI
  # gates, while this scans every image actually running. See the docstring
  # in vuln-nightly-scan.py. Seed it once with --seed-baseline.
  python3 "$STACK_DIR/scripts/vuln-nightly-scan.py" \
    --vuln-scan "$SCAN_DIR/vuln.json" \
    --posture-scan "$SCAN_DIR/posture.json" \
    --baseline "$STACK_DIR/security/baseline/live-cluster.json" \
    ${SEED_BASELINE:+--update-baseline} \
    --out "$TEXTFILE_DIR/homeserver_vuln.prom"
  chmod 644 "$TEXTFILE_DIR/homeserver_vuln.prom"
  log "scan complete"
}

do_install() {
  if [[ ! -x "$TRIVY_BIN" ]]; then
    log "installing trivy $TRIVY_VERSION"
    curl -sSL "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
      | tar -xz -C /usr/local/bin trivy
  fi
  mkdir -p "$TEXTFILE_DIR" "$SCAN_DIR"
  chmod 755 "$TEXTFILE_DIR"; chmod 700 "$SCAN_DIR"

  cat > /etc/systemd/system/homeserver-vuln-scan.service <<UNIT
[Unit]
Description=Nightly trivy scan of the live k3s cluster (image CVEs + posture)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$STACK_DIR/scripts/setup-vuln-scan.sh --run
Nice=10
IOSchedulingClass=idle
UNIT

  # 02:00 -- clear of the local backup (03:30), offsite critical (05:00) and
  # offsite bulk (Sunday 06:00). A live cluster scan pulls no images (already
  # in containerd) but is still CPU-bound; this keeps it off the same window.
  cat > /etc/systemd/system/homeserver-vuln-scan.timer <<'UNIT'
[Unit]
Description=Schedule the nightly vuln scan

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now homeserver-vuln-scan.timer
  log "timer installed:"
  systemctl list-timers --no-pager homeserver-vuln-scan.timer | sed 's/^/  /'
}

case "${1:---check}" in
  --check)   do_check ;;
  --run)     do_run ;;
  --install) do_install ;;
  # Seeds security/baseline/live-cluster.json from what is running RIGHT NOW,
  # i.e. declares today's fixable-CVE count acceptable. Run once at setup, or
  # deliberately after accepting a rise. NOT part of --run: a nightly job that
  # re-baselines itself every night can never alert on anything.
  --seed-baseline) SEED_BASELINE=1 do_run ;;
  *) die "unknown mode '$1' (use --check, --run, --install, --seed-baseline)" ;;
esac
