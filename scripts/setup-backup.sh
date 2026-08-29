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
# STATUS: LIVE since 2026-08-23
# ---------------------------------------------------------------------------
# Target is /srv/backup/restic — an ext4 filesystem on /dev/md0, a two-disk
# mdadm RAID 1 mirror built by scripts/setup-raid.sh. One disk can die without
# losing the repository. Both member disks are ~6 years old, so the mirror is a
# TARGET, not a strategy: offsite (S3 Glacier IR) is still deferred and still
# the real remaining gap.
#
# RESTIC_REPOSITORY and RESTIC_PASSWORD live in the git-ignored .env. The
# password is the encryption key and MUST also exist off this machine — if the
# box is lost with the only copy of the password, every snapshot on the mirror
# is permanently unreadable.
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

# --- is the cluster actually answering? -------------------------------------
# Not a nicety. On 2026-08-28 the host booted with no network (the NIC profile
# was user-scoped, so it waited for a desktop login), k3s died with "no default
# routes found", and this script hit `kubectl` returning nothing. The old
# pvc_path piped that empty output straight into python, which raised
# JSONDecodeError and -- under `set -e` -- killed the whole run. Result: zero
# backup that night, including the 240GB of photos that were sitting right there
# on a perfectly healthy disk and needed no cluster at all.
CLUSTER_UP=0
check_cluster() {
  if kubectl get --raw='/readyz' >/dev/null 2>&1 || kubectl get pv >/dev/null 2>&1; then
    CLUSTER_UP=1
  else
    CLUSTER_UP=0
    log "WARN: the k3s API is NOT reachable — this run will be INCOMPLETE."
    log "WARN: skipping webui.db, the sealed-secrets key, immich-db and the PVCs."
  fi
}

# --- resolve the k3s PVC host paths by CLAIM, never by UUID -----------------
# Returns empty (never fails) when the cluster is down, so a caller can decide.
pvc_path() {  # $1=namespace $2=claim
  [[ $CLUSTER_UP -eq 1 ]] || return 0
  kubectl get pv -o json 2>/dev/null | python3 -c '
import json,sys
ns,claim=sys.argv[1],sys.argv[2]
try:
    items=json.load(sys.stdin)["items"]
except Exception:
    sys.exit(0)          # cluster unreachable or malformed: no path, not a crash
for p in items:
    c=p["spec"].get("claimRef") or {}
    if c.get("namespace")==ns and c.get("name")==claim:
        src=p["spec"].get("hostPath") or p["spec"].get("local") or {}
        print(src.get("path","")); break
' "$1" "$2"
}

