#!/usr/bin/env python3
"""Quiet the wyzeapi camera logger in HA's configuration.yaml.

WHY: custom_components/wyzeapi/camera.py line ~70 logs the whole exception when
a camera's `config_fetch()` fails (routine for any offline camera). That
exception message embeds Wyze's full `get_stream_info` response, which contains
LIVE AWS CREDENTIALS -- `X-Amz-Security-Token`, presigned Kinesis Video URLs, a
JWT `auth_token`, and TURN usernames/passwords. Those land in
`/config/home-assistant.log` AND get shipped to Loki by Alloy, where they
outlive their 30-minute expiry by weeks.

Setting that logger to `error` drops the offending WARNING while keeping the two
genuine `_LOGGER.error` calls in that module (JSON-decode and run_loop failures,
which log only benign text). Do NOT set this logger to `debug`: the module's
debug statements dump the same config dict and ICE server credentials.

Idempotent: adds the entry under the existing `logger:` -> `logs:` block if
absent, leaves the file untouched if already present. Run inside the HA
container (the config file is root-owned):

    docker cp scripts/ha-wyze-logging.py homeassistant:/tmp/
    docker exec homeassistant python3 /tmp/ha-wyze-logging.py
"""
import re
import sys

CONFIG = "/config/configuration.yaml"
KEY = "custom_components.wyzeapi.camera"
LEVEL = "error"
COMMENT = (
    "    # Suppress the camera config-fetch WARNING: it logs Wyze's full\n"
    "    # get_stream_info response, which embeds live AWS/TURN credentials and a\n"
    "    # JWT into home-assistant.log and Loki. Real errors still surface.\n"
)

with open(CONFIG) as f:
    lines = f.readlines()

text = "".join(lines)
if KEY in text:
    print("already configured: %s" % KEY)
    sys.exit(0)

# Locate the `logs:` mapping inside the top-level `logger:` block.
logger_at = None
for i, line in enumerate(lines):
    if re.match(r"^logger:\s*$", line):
        logger_at = i
        break

if logger_at is None:
    sys.exit("ERROR: no top-level `logger:` block in %s; refusing to guess" % CONFIG)

logs_at = None
for i in range(logger_at + 1, len(lines)):
    # Stop at the next top-level key (column 0, non-comment, non-blank).
    if re.match(r"^\S", lines[i]) and not lines[i].startswith("#"):
        break
    if re.match(r"^\s+logs:\s*$", lines[i]):
        logs_at = i
        break

if logs_at is None:
    sys.exit("ERROR: `logger:` block has no `logs:` mapping; refusing to guess")

# Insert after the last entry belonging to `logs:` (preserves existing entries).
insert_at = logs_at + 1
while insert_at < len(lines) and re.match(r"^\s{4,}\S", lines[insert_at]):
    insert_at += 1

lines.insert(insert_at, COMMENT + "    %s: %s\n" % (KEY, LEVEL))

with open(CONFIG, "w") as f:
    f.writelines(lines)

print("added: %s: %s" % (KEY, LEVEL))
