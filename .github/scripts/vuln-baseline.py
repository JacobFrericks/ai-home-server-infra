#!/usr/bin/env python3
"""Count-only delta gate for trivy image scans in a PUBLIC repo.

Why counts, not IDs: ai-home-server-infra is public. A committed list of
"CVE-YYYY-NNNNN, CVE-YYYY-NNNNN, ..." is a precise, dated map of every
unpatched hole in a container this household runs -- a gift to anyone
looking. This script never stores or prints a specific finding ID, only
how many HIGH/CRITICAL findings exist per severity. The baseline commits
today's accepted counts; a PR fails only if a severity's count goes UP.

This is a real precision tradeoff, accepted deliberately: if one CVE gets
fixed and a different one appears in the same PR, the count can stay flat
and the new one slips through unnoticed by this gate. That's the price of
not naming anything specific in a public repo. (The sibling repo,
ai-home-server-k8s, is private and keeps the full ID-level baseline design
in its own copy of this script for its own -- non-public -- findings.)

Usage:
  vuln-baseline.py generate --scan <trivy.json> --baseline <baseline.json> --target NAME
  vuln-baseline.py check    --scan <trivy.json> --baseline <baseline.json> --target NAME
"""
import argparse
import datetime
import json
import sys
from collections import Counter

STALE_DAYS = 90


def count_by_severity(scan_path):
    with open(scan_path) as f:
        data = json.load(f)
    counts = Counter()
    for result in data.get("Results", []):
        for m in result.get("Misconfigurations") or []:
            counts[m.get("Severity", "UNKNOWN")] += 1
        for v in result.get("Vulnerabilities") or []:
            counts[v.get("Severity", "UNKNOWN")] += 1
    return dict(counts)


def load_baseline(baseline_path):
    try:
        with open(baseline_path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"target": None, "generated": None, "accepted_counts": {}}


def cmd_generate(args):
    counts = count_by_severity(args.scan)
    out = {
        "target": args.target,
        "generated": datetime.date.today().isoformat(),
        "accepted_counts": dict(sorted(counts.items())),
    }
    with open(args.baseline, "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")
    print(f"{args.target}: accepted " +
          ", ".join(f"{n} {sev}" for sev, n in sorted(counts.items())))


def cmd_check(args):
    counts = count_by_severity(args.scan)
    baseline = load_baseline(args.baseline)
    accepted = baseline.get("accepted_counts", {})

    generated = baseline.get("generated")
    if generated:
        try:
            age_days = (datetime.date.today() - datetime.date.fromisoformat(generated)).days
            if age_days > STALE_DAYS:
                print(f"WARN [{args.target}]: baseline is {age_days} days old "
                      f"(> {STALE_DAYS}) -- worth a re-look, not blocking.")
        except ValueError:
            pass

    increased = {}
    for sev, n in counts.items():
        base_n = accepted.get(sev, 0)
        if n > base_n:
            increased[sev] = (base_n, n)

    if increased:
        print(f"FAIL [{args.target}]: severity count increased vs baseline "
              f"(specific findings withheld -- this is a public repo):")
        for sev, (before, after) in sorted(increased.items()):
            print(f"  {sev}: {before} -> {after}")
        print(f"If accepted, run: python3 .github/scripts/vuln-baseline.py generate "
              f"--scan {args.scan} --baseline {args.baseline} --target '{args.target}' "
              f"and commit the updated baseline.")
        return 1

    print(f"OK [{args.target}]: " +
          ", ".join(f"{n} {sev}" for sev, n in sorted(counts.items())) +
          " -- none higher than accepted")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("generate")
    g.add_argument("--scan", required=True)
    g.add_argument("--baseline", required=True)
    g.add_argument("--target", required=True)
    g.set_defaults(func=cmd_generate)

    c = sub.add_parser("check")
    c.add_argument("--scan", required=True)
    c.add_argument("--baseline", required=True)
    c.add_argument("--target", required=True)
    c.set_defaults(func=cmd_check)

    args = p.parse_args()
    sys.exit(args.func(args) or 0)


if __name__ == "__main__":
    main()