# --- consistent snapshots of anything SQLite --------------------------------
stage_sqlite() {
  rm -rf "$STAGE"; mkdir -p "$STAGE"; chmod 700 "$STAGE"

  # etcd snapshots are on local disk, so they are worth grabbing even when the
  # API is down -- they are often exactly what you need to explain WHY it is.
  if [[ -d /var/lib/rancher/k3s/server/db/snapshots ]]; then
    cp -a /var/lib/rancher/k3s/server/db/snapshots "$STAGE/etcd-snapshots" 2>/dev/null || true
    log "staged etcd snapshots"
  fi

  # Everything below needs a live API server. Skip rather than crash.
  if [[ $CLUSTER_UP -ne 1 ]]; then
    log "cluster down: skipping webui.db, sealed-secrets key and immich-db"
    return 0
  fi

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

  # Immich's Postgres. The photo FILES are an external read-only library under
  # /home/jacob/backup (backed up as a plain path below), but the database is
  # what makes them a library rather than a folder: albums, faces, dates, and
  # the Locked Folder membership all live here and exist nowhere else.
  # A file-level copy of a running Postgres data directory is torn by
  # definition, so dump it through the server instead.
  if kubectl -n immich-private get deploy immich-postgres >/dev/null 2>&1; then
    if kubectl -n immich-private exec deploy/immich-postgres -- \
         sh -c 'pg_dumpall --clean --if-exists -U "$POSTGRES_USER"' \
         > "$STAGE/immich-db.sql" 2>/dev/null && [[ -s "$STAGE/immich-db.sql" ]]; then
      chmod 600 "$STAGE/immich-db.sql"
      log "staged immich-db.sql ($(du -h "$STAGE/immich-db.sql" | cut -f1))"
    else
      rm -f "$STAGE/immich-db.sql"
      log "WARN: immich pg_dumpall FAILED — the photo library metadata is NOT backed up"
    fi
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

# --- what goes in each tier -------------------------------------------------
# Two tiers, because an offsite copy has to move at two different speeds.
#
#   critical  ~6.5GB  the sealed-secrets master key, the staged databases, the
#                     configs and the secrets. Irreplaceable AND changes daily,
#                     so it is cheap enough to push to S3 every night.
#   bulk      ~234GB  /home/jacob/backup: photos, music, documents, the old
#                     PC's archive. Irreplaceable but nearly static, so it goes
#                     offsite weekly.
#
# Both land in the SAME local repository, so restic still deduplicates across
# them and nothing about local restore changes. The split exists so that
# `restic copy` has something to select on -- you cannot copy half a snapshot,
# and pushing 234GB to S3 every night to protect 6.5GB of churn is waste.
#
# The tags these produce are load-bearing: scripts/setup-offsite-backup.sh
# selects on them. Renaming a tier means changing both files.
build_critical_paths() {
  CRITICAL_PATHS=("$STAGE")
  # Home Assistant: config + entity registry. .storage/*.json are written
  # atomically, so they are safe to copy live.
  CRITICAL_PATHS+=(/home/jacob/Documents/homeassistant)
  # The AI's persistent memory, and ComfyUI's own data.
  local p
  for claim in memory-data comfyui-data; do
    p="$(pvc_path ai-stack "$claim")"; [[ -n "$p" ]] && CRITICAL_PATHS+=("$p")
  done
  # Server-only secrets (git-ignored by design).
  [[ -f "$ENV_FILE" ]] && CRITICAL_PATHS+=("$ENV_FILE")
  [[ -f "$STACK_DIR/monitoring/.env" ]] && CRITICAL_PATHS+=("$STACK_DIR/monitoring/.env")
  [[ -d "$STACK_DIR/prompts" ]] && CRITICAL_PATHS+=("$STACK_DIR/prompts")
}

build_bulk_paths() {
  BULK_PATHS=()
  # Photos, documents and the old PC's archive (~234GB). These are ORIGINALS,
  # not a copy of something else: they were moved off the WD drives when those
  # became the RAID mirror, so the NVMe holds the only copy.
  #
  # Immich's read-only external library (Jacob/untitled, ~51GB) lives INSIDE
  # this path. It used to be listed separately to document that, which bought
  # nothing but a second tree walk over the same bytes.
  [[ -d /home/jacob/backup ]] && BULK_PATHS+=(/home/jacob/backup)
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
#                   duplicate of a path already in BULK_PATHS, so including it would
#                   double the photo bytes in every snapshot for no recovery
#                   value. (restic dedupes, but the path list should still say
#                   what it means.)
#   .Trash-1000     deleted files the user already threw away
#   System Volume   Windows metadata carried in from the old PC archive
#   Information/
EXCLUDES=(
  --exclude '*.safetensors' --exclude '*.ckpt' --exclude '*.gguf'
  --exclude 'home-assistant_v2.db*'
  --exclude '*/models/checkpoints/*'
  --exclude '*.tmp' --exclude '*-wal' --exclude '*-shm'
  --exclude '/srv/photos/pristine'
  --exclude '*/thumbs/*' --exclude '*/encoded-video/*'
  --exclude '*/.Trash-1000/*'
  --exclude '*/System Volume Information/*'
)

do_backup() {
  have_repo || die "RESTIC_REPOSITORY / RESTIC_PASSWORD not set in $ENV_FILE — no target chosen yet"
  command -v restic >/dev/null || die "restic not installed; run --install first"
  restic snapshots >/dev/null 2>&1 || { log "initialising repo"; restic init; }
  check_cluster
  stage_sqlite; build_critical_paths; build_bulk_paths
  if [[ $CLUSTER_UP -eq 1 ]]; then stage_postgres; fi

  # A run without the cluster still saves the photos, documents and HA config --
  # 234GB that needs no API server. It is tagged so it can never be mistaken for
  # a full one, and it deliberately does NOT publish the success metric, so the
  # freshness alert fires exactly as if nothing had run.
  local common=(--tag homeserver)
  [[ $CLUSTER_UP -eq 1 ]] || common+=(--tag incomplete)

  log "backing up CRITICAL tier: ${CRITICAL_PATHS[*]}"
  restic backup "${CRITICAL_PATHS[@]}" "${EXCLUDES[@]}" "${common[@]}" --tag critical --verbose

  if [[ ${#BULK_PATHS[@]} -gt 0 ]]; then
    log "backing up BULK tier: ${BULK_PATHS[*]}"
    restic backup "${BULK_PATHS[@]}" "${EXCLUDES[@]}" "${common[@]}" --tag bulk --verbose
  else
    log "WARN: bulk tier is EMPTY — /home/jacob/backup is missing"
  fi

  # Retention is applied per tier. --group-by '' collapses each tier into a
  # single group: the default grouping is by host+paths, and a cluster-down run
  # changes the path list, which would silently create a second group with its
  # own independent retention and quietly keep snapshots forever.
  restic forget --tag critical --group-by '' --keep-daily 7 --keep-weekly 4 --keep-monthly 6
  restic forget --tag bulk     --group-by '' --keep-daily 7 --keep-weekly 4 --keep-monthly 6
  restic prune
  rm -rf "$STAGE"

  if [[ $CLUSTER_UP -eq 1 ]]; then
    publish_success_metric
    log "done"
  else
    # Non-zero so systemd records a failure. The data that could be saved WAS
    # saved; this exit code is the alarm, not a rollback.
    log "done, but INCOMPLETE — cluster was unreachable; snapshots tagged 'incomplete'"
    return 1
  fi
}

# A backup job that fails silently is worse than no backup, because it looks
# like one. node-exporter's textfile collector turns "the last run succeeded,
# and when" into a metric Prometheus can alert on (BackupJobFailing /
# BackupJobNeverRan in the monitoring repo). Written only AFTER restic exits 0.
publish_success_metric() {
  local dir=/var/lib/node_exporter/textfile_collector
  [[ -d "$dir" ]] || { log "WARN: $dir missing — backup freshness is NOT monitored"; return 0; }
  # Write-then-rename: the collector must never read a half-written file.
  local tmp="$dir/.homeserver_backup.prom.$$"
  {
    echo '# HELP homeserver_backup_last_success_timestamp_seconds Unix time of the last successful restic backup.'
    echo '# TYPE homeserver_backup_last_success_timestamp_seconds gauge'
    echo "homeserver_backup_last_success_timestamp_seconds $(date +%s)"
  } > "$tmp"
  mv -f "$tmp" "$dir/homeserver_backup.prom"
  chmod 644 "$dir/homeserver_backup.prom"
}

do_dry_run() {
  check_cluster
  stage_sqlite; build_critical_paths; build_bulk_paths
  if [[ $CLUSTER_UP -eq 1 ]]; then stage_postgres; fi
  log "WOULD back up CRITICAL tier (offsite nightly):"; printf '  %s\n' "${CRITICAL_PATHS[@]}"
  log "WOULD back up BULK tier (offsite weekly):";      printf '  %s\n' "${BULK_PATHS[@]}"
  log "excludes: ${EXCLUDES[*]}"
  have_repo && log "repo: ${RESTIC_REPOSITORY}" || log "repo: NOT CONFIGURED — no backup would run"
  du -sh "${CRITICAL_PATHS[@]}" "${BULK_PATHS[@]}" 2>/dev/null | sed 's/^/  /'
  rm -rf "$STAGE"
}

do_install() {
  command -v restic >/dev/null || { log "installing restic"; apt-get update -qq && apt-get install -y -qq restic sqlite3; }
  # Where publish_success_metric drops the freshness gauge. node-exporter reads
  # this directory via a hostPath mount (see the monitoring repo).
  mkdir -p /var/lib/node_exporter/textfile_collector
  chmod 755 /var/lib/node_exporter/textfile_collector
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
