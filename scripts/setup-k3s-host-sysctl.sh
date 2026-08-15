#!/usr/bin/env bash
# Host sysctl tuning required by k3s. Idempotent; safe to re-run.
#
# WHY THIS EXISTS
# ---------------
# cAdvisor started crashing with `inotify_init: too many open files` after the
# monitoring stack moved into k3s -- having run fine under Docker Compose for
# months. Nothing about cAdvisor changed. What changed is that k3s, Cilium,
# Argo CD, the local-path provisioner and every controller now share the SAME
# per-uid inotify instance budget as root, and the kernel default of 128 no
# longer covers it.
#
# This is a host-level consequence of running Kubernetes that no manifest can
# express, and it surfaces as an unrelated-looking crash in whichever component
# happens to request the 129th instance -- it was luck that the victim was
# cAdvisor and not etcd.
set -euo pipefail

CONF=/etc/sysctl.d/60-k3s-inotify.conf

if [[ $EUID -ne 0 ]]; then
  echo "must run as root (sysctl + /etc/sysctl.d)" >&2
  exit 1
fi

cat > "$CONF" <<'SYSCTL'
# Managed by scripts/setup-k3s-host-sysctl.sh -- see that file for rationale.
# Raised 2026-08-15 during the k3s migration: k3s + Cilium + Argo exhaust the
# kernel default of 128 inotify instances for uid 0, which killed cAdvisor.
fs.inotify.max_user_instances = 1024
SYSCTL

sysctl --system >/dev/null
echo "fs.inotify.max_user_instances = $(cat /proc/sys/fs/inotify/max_user_instances)"
echo "in-use inotify fds: $(find /proc/*/fd -lname "anon_inode:inotify" 2>/dev/null | wc -l)"
