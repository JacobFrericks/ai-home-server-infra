#!/usr/bin/env python3
"""Diff a `trivy k8s --scanners vuln` scan of the LIVE cluster against this
repo's own committed image baseline, and publish node-exporter textfile
metrics. Misconfig/RBAC findings are reported (logged) but NOT baselined --
see below.

Why only the image (CVE) baseline, not the k8s repo's config baseline too:
the design table in security-scanning-ci.md gives "Container image CVEs" a
`delta vs baseline` gate, but "Live cluster posture (RBAC, privileged pods)"
only `report -> alert` -- no baseline column at all. That is also the only
scope that keeps this script self-contained: `ai-home-server-k8s` is a
PRIVATE repo (confirmed via `gh api ... -q .private` -> true, 2026-08-31),
while ai-home-server-infra is public. The GitHub App keys that authenticate
to it live only on the operator's laptop (~/.config/gh-app/), not on this
server, so a live cluster script here has no way to read that repo's
baseline short of shipping a second credential to a second machine -- a
real decision, not something to make unasked inside a nightly cron script.
Reading THIS repo's own local checkout (it already runs from inside one)
needs no network call and no credential at all.

`trivy k8s -f json` nests findings under Resources[].Results[], and the
exact shape has moved between trivy releases before. Rather than pin to one
nested path, this walks the whole document looking for "Vulnerabilities"
and "Misconfigurations" arrays wherever they appear.
"""
import argparse
import datetime
import glob
import json
import os


def walk_findings(node):
    """Yield (id, severity, fixed, kind) for every Vulnerability/
    Misconfiguration found anywhere in a trivy JSON report."""
    if isinstance(node, dict):
        for v in node.get("Vulnerabilities") or []:
            yield (v.get("VulnerabilityID"), v.get("Severity", ""),
                   bool(v.get("FixedVersion")), "vuln")
        for m in node.get("Misconfigurations") or []:
            yield (m.get("ID"), m.get("Severity", ""), True, "misconfig")
        for value in node.values():
            yield from walk_findings(value)
    elif isinstance(node, list):
        for item in node:
            yield from walk_findings(item)


