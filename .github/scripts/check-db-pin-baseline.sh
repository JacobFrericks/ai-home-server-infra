#!/usr/bin/env bash
# Guard: the pinned vulnerability database and the baselines cut from it must
# move in the SAME commit.
#
# image-scan.yml pins TRIVY_DB_REF so the gate only changes verdict when this
# repo changes, and Renovate keeps that pin current. That Renovate PR is the one
# review point where database movement is actually looked at -- but Renovate
# edits ONLY the pin. It has no idea security/baseline/images/*.json exist, so a
# database bump can merge with baselines cut against the PREVIOUS database.
#
# That is not merely untidy, because the gate is a ONE-WAY RATCHET: it fails
# when a severity count goes UP and is silent when one goes DOWN. So if the new
# database reports FEWER findings, the PR is green and the baseline keeps the
# old, higher numbers. The difference is permanent slack that a genuine
# regression can later hide inside -- the gate would read "51 HIGH, not higher
# than accepted" while the truth had moved. infra#81 (2026-09-06) merged in
# exactly this shape.
#
# So: if TRIVY_DB_REF moved in this PR, every baseline must move too. This is
# the "expect that PR to arrive red" behaviour image-scan.yml's header already
# promises; until now nothing enforced it.
set -euo pipefail

: "${BASE_SHA:?BASE_SHA must be set (github.event.pull_request.base.sha)}"

WORKFLOW=.github/workflows/image-scan.yml
BASELINES=(
  security/baseline/images/memory-mcp.json
  security/baseline/images/comfyui-mcp.json
)

# Read the pin out of a given revision of the workflow. Missing file or missing
# key yields an empty string, which compares unequal to a real pin and so fails
# closed rather than silently passing.
pin_at() {
  git show "$1:$WORKFLOW" 2>/dev/null \
    | sed -n 's/^[[:space:]]*TRIVY_DB_REF:[[:space:]]*//p' \
    | head -1
}

before=$(pin_at "$BASE_SHA")
after=$(sed -n 's/^[[:space:]]*TRIVY_DB_REF:[[:space:]]*//p' "$WORKFLOW" | head -1)

if [ -z "$after" ]; then
  echo "FAIL: no TRIVY_DB_REF found in $WORKFLOW -- the gate would silently"
  echo "      fall back to an unpinned database. This guard fails closed."
  exit 1
fi

if [ "$before" = "$after" ]; then
  echo "OK: TRIVY_DB_REF unchanged in this PR -- nothing to enforce."
  exit 0
fi

echo "TRIVY_DB_REF moved in this PR:"
echo "  before: ${before:-<absent>}"
echo "  after:  $after"

stale=()
for f in "${BASELINES[@]}"; do
  if git diff --quiet "$BASE_SHA" -- "$f"; then
    stale+=("$f")
  fi
done

if [ ${#stale[@]} -eq 0 ]; then
  echo "OK: every baseline moved in the same commit."
  exit 0
fi

echo
echo "FAIL: the database pin moved but these baselines did not:"
printf '  %s\n' "${stale[@]}"
cat <<'ADVICE'

A baseline cut against a different database than the gate uses is how this goes
quietly wrong -- and because the gate only fails on an INCREASE, a database that
reports fewer findings leaves permanent slack behind with a green check.

Fix, on this branch:
  1. Re-run the scan against the NEW pin:
       .github/scripts/scan-images.sh
  2. For each image, decide whether the new numbers are acceptable, then:
       python3 .github/scripts/vuln-baseline.py generate \
         --scan <the scan JSON the run above kept> \
         --baseline security/baseline/images/<image>.json \
         --target 'image:<image>'
  3. Commit the regenerated baselines alongside the pin.
ADVICE
exit 1
