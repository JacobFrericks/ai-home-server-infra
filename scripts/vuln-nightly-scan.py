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


def load_baseline_ids(baseline_glob):
    ids = set()
    for path in glob.glob(baseline_glob):
        with open(path) as f:
            data = json.load(f)
        ids |= set(data.get("findings", {}).keys())
    return ids


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--vuln-scan", required=True,
                    help="trivy k8s --scanners vuln -f json output")
    p.add_argument("--posture-scan", required=True,
                    help="trivy k8s --scanners misconfig,rbac -f json output")
    p.add_argument("--baseline-glob", required=True,
                    help="e.g. /path/to/repo/security/baseline/images/*.json")
    p.add_argument("--out", required=True, help=".prom file to write")
    args = p.parse_args()

    baseline_ids = load_baseline_ids(args.baseline_glob)
    print(f"loaded {len(baseline_ids)} accepted image-CVE IDs from {args.baseline_glob}")

    fixable = {"CRITICAL": 0, "HIGH": 0}
    new_findings = []
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
        if finding_id not in baseline_ids:
            new_findings.append((finding_id, severity))

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
        "# HELP homeserver_vuln_new_total Live-cluster image CVEs not in security/baseline/images/*.json -- the alertable one.",
        "# TYPE homeserver_vuln_new_total gauge",
        f"homeserver_vuln_new_total {len(new_findings)}",
        "# HELP homeserver_vuln_scan_last_success_timestamp_seconds Unix time of the last successful nightly vuln scan.",
        "# TYPE homeserver_vuln_scan_last_success_timestamp_seconds gauge",
        f"homeserver_vuln_scan_last_success_timestamp_seconds {now}",
    ]
    tmp = f"{args.out}.tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.rename(tmp, args.out)  # write-then-rename: the collector must never read a half-written file

    print(f"fixable image CVEs: CRITICAL={fixable['CRITICAL']} HIGH={fixable['HIGH']}")
    print(f"new image CVEs (not in baseline): {len(new_findings)}")
    for finding_id, severity in sorted(new_findings)[:20]:
        print(f"  NEW [{severity}] {finding_id}")
    if len(new_findings) > 20:
        print(f"  ... and {len(new_findings) - 20} more")
    print(f"live posture findings (misconfig/rbac, reported not baselined): {len(posture_findings)}")
    for finding_id, severity in sorted(posture_findings)[:20]:
        print(f"  POSTURE [{severity}] {finding_id}")
    if len(posture_findings) > 20:
        print(f"  ... and {len(posture_findings) - 20} more")


if __name__ == "__main__":
    main()
