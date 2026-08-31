#!/usr/bin/env bash
# setup-offsite-backup.sh — push the local restic repo to S3 Glacier Instant
# Retrieval. Idempotent. Safe to re-run.
#
#   sudo ./scripts/setup-offsite-backup.sh --check        # read-only: config, creds, bucket
#   sudo ./scripts/setup-offsite-backup.sh --init         # create the offsite repo (once)
#   sudo ./scripts/setup-offsite-backup.sh --copy critical
#   sudo ./scripts/setup-offsite-backup.sh --copy bulk
#   sudo ./scripts/setup-offsite-backup.sh --maintain     # forget/prune + check
#   sudo ./scripts/setup-offsite-backup.sh --install      # systemd units + timers
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
# /srv/backup is a two-disk RAID 1 mirror. That survives a dead disk. It does
# not survive a fire, a theft, a flood, or a delete. Both mirror members are
# ~6 years old and were bought together, so correlated failure is realistic.
#
# ---------------------------------------------------------------------------
# THE THREE DESIGN DECISIONS, AND WHY
# ---------------------------------------------------------------------------
# 1. GLACIER INSTANT RETRIEVAL, NOT DEEP ARCHIVE.
#    restic must be able to GET any pack file on demand to check, prune, or
#    restore. Glacier IR serves reads immediately. Deep Archive puts every read
#    behind a 12-hour thaw job, which breaks every restic operation. Deep
#    Archive saves ~$8/year and costs you a backup that works.
#
# 2. A LIFECYCLE RULE, NOT `-o s3.storage-class`.
#    restic's storage-class option applies to EVERYTHING, and restic only
#    exempts metadata for GLACIER and DEEP_ARCHIVE -- not for GLACIER_IR. Small
#    frequently-rewritten index/ and snapshots/ objects in Glacier IR would hit
#    both the 128KB minimum billable size and the 90-day minimum storage
#    duration. So aws/bucket-lifecycle.json filters on `restic/data/` and leaves
#    everything restic reads constantly in STANDARD.
#
# 3. `restic copy` INTO AN INDEPENDENT REPO, NOT AN rclone MIRROR.
#    A mirror propagates damage: a bad `forget --prune` at home would delete the
#    offsite copy too. An independent repo has its own snapshot list and its own
#    retention. The cost is that copy re-encrypts, so it is CPU-bound.
#
#    The offsite repo MUST be initialised with --copy-chunker-params. Without
#    it the two repos chunk data differently and every copy re-uploads
#    everything. This is not a tuning knob; it is load-bearing.
set -euo pipefail

STACK_DIR=/home/jacob/docker/ai-stack
ENV_FILE="$STACK_DIR/.env"
STATE_DIR=/var/lib/backup-offsite
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector

# Larger packs mean fewer, bigger S3 objects: fewer PUT requests to seed, and
# nothing bumping into Glacier IR's 128KB minimum billable object size.
OFFSITE_PACK_SIZE=64

# systemd starts services with no $HOME, and restic locates its cache via
# $XDG_CACHE_HOME or $HOME. Without one it runs cacheless and re-downloads the
# repository index from S3 on EVERY run -- slow, and billed as egress at
# $0.09/GB. Pin the cache explicitly so it never depends on who invoked us.
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"

# Retention offsite is deliberately LONGER than local (7d/4w/6m). Offsite is the
# copy you reach for when the local one is gone, which is exactly when you may
# not know how long the problem has been going on. It also keeps objects past
# Glacier IR's 90-day minimum storage duration, so pruning does not trigger
# early-delete fees.
KEEP=(--keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 3)

log() { printf '[offsite] %s\n' "$*"; }
die() { printf '[offsite] ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (reads /srv/backup, writes systemd units and the textfile collector)"

# --- config, from the git-ignored .env --------------------------------------
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY (the LOCAL repo) not set in $ENV_FILE}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set in $ENV_FILE}"
: "${RESTIC_OFFSITE_REPOSITORY:?RESTIC_OFFSITE_REPOSITORY not set in $ENV_FILE}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID not set in $ENV_FILE}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY not set in $ENV_FILE}"
: "${AWS_DEFAULT_REGION:?AWS_DEFAULT_REGION not set in $ENV_FILE}"