def load_accepted_counts(baseline_path):
    """Accepted fixable-CVE counts for the WHOLE live cluster, by severity.

    Two things forced this shape, both found by the first real run
    (2026-09-02), which reported 913 "new" CVEs and would have paged the
    phone on night one:

    1. FORMAT. This originally read a per-CVE-ID list. That list no longer
       exists: ai-home-server-infra is PUBLIC, so the image baselines were
       rewritten to store only counts per severity -- a dated, named list of
       every unpatched hole on this server has no business in a public repo.
       Reading `findings` out of a count-only file silently loaded 0 IDs, so
       every CVE in the cluster looked new.

    2. SCOPE. The per-image baselines cover the 2 SELF-BUILT images
       (memory-mcp, comfyui-mcp) that CI builds and gates. This scan covers
       every image actually RUNNING -- ~30 of them, including open-webui,
       immich, argocd, ollama. Diffing the second against the first is a
       category error even with matching formats.

    So the live cluster gets its own count baseline, and "new" means the
    fixable count went UP against it. Same deliberate precision tradeoff as
    the CI gate: one CVE fixed and another appearing on the same night keeps
    the count flat and passes unnoticed. That is the price of not naming
    findings in a public repo, and the nightly unit log still prints the
    full detail for whoever is actually looking.
    """
    try:
        with open(baseline_path) as f:
            return json.load(f).get("accepted_counts", {})
    except FileNotFoundError:
        return {}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--vuln-scan", required=True,
                    help="trivy k8s --scanners vuln -f json output")
    p.add_argument("--posture-scan", required=True,
                    help="trivy k8s --scanners misconfig,rbac -f json output")
    p.add_argument("--baseline", required=True,
                    help="e.g. /path/to/repo/security/baseline/live-cluster.json")
    p.add_argument("--out", required=True, help=".prom file to write")
    p.add_argument("--update-baseline", action="store_true",
                    help="write this run's counts back as the accepted baseline "
                         "(use once to seed it, or after deliberately accepting a rise)")
    args = p.parse_args()

    accepted = load_accepted_counts(args.baseline)
    print(f"accepted baseline counts from {args.baseline}: {accepted or '(none yet)'}")

    fixable = {"CRITICAL": 0, "HIGH": 0}
    all_findings = []
    seen = set()

    with open(args.vuln_scan) as f:
        vuln_report = json.load(f)
    for finding_id, severity, fixed, _kind in walk_findings(vuln_report):
        if not finding_id:
            continue
        key = (finding_id, severity)
        if key in seen:
            continue
        seen.add(key)
        if severity in fixable and fixed:
            fixable[severity] += 1
        all_findings.append((finding_id, severity))

    # "New" = how many MORE fixable CVEs than the accepted baseline, summed
    # across severities. Never negative: fixing things must not read as a
    # deficit, and this metric drives an alert that fires on > 0.
    new_count = sum(
        max(0, fixable[sev] - int(accepted.get(sev, 0)))
        for sev in ("CRITICAL", "HIGH")
    )

    if args.update_baseline:
        with open(args.baseline, "w") as f:
            json.dump({
                "target": "live-cluster",
                "generated": datetime.date.today().isoformat(),
                "accepted_counts": {k: fixable[k] for k in ("CRITICAL", "HIGH")},
            }, f, indent=2)
            f.write("\n")
        print(f"baseline updated: {fixable}")

    # Posture is reported, not baselined -- see module docstring.
    with open(args.posture_scan) as f:
        posture_report = json.load(f)
    posture_findings = []
    posture_seen = set()
    for finding_id, severity, _fixed, _kind in walk_findings(posture_report):
        if not finding_id or (finding_id, severity) in posture_seen:
            continue
        posture_seen.add((finding_id, severity))
        posture_findings.append((finding_id, severity))

    now = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    lines = [
        "# HELP homeserver_vuln_fixable_total Live-cluster image CVEs with a fix available, by severity.",
        "# TYPE homeserver_vuln_fixable_total gauge",
        f'homeserver_vuln_fixable_total{{severity="critical"}} {fixable["CRITICAL"]}',
        f'homeserver_vuln_fixable_total{{severity="high"}} {fixable["HIGH"]}',
        "# HELP homeserver_vuln_new_total Fixable live-cluster image CVEs ABOVE the accepted baseline count -- the alertable one.",
        "# TYPE homeserver_vuln_new_total gauge",
        f"homeserver_vuln_new_total {new_count}",
        "# HELP homeserver_vuln_scan_last_success_timestamp_seconds Unix time of the last successful nightly vuln scan.",
        "# TYPE homeserver_vuln_scan_last_success_timestamp_seconds gauge",
        f"homeserver_vuln_scan_last_success_timestamp_seconds {now}",
    ]
    tmp = f"{args.out}.tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.rename(tmp, args.out)  # write-then-rename: the collector must never read a half-written file

    print(f"fixable image CVEs: CRITICAL={fixable['CRITICAL']} HIGH={fixable['HIGH']}")
    print(f"accepted:           CRITICAL={accepted.get('CRITICAL', 0)} HIGH={accepted.get('HIGH', 0)}")
    print(f"above baseline (alertable): {new_count}")
    print(f"total distinct CVE IDs seen in the live cluster: {len(all_findings)}")
    print(f"live posture findings (misconfig/rbac, reported not baselined): {len(posture_findings)}")
    for finding_id, severity in sorted(posture_findings)[:20]:
        print(f"  POSTURE [{severity}] {finding_id}")
    if len(posture_findings) > 20:
        print(f"  ... and {len(posture_findings) - 20} more")


if __name__ == "__main__":
    main()
