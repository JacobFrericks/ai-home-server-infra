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

WHY THIS ALSO PUBLISHES THE DATABASE'S OWN IDENTITY:

This scan runs against whatever vulnerability database is current that night,
deliberately -- unlike the CI gate in .github/workflows/image-scan.yml, which
pins one. Freshness is the entire point of scanning the LIVE cluster: it covers
~30 running images nobody here builds, and a pinned database would stop telling
us about real new findings in them between Renovate bumps.

The cost of not pinning is that homeserver_vuln_new_total can move with NOTHING
changed on this server -- the database simply learned something new about
packages that were already installed. That is exactly what happened on
2026-09-04 (HIGH 18 -> 53 with no commit), and on this path it means a phone
alert for something nobody did.

So rather than trade freshness away, make the two causes TELLABLE APART:
homeserver_vuln_db_updated_timestamp_seconds is when the database content was
built upstream. If the CVE count jumped and this moved on the same night, the
database is the reason; if the count jumped and this did not move, something
really did change in the cluster. In PromQL:

    changes(homeserver_vuln_db_updated_timestamp_seconds[2d]) > 0

Emitted only when trivy actually reported it -- a missing metric is honest,
whereas a 0 would read as 1970 and quietly poison any graph or comparison.
"""
import argparse
import datetime
import glob
import json
import os
import re


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


def db_timestamps(version_json_path):
    """(updated_at, downloaded_at) as unix ints from `trivy version -f json`.

    Returns (None, None) for every failure mode -- absent flag, missing file,
    malformed JSON, older trivy that omits the block. This runs inside a
    nightly cron whose real job is the CVE counts; a nice-to-have provenance
    metric must never be the reason those go unpublished.
    """
    if not version_json_path:
        return (None, None)
    try:
        with open(version_json_path) as f:
            data = json.load(f)
        db = data.get("VulnerabilityDB") or {}

        def parse(value):
            if not value:
                return None
            if not isinstance(value, str):
                return None
            text = value.strip().replace("Z", "+00:00")
            # Trivy is a Go program, so it emits RFC3339 with NANOSECOND
            # precision: "2026-09-06T12:11:07.913419471+00:00". Nine fractional
            # digits are rejected outright by datetime.fromisoformat on Python
            # < 3.11, which accepts only 3 or 6. Normalise the fraction to
            # exactly 6 digits rather than assume the interpreter version --
            # this script runs from a repo checkout on whatever python3 the
            # host has.
            match = re.search(r"\.(\d+)", text)
            if match:
                micros = (match.group(1) + "000000")[:6]
                text = f"{text[:match.start()]}.{micros}{text[match.end():]}"
            try:
                return int(datetime.datetime.fromisoformat(text).timestamp())
            except (ValueError, TypeError):
                return None

        return (parse(db.get("UpdatedAt")), parse(db.get("DownloadedAt")))
    except (OSError, ValueError) as exc:
        print(f"WARN: could not read trivy DB metadata ({exc}) -- "
              f"database provenance metrics omitted this run.")
        return (None, None)


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
    p.add_argument("--trivy-version",
                    help="`trivy version -f json` output, to publish which "
                         "vulnerability database this run actually used. "
                         "Optional: omitted or unreadable simply drops those "
                         "two metrics rather than failing the run.")
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

    # Which database produced the counts above. See the module docstring: this
    # is what separates "the cluster got worse" from "the database learned
    # something", and this scan is unpinned on purpose.
    db_updated, db_downloaded = db_timestamps(args.trivy_version)
    if db_updated is not None:
        lines += [
            "# HELP homeserver_vuln_db_updated_timestamp_seconds Unix time the trivy vulnerability DB content was built upstream -- a change here explains a CVE count move that no commit caused.",
            "# TYPE homeserver_vuln_db_updated_timestamp_seconds gauge",
            f"homeserver_vuln_db_updated_timestamp_seconds {db_updated}",
        ]
    if db_downloaded is not None:
        lines += [
            "# HELP homeserver_vuln_db_downloaded_timestamp_seconds Unix time this host last fetched the trivy vulnerability DB.",
            "# TYPE homeserver_vuln_db_downloaded_timestamp_seconds gauge",
            f"homeserver_vuln_db_downloaded_timestamp_seconds {db_downloaded}",
        ]
    tmp = f"{args.out}.tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(lines) + "\n")
    os.rename(tmp, args.out)  # write-then-rename: the collector must never read a half-written file

    print(f"fixable image CVEs: CRITICAL={fixable['CRITICAL']} HIGH={fixable['HIGH']}")
    print(f"accepted:           CRITICAL={accepted.get('CRITICAL', 0)} HIGH={accepted.get('HIGH', 0)}")
    print(f"above baseline (alertable): {new_count}")
    if db_updated is not None:
        print("vulnerability DB built upstream: "
              f"{datetime.datetime.fromtimestamp(db_updated, datetime.timezone.utc).isoformat()}"
              " (UNPINNED here on purpose -- see the module docstring)")
    else:
        print("vulnerability DB: provenance unavailable this run")
    print(f"total distinct CVE IDs seen in the live cluster: {len(all_findings)}")
    print(f"live posture findings (misconfig/rbac, reported not baselined): {len(posture_findings)}")
    for finding_id, severity in sorted(posture_findings)[:20]:
        print(f"  POSTURE [{severity}] {finding_id}")
    if len(posture_findings) > 20:
        print(f"  ... and {len(posture_findings) - 20} more")


if __name__ == "__main__":
    main()