SRC="$RESTIC_REPOSITORY"
DST="$RESTIC_OFFSITE_REPOSITORY"

# The bucket name is DERIVED from the repo URL above, not written in this file.
# It lives in the git-ignored .env with the credentials, because this repository
# is public and a value that names infrastructure belongs alongside them even
# when it is not itself a credential. Same convention as the ntfy topic, which
# verify-services.sh reads at runtime rather than hardcoding.
#
#   s3:s3.<region>.amazonaws.com/<bucket>/restic   ->   <bucket>
#
# 🔴 An empty BUCKET must stop the script, not continue. `aws s3api --bucket ""`
# fails on every call, so preflight() would report a wall of unrelated failures
# and send you looking at IAM. Fail here, once, with the actual reason.
BUCKET="${DST#*amazonaws.com/}"; BUCKET="${BUCKET%%/*}"
[[ -n "$BUCKET" && "$BUCKET" != "$DST" ]] || die \
  "cannot derive a bucket from RESTIC_OFFSITE_REPOSITORY ('$DST') -- expected \
s3:s3.<region>.amazonaws.com/<bucket>/restic"

# --- source-repo password ----------------------------------------------------
# `restic copy` needs a password for the SOURCE repo, and there is no
# RESTIC_FROM_PASSWORD env var -- only --from-password-file/-command. Both repos
# use the same password, so hand restic a file on /dev/shm: tmpfs, so it is
# memory-backed and never written to a physical disk, mode 0600, and removed on
# exit including on failure.
PWDIR=""
make_from_password_file() {
  PWDIR="$(mktemp -d /dev/shm/offsite-pw.XXXXXX)"
  chmod 700 "$PWDIR"
  ( umask 077; printf '%s' "$RESTIC_PASSWORD" > "$PWDIR/pw" )
  FROM_PW="$PWDIR/pw"
}
cleanup() { [[ -n "$PWDIR" ]] && rm -rf "$PWDIR"; }
trap cleanup EXIT

# restic against the offsite repo, with the S3 tuning applied consistently.
rdst() { restic -r "$DST" --pack-size "$OFFSITE_PACK_SIZE" "$@"; }

# --- read-only preflight -----------------------------------------------------
do_check() {
  local fail=0
  log "local (source) repo:  $SRC"
  log "offsite (dest) repo:  $DST"
  log "region:               $AWS_DEFAULT_REGION"

  command -v restic >/dev/null || { log "FAIL: restic not installed"; fail=1; }
  command -v aws    >/dev/null || { log "FAIL: awscli not installed"; fail=1; }

  # The bucket's region is baked into the repo URL. A mismatch shows up as an
  # endless retry loop on '301 Moved Permanently', which looks like a network
  # problem and is not one.
  local real
  real="$(aws s3api get-bucket-location --bucket "$BUCKET" --output text 2>/dev/null || echo UNKNOWN)"
  [[ "$real" == "null" ]] && real=us-east-1   # the API's quirky name for us-east-1
  if [[ "$real" == "$AWS_DEFAULT_REGION" ]]; then
    log "OK:   bucket is in $real"
  else
    log "FAIL: bucket is in '$real' but config says '$AWS_DEFAULT_REGION'"; fail=1
  fi

  if [[ "$DST" == *"$AWS_DEFAULT_REGION"* ]]; then
    log "OK:   repo URL names the right region"
  else
    log "FAIL: RESTIC_OFFSITE_REPOSITORY does not contain $AWS_DEFAULT_REGION"; fail=1
  fi

  # Versioning is what makes it safe to grant DeleteObject. restic needs delete
  # for its lock files and for prune; versioning turns a delete into a
  # recoverable delete marker for 30 days.
  if [[ "$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>/dev/null)" == "Enabled" ]]; then
    log "OK:   bucket versioning enabled"
  else
    log "FAIL: bucket versioning is NOT enabled"; fail=1
  fi

  if aws s3api get-public-access-block --bucket "$BUCKET" \
       --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
       --output text 2>/dev/null | grep -qx 'True	True	True	True'; then
    log "OK:   all four public-access blocks on"
  else
    log "FAIL: bucket is not fully blocked from public access"; fail=1
  fi

  # Without this rule everything sits in STANDARD at $5.31/month instead of
  # $0.92/month. It is the single line that makes this affordable.
  if aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --output json 2>/dev/null \
     | grep -q GLACIER_IR; then
    log "OK:   lifecycle transitions data to GLACIER_IR"
  else
    log "FAIL: no GLACIER_IR lifecycle rule — storage would cost ~5x"; fail=1
  fi

  if restic -r "$SRC" --no-cache cat config >/dev/null 2>&1; then
    log "OK:   local repo readable"
  else
    log "FAIL: cannot read local repo at $SRC"; fail=1
  fi

  if rdst --no-cache --retry-lock=0 cat config >/dev/null 2>&1; then
    log "OK:   offsite repo exists and the password works"
  else
    log "NOTE: offsite repo not initialised yet — run --init"
  fi

  [[ $fail -eq 0 ]] || die "preflight FAILED"
  log "preflight passed"
}

