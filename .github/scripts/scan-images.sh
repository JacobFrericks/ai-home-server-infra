#!/usr/bin/env bash
# Trivy delta gate for the two self-built images (memory-mcp, comfyui-mcp).
#
# The body of .github/workflows/image-scan.yml, kept as a script so the same
# verdict can be reproduced by hand on the server when a run is surprising.
#
# $TRIVY_DB_REF pins the vulnerability database; leaving it unset lets trivy
# resolve whatever is current. image-scan.yml always sets it. The unset path is
# kept for running this by hand -- it was also how the nightly canary ran,
# before that canary was removed on 2026-09-11.
#
# WHY THE IMAGES ARE BUILT HERE RATHER THAN PULLED: memory-mcp and comfyui-mcp
# are pushed ONLY to a loopback-only in-cluster registry (localhost:5000 on the
# k3s node) -- a GitHub-hosted runner cannot reach it, by design (see
# ai-home-server-k8s/infra/registry/registry.yaml). So this builds each
# Dockerfile fresh, scans the LOCAL build with the docker-daemon scanner, and
# never pushes anywhere.
#
# WHY THE BASELINE IS COUNTS-ONLY: this repo is PUBLIC.
# security/baseline/images/*.json commits only a COUNT of accepted findings per
# severity, never a specific CVE ID -- a named, dated "here is our unpatched
# hole" list has no business in a public repo. A run fails only if a severity's
# count goes UP. See vuln-baseline.py's module docstring for the precision this
# trades away on purpose.
set -euo pipefail

TRIVY_VERSION=0.74.0
IMAGES=(memory-mcp comfyui-mcp)

# Everything scratch goes in one throwaway dir rather than bare /tmp. This is
# not tidiness: on the home server /tmp/trivy is a ROOT-OWNED CACHE DIRECTORY
# belonging to the 02:00 nightly scan timer, so extracting a binary called
# /tmp/trivy fails there. Keeping the scratch self-contained means this script
# reproduces CI's verdict when run by hand on the server, which is exactly what
# you want when a run is surprising.
WORK="$(mktemp -d)"

BASE=https://github.com/aquasecurity/trivy/releases/download
TGZ="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
curl -sSL "$BASE/v${TRIVY_VERSION}/$TGZ" | tar -xz -C "$WORK" trivy

# Say plainly which database this run used. When a scan result is surprising,
# this line is the first thing worth reading.
db_args=()
if [ -n "${TRIVY_DB_REF:-}" ]; then
  db_args=(--db-repository "$TRIVY_DB_REF")
  echo "vulnerability DB: PINNED -> ${TRIVY_DB_REF}"
else
  echo "vulnerability DB: LATEST (trivy defaults, unpinned)"
fi

fail=0
for img in "${IMAGES[@]}"; do
  docker build -t "${img}:ci-scan" "${img}/"
  "$WORK/trivy" image --severity HIGH,CRITICAL --exit-code 0 -f json \
    "${db_args[@]}" \
    -o "${WORK}/${img}-scan.json" "${img}:ci-scan"
  python3 .github/scripts/vuln-baseline.py check \
    --scan "${WORK}/${img}-scan.json" \
    --baseline "security/baseline/images/${img}.json" \
    --target "image:${img}" || fail=1
done

# On failure vuln-baseline.py prints a ready-to-run `generate` command that
# references the scan JSON, so the scratch dir has to outlive the run for that
# advice to be usable. Only clean up when there is nothing left to look at.
if [ "$fail" -eq 0 ]; then
  rm -rf "$WORK"
else
  rm -f "$WORK/trivy"
  echo "scan output kept for the command above: $WORK"
fi
exit $fail
