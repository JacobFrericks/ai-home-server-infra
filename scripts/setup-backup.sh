#!/usr/bin/env bash
# setup-backup.sh — idempotent restic backup for the home server. Safe to re-run.
#
# Run as root: it reads root-owned Home Assistant .storage, the k3s PVC tree
# (/var/lib/rancher/k3s/storage is 0700 root), and installs a systemd timer.
#
#   sudo ./scripts/setup-backup.sh --install        # deps, unit, timer
#   sudo ./scripts/setup-backup.sh --run            # one backup now
#   sudo ./scripts/setup-backup.sh --dry-run        # show what WOULD be backed up
#
# ---------------------------------------------------------------------------
# WHAT THE k3s MIGRATION CHANGED ABOUT BACKUPS
# ---------------------------------------------------------------------------
# The original plan (2026-07-24) predates the cluster and its include-list is
# now wrong in three ways:
#
#  1. webui.db and memory-data are no longer Docker volumes. They live in k3s
#     PVCs under /var/lib/rancher/k3s/storage/<pv-uuid>_<ns>_<claim>/ — and the
#     UUID CHANGES if a PVC is ever recreated, so paths are resolved with
#     kubectl at run time and never hardcoded.
#
#  2. 🔴 THE SEALED-SECRETS MASTER KEY IS NOW THE MOST CRITICAL ITEM ON THE
#     LIST, ahead of any application data. Every Secret in the GitOps repo is
#     a SealedSecret, encrypted to that key. Lose it and the manifests in git
#     are undecryptable ciphertext: a rebuilt cluster comes up with workloads
#     that can NEVER start, and no amount of application-data backup helps.
#     It is a private key, so it is backed up ENCRYPTED by restic and must
#     never be committed.
#
#  3. etcd snapshots hold cluster STATE but not PVC CONTENTS. The two are
#     complementary; neither substitutes for the other. k3s already writes
#     snapshots on a cron (retention 10) — this job captures them so they
#     survive the disk they are written to.
#
# ---------------------------------------------------------------------------
# STATUS: TIER 1 TARGET NOT YET CHOSEN (2026-08-15)
# ---------------------------------------------------------------------------
# The user will attach a dedicated backup drive later; the internal disks
# (sda/sdb/sdc) hold existing data and are deliberately NOT touched. Offsite
# (S3 Glacier IR) is deferred. Until RESTIC_REPOSITORY is set in .env this
# script installs cleanly and the timer refuses to run rather than pretending
# to back anything up.
#
# ⚠️ THIS MEANS THERE IS CURRENTLY NO BACKUP. That is a known, accepted state,
# not an oversight — see the plan. Everything else is ready so that attaching a
# drive is a two-line change: set RESTIC_REPOSITORY + RESTIC_PASSWORD, re-run.
set -euo pipefail

STACK_DIR=/home/jacob/docker/ai-stack
ENV_FILE="$STACK_DIR/.env"
STAGE=/var/lib/backup-staging          # consistent copies land here first
KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG="$KUBECONFIG_PATH"

