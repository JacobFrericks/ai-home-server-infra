#!/usr/bin/env python3
"""Assert that every container image in this repo is pinned by digest.

WHY THIS EXISTS
---------------
The 2026-08-30 supply-chain audit rated mutable image tags HIGH across both
home-server repos. At that point all four services in docker-compose.yml were
pinned to a tag and none to a digest.

A tag records what the publisher most recently CALLED an image. A digest
records what the image IS. Only the second is immutable. Two of these four
images -- `rhasspy/wyoming-piper` and `rhasspy/wyoming-whisper` -- are Docker
Hub accounts outside our control; if such an account were taken over and the
same tag re-pushed, the weekly cron `deploy.sh` would `docker compose pull`
it and run it here, as a user in the `docker` group, which is
root-equivalent. There would be no commit, no PR and no signal.

Renovate now sets `pinDigests: true` (its config lives in the sibling k8s
repo and governs this one too), so new images arrive pinned. But a bot config
can be edited and a convention nobody enforces decays back to convenience.
This is the enforcement half.

WHAT IT ASKS
------------
One structural question over composed YAML nodes -- no regex over file text,
so no false positives:

    Does every `image:` value carry an @sha256:<64 hex> digest?

Keeping BOTH tag and digest, as `repo:tag@sha256:...`, is deliberate: the tag
stays as human-readable provenance for review, and the digest is what docker
actually resolves and pulls.

A NOTE ON THIS REPO'S CI
------------------------
This repo's CI failed on EVERY run for months because it validated a compose
file deleted during the k3s migration -- a check that is always red is
indistinguishable from a check nobody reads. The mirror-image failure is a
check that is always green because it is looking at nothing. So an empty scan
here is a FAILURE, not a pass.
"""
import pathlib
import re
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parents[2]

# Anchored: a truncated or hand-typed digest fails rather than passing.
DIGEST = re.compile(r"@sha256:[0-9a-f]{64}$")

failures = []
pinned = []


def scan(path, node):
    """Walk composed nodes so every finding carries a real line number."""
    if isinstance(node, yaml.MappingNode):
        for key, value in node.value:
            if (
                isinstance(key, yaml.ScalarNode)
                and key.value == "image"
                and isinstance(value, yaml.ScalarNode)
                and isinstance(value.value, str)
                and value.value
            ):
                where = f"{path.relative_to(REPO)}:{value.start_mark.line + 1}"
                if DIGEST.search(value.value):
                    pinned.append(where)
                else:
                    failures.append((where, value.value))
            scan(path, value)
    elif isinstance(node, yaml.SequenceNode):
        for item in node.value:
            scan(path, item)


for path in sorted(REPO.rglob("*.y*ml")):
    if ".git/" in str(path):
        continue
    try:
        docs = list(yaml.compose_all(path.read_text(encoding="utf-8")))
    except yaml.YAMLError as e:
        failures.append((str(path.relative_to(REPO)), f"unparseable YAML: {e}"))
        continue
    for doc in docs:
        if doc is not None:
            scan(path, doc)

print(f"{len(pinned)} image reference(s) pinned by digest")

if failures:
    print("\nFAILED: image(s) pinned to a mutable tag:")
    for where, image in failures:
        print(f"  - {where}: {image}")
    print(
        "\nFix: append the registry digest, keeping the tag —\n"
        "    image: repo:tag@sha256:<64 hex>\n"
        "Resolve one with:\n"
        "    docker buildx imagetools inspect repo:tag "
        "--format '{{.Manifest.Digest}}'"
    )
    sys.exit(1)

if not pinned:
    print("no image references found — nothing was verified; see docstring")
    sys.exit(1)

print("OK: every image is pinned by digest")