# --- one-time creation of the offsite repo -----------------------------------
do_init() {
  if rdst --no-cache --retry-lock=0 cat config >/dev/null 2>&1; then
    log "offsite repo already initialised — nothing to do"
    return 0
  fi
  make_from_password_file
  log "initialising offsite repo WITH --copy-chunker-params (required for dedup)"
  rdst init --copy-chunker-params --from-repo "$SRC" --from-password-file "$FROM_PW"
  log "offsite repo created"
}

# --- copy one tier ------------------------------------------------------------
do_copy() {
  local tier="$1"
  [[ "$tier" == critical || "$tier" == bulk ]] || die "tier must be 'critical' or 'bulk', got '$tier'"

  rdst --no-cache --retry-lock=0 cat config >/dev/null 2>&1 \
    || die "offsite repo does not exist — run --init first"

  make_from_password_file
  mkdir -p "$STATE_DIR" "$RESTIC_CACHE_DIR"; chmod 700 "$STATE_DIR"

  log "copying tier '$tier' -> $DST"
  rdst copy --from-repo "$SRC" --from-password-file "$FROM_PW" --tag "$tier"

  # Written ONLY after restic exits 0. A backup job that reports success it did
  # not achieve is worse than one that fails loudly.
  date +%s > "$STATE_DIR/$tier.ts"

  # Repo size is refreshed on every copy, not only during monthly maintenance,
  # so the OffsiteRepoShrank alert has a daily series to compare against. With
  # the cache warm this reads local index files, not S3.
  rdst stats --mode raw-data --json 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["total_size"])' \
    > "$STATE_DIR/size.bytes" || true

  publish_metrics
  log "tier '$tier' copied"
}

# --- retention + integrity ----------------------------------------------------
do_maintain() {
  rdst --no-cache --retry-lock=0 cat config >/dev/null 2>&1 \
    || die "offsite repo does not exist — run --init first"
  mkdir -p "$STATE_DIR" "$RESTIC_CACHE_DIR"; chmod 700 "$STATE_DIR"

  # --group-by '' collapses each tier into ONE group. The default grouping is
  # host+paths, and a cluster-down run changes the path list, which would
  # silently create a second group with its own retention and keep snapshots
  # forever.
  local t
  for t in critical bulk; do
    log "applying retention to tier '$t'"
    rdst forget --tag "$t" --group-by '' "${KEEP[@]}"
  done
  log "pruning"
  rdst prune

  # Structure-only check. It reads index/ and snapshots/, which the lifecycle
  # rule deliberately leaves in STANDARD, so this costs pennies. Verifying the
  # actual DATA means downloading it out of Glacier IR at $0.03/GB retrieval +
  # $0.09/GB egress, so that is a separate, deliberate, quarterly action:
  #   restic -r "$DST" check --read-data-subset=5%
  log "checking repository structure"
  rdst check

  rdst stats --mode raw-data --json 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["total_size"])' \
    > "$STATE_DIR/size.bytes" || true
  publish_metrics
  log "maintenance done"
}