log() { printf '[backup] %s\n' "$*"; }
die() { printf '[backup] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (root-owned HA .storage, k3s PVC tree, systemd)"

# --- repo config, read from the git-ignored .env ----------------------------
# RESTIC_PASSWORD is the ENCRYPTION KEY. Lose it and every backup is
# unrecoverable, so it must also live OFF this box (password manager / printed).
# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

have_repo() { [[ -n "${RESTIC_REPOSITORY:-}" && -n "${RESTIC_PASSWORD:-}" ]]; }

# --- resolve the k3s PVC host paths by CLAIM, never by UUID -----------------
pvc_path() {  # $1=namespace $2=claim
  kubectl get pv -o json 2>/dev/null | python3 -c '
import json,sys
ns,claim=sys.argv[1],sys.argv[2]
for p in json.load(sys.stdin)["items"]:
    c=p["spec"].get("claimRef") or {}
    if c.get("namespace")==ns and c.get("name")==claim:
        src=p["spec"].get("hostPath") or p["spec"].get("local") or {}
        print(src.get("path","")); break
' "$1" "$2"
}

# --- consistent snapshots of anything SQLite --------------------------------
stage_sqlite() {
  rm -rf "$STAGE"; mkdir -p "$STAGE"; chmod 700 "$STAGE"

  # webui.db is in WAL mode: a plain cp can miss the log and capture a TORN
  # database. VACUUM INTO produces a consistent single-file copy. This is the
  # same rule that governs every backup of this file.
  local owui; owui="$(pvc_path ai-stack open-webui-data)"
  if [[ -n "$owui" && -f "$owui/webui.db" ]]; then
    sqlite3 "$owui/webui.db" "VACUUM INTO '$STAGE/webui.db'" \
      && log "staged webui.db ($(du -h "$STAGE/webui.db" | cut -f1)) via VACUUM INTO"
    sqlite3 "$STAGE/webui.db" "PRAGMA integrity_check;" | head -1 | grep -qx ok \
      || die "staged webui.db failed integrity_check — refusing to back up a torn DB"
  else
    log "WARN: open-webui PVC not found; webui.db NOT staged"
  fi

  # The sealed-secrets private key. Without it every SealedSecret in git is
  # dead ciphertext. Exported as yaml; restic encrypts it at rest.
  if kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
       > "$STAGE/sealed-secrets-key.yaml" 2>/dev/null; then
    chmod 600 "$STAGE/sealed-secrets-key.yaml"
    log "staged sealed-secrets master key ($(grep -c 'name:' "$STAGE/sealed-secrets-key.yaml") entries)"
  else
    log "WARN: could NOT export the sealed-secrets key — SealedSecrets would be unrecoverable"
  fi

  # Cluster state. Complementary to PVC contents, not a substitute.
  if [[ -d /var/lib/rancher/k3s/server/db/snapshots ]]; then
    cp -a /var/lib/rancher/k3s/server/db/snapshots "$STAGE/etcd-snapshots" 2>/dev/null || true
    log "staged etcd snapshots"
  fi
}

# --- consistent snapshots of anything PostgreSQL -----------------------------
# Immich is the first Postgres workload on this box, and it does NOT play by
# the same rules as the SQLite ones above.
#
# 🔴 Immich's own documentation is explicit: DO NOT back up the Postgres data
# directory. A live file copy of PGDATA is torn in exactly the way a `cp` of a
# WAL-mode SQLite file is torn -- same class of bug stage_sqlite() exists to
# prevent, different engine. pg_dump is the supported path.
#
# The dump is the load-bearing half of an Immich backup. The photo files are
# just files, but the DATABASE holds the entire external-library index: which
# assets exist, their dates, faces, tags, albums and locked-folder state. Lose
# it and the photos survive as ordinary files while everything Immich knows
# about them is gone.
stage_postgres() {
  local ns dep
  for spec in "immich-private:immich-postgres"; do
    ns="${spec%%:*}"; dep="${spec##*:}"
    kubectl -n "$ns" get deploy "$dep" >/dev/null 2>&1 || continue

    local pod
    pod="$(kubectl -n "$ns" get pod -l "app=$dep" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
    [[ -n "$pod" ]] || { log "WARN: $ns/$dep has no running pod; database NOT staged"; continue; }

    local out="$STAGE/${ns}-${dep}.sql.gz"
    # --clean --if-exists so the dump can be replayed onto a non-empty database
    # without a manual drop first, which is what you actually want at 3am
    # during a restore.
    if kubectl -n "$ns" exec "$pod" -- \
         pg_dump --clean --if-exists --username=immich --dbname=immich 2>/dev/null \
         | gzip > "$out"; then
      # A pg_dump that fails midway still leaves a valid gzip of a TRUNCATED
      # dump. Size alone cannot tell them apart, so assert the terminator
      # pg_dump writes only on success.
      if zcat "$out" | tail -5 | grep -q 'PostgreSQL database dump complete'; then
        log "staged $ns/$dep ($(du -h "$out" | cut -f1)) via pg_dump"
      else
        die "$ns/$dep dump is TRUNCATED (no completion marker) — refusing to store a partial database"
      fi
    else
      rm -f "$out"
      die "pg_dump failed for $ns/$dep — refusing to back up photos without their index"
    fi
  done
}

build_paths() {
  PATHS=("$STAGE")
  # Home Assistant: config + entity registry. .storage/*.json are written
  # atomically, so they are safe to copy live.
  PATHS+=(/home/jacob/Documents/homeassistant)
  # The AI's persistent memory, and ComfyUI's own data.
  local p
  for claim in memory-data comfyui-data; do
    p="$(pvc_path ai-stack "$claim")"; [[ -n "$p" ]] && PATHS+=("$p")
  done
  # Immich's ORIGINALS only. The library is an external read-only mount, so
  # these files are the irreplaceable half; everything Immich derives from them
  # is excluded below.
  [[ -d /home/jacob/backup/Jacob/untitled ]] && PATHS+=(/home/jacob/backup/Jacob/untitled)
  # Server-only secrets (git-ignored by design).
  [[ -f "$ENV_FILE" ]] && PATHS+=("$ENV_FILE")
  [[ -f "$STACK_DIR/monitoring/.env" ]] && PATHS+=("$STACK_DIR/monitoring/.env")
  [[ -d "$STACK_DIR/prompts" ]] && PATHS+=("$STACK_DIR/prompts")
}

# Deliberately excluded, with reasons:
#   ollama models   ~40GB, re-pullable with `ollama pull`
#   SDXL checkpoint 6.9GB, re-downloadable
#   loki/prometheus/grafana  observability history; regenerable, and Grafana's
#                            config is entirely reproducible from git
#   registry-data   images rebuildable from the Dockerfiles in git
#   HA recorder db  large, history only
#   immich thumbs/  regenerable: Immich rebuilds them from the originals with a
#   encoded-video/  job. Backing them up would multiply the library size for
#                   data that is derived, not authored. After a restore, run
#                   the thumbnail + transcode jobs. The PRISTINE COPY is
#                   excluded for the same reason -- it is a byte-identical
#                   duplicate of a path already in PATHS, so including it would
#                   double the photo bytes in every snapshot for no recovery
#                   value. (restic dedupes, but the path list should still say
#                   what it means.)
EXCLUDES=(
  --exclude '*.safetensors' --exclude '*.ckpt' --exclude '*.gguf'
  --exclude 'home-assistant_v2.db*'
  --exclude '*/models/checkpoints/*'
  --exclude '*.tmp' --exclude '*-wal' --exclude '*-shm'
  --exclude '/srv/photos/pristine'
  --exclude '*/thumbs/*' --exclude '*/encoded-video/*'
)

do_backup() {
  have_repo || die "RESTIC_REPOSITORY / RESTIC_PASSWORD not set in $ENV_FILE — no target chosen yet"
  command -v restic >/dev/null || die "restic not installed; run --install first"
  restic snapshots >/dev/null 2>&1 || { log "initialising repo"; restic init; }
  stage_sqlite; stage_postgres; build_paths
  log "backing up: ${PATHS[*]}"
  restic backup "${PATHS[@]}" "${EXCLUDES[@]}" --tag homeserver --verbose
  restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
  rm -rf "$STAGE"
  log "done"
}

do_dry_run() {
  stage_sqlite; stage_postgres; build_paths
  log "WOULD back up:"; printf '  %s\n' "${PATHS[@]}"
  log "excludes: ${EXCLUDES[*]}"
  have_repo && log "repo: ${RESTIC_REPOSITORY}" || log "repo: NOT CONFIGURED — no backup would run"
  du -sh "${PATHS[@]}" 2>/dev/null | sed 's/^/  /'
  rm -rf "$STAGE"
}

do_install() {
  command -v restic >/dev/null || { log "installing restic"; apt-get update -qq && apt-get install -y -qq restic sqlite3; }
  cat > /etc/systemd/system/homeserver-backup.service <<'UNIT'
[Unit]
Description=Home server restic backup
After=network-online.target k3s.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/home/jacob/docker/ai-stack/scripts/setup-backup.sh --run
UNIT
  cat > /etc/systemd/system/homeserver-backup.timer <<'UNIT'
[Unit]
Description=Daily home server backup

[Timer]
# 03:30 — before the Sunday 04:30 deploy cron, after the 03:00 etcd snapshot
# so the freshest cluster state is included.
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  if have_repo; then
    systemctl enable --now homeserver-backup.timer
    log "timer enabled"
  else
    systemctl disable --now homeserver-backup.timer 2>/dev/null || true
    log "timer installed but NOT enabled — no RESTIC_REPOSITORY yet (see header)"
  fi
}

case "${1:---dry-run}" in
  --install) do_install ;;
  --run)     do_backup ;;
  --dry-run) do_dry_run ;;
  *) die "usage: $0 [--install|--run|--dry-run]" ;;
esac
