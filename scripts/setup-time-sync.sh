#!/usr/bin/env bash
# Keep the host clock synchronised with NTP. Idempotent; safe to re-run.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-30 the host clock was found 63 seconds FAST. Debian 13 (trixie)
# shipped this box with NO time-sync client at all -- systemd-timesyncd is not
# installed by default and nothing else filled the gap, so the clock had been
# free-running on the RTC crystal since install.
#
# A minute of skew is not cosmetic here:
#   - Prometheus/Loki timestamps stop lining up with everything else, so
#     Grafana panels and alert evaluation quietly go wrong.
#   - k3s/Kubernetes client certs and service-account tokens are time-bound;
#     enough skew and the API server rejects them.
#   - restic snapshot times, Immich asset times and backup retention windows
#     are all recorded from this clock.
#
# chrony over systemd-timesyncd: chrony can STEP a large offset (timesyncd
# only slews, so a 63s error would have taken hours to bleed off), it keeps
# disciplining the RTC via rtcsync so the fix survives a power cut, and it
# recovers cleanly from the long offline periods this box sees.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "must run as root (apt + systemctl)" >&2
  exit 1
fi

if ! dpkg -s chrony >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y chrony
fi

systemctl enable --now chrony >/dev/null

# Debian ships rtcsync enabled; assert it so a power cut does not resurrect the
# old skew from the hardware clock.
grep -q "^rtcsync" /etc/chrony/chrony.conf || echo "rtcsync" >> /etc/chrony/chrony.conf

# Correct any offset immediately instead of slewing it off over hours.
chronyc makestep >/dev/null
sleep 3

echo "chrony: $(systemctl is-active chrony) / $(systemctl is-enabled chrony)"
chronyc tracking | grep -E "^(Reference ID|Stratum|System time)"
timedatectl | grep -E "System clock synchronized|NTP service"