# --- freshness metrics --------------------------------------------------------
# Regenerated in full from the state files every time, so one .prom file holds
# both tiers. Two files each declaring the same metric name would make
# node-exporter's textfile collector fail to parse.
publish_metrics() {
  [[ -d "$TEXTFILE_DIR" ]] || { log "WARN: $TEXTFILE_DIR missing — offsite freshness is NOT monitored"; return 0; }
  local tmp="$TEXTFILE_DIR/.homeserver_offsite.prom.$$"
  {
    echo '# HELP homeserver_offsite_backup_last_success_timestamp_seconds Unix time of the last successful restic copy to S3.'
    echo '# TYPE homeserver_offsite_backup_last_success_timestamp_seconds gauge'
    local t
    for t in critical bulk; do
      [[ -s "$STATE_DIR/$t.ts" ]] && \
        echo "homeserver_offsite_backup_last_success_timestamp_seconds{tier=\"$t\"} $(cat "$STATE_DIR/$t.ts")"
    done
    if [[ -s "$STATE_DIR/size.bytes" ]]; then
      echo '# HELP homeserver_offsite_repo_size_bytes Raw size of the offsite restic repository.'
      echo '# TYPE homeserver_offsite_repo_size_bytes gauge'
      echo "homeserver_offsite_repo_size_bytes $(cat "$STATE_DIR/size.bytes")"
    fi
  } > "$tmp"
  # Write-then-rename: the collector must never read a half-written file.
  mv -f "$tmp" "$TEXTFILE_DIR/homeserver_offsite.prom"
  chmod 644 "$TEXTFILE_DIR/homeserver_offsite.prom"
}

# --- systemd ------------------------------------------------------------------
do_install() {
  command -v restic >/dev/null || die "restic not installed"
  command -v aws    >/dev/null || { log "installing awscli"; apt-get update -qq && apt-get install -y -qq awscli; }
  mkdir -p "$STATE_DIR" "$TEXTFILE_DIR"; chmod 700 "$STATE_DIR"; chmod 755 "$TEXTFILE_DIR"

  local tier when
  # The local backup runs at 03:30. Critical goes offsite at 05:00, well clear
  # of it. Bulk goes on Sunday at 06:00, after the 04:30 deploy cron.
  for spec in "critical:*-*-* 05:00:00" "bulk:Sun *-*-* 06:00:00"; do
    tier="${spec%%:*}"; when="${spec#*:}"
    cat > "/etc/systemd/system/homeserver-offsite-$tier.service" <<UNIT
[Unit]
Description=Copy restic '$tier' tier offsite to S3 Glacier IR
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$STACK_DIR/scripts/setup-offsite-backup.sh --copy $tier
Nice=10
IOSchedulingClass=idle
UNIT
    cat > "/etc/systemd/system/homeserver-offsite-$tier.timer" <<UNIT
[Unit]
Description=Schedule offsite copy of the restic '$tier' tier

[Timer]
OnCalendar=$when
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
UNIT
  done

  cat > /etc/systemd/system/homeserver-offsite-maintain.service <<UNIT
[Unit]
Description=Offsite restic retention, prune and structure check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$STACK_DIR/scripts/setup-offsite-backup.sh --maintain
Nice=10
IOSchedulingClass=idle
UNIT
  cat > /etc/systemd/system/homeserver-offsite-maintain.timer <<'UNIT'
[Unit]
Description=Schedule monthly offsite retention and check

[Timer]
OnCalendar=*-*-01 07:00:00
Persistent=true
RandomizedDelaySec=1800

[Install]
WantedBy=timers.target
UNIT

  systemctl daemon-reload
  systemctl enable --now homeserver-offsite-critical.timer \
                          homeserver-offsite-bulk.timer \
                          homeserver-offsite-maintain.timer
  log "timers installed:"
  systemctl list-timers --no-pager 'homeserver-offsite-*' | sed 's/^/  /'
}

case "${1:---check}" in
  --check)    do_check ;;
  --init)     do_check; do_init ;;
  --copy)     do_copy "${2:?usage: --copy critical|bulk}" ;;
  --maintain) do_maintain ;;
  --install)  do_install ;;
  *) die "unknown mode '$1' (use --check, --init, --copy TIER, --maintain, --install)" ;;
esac
