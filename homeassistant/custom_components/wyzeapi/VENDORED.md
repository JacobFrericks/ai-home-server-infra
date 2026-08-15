# Vendored: Wyze (`wyzeapi`)

This directory is a **vendored copy** of a third-party Home Assistant custom
integration, committed here so the Wyze setup is self-contained and
version-pinned (no reliance on the upstream repo staying available, no download
at rebuild time).

- **Upstream:** https://github.com/SecKatie/ha-wyzeapi
- **Pinned commit:** `815d4b16ae7524a491b4fe6bb20d653f8a10b99a` (release `v0.1.39`)
- **License:** Apache 2.0 (see `LICENSE` in this directory)

## Why this exists

We own a handful of first-generation **Wyze Bulb (WLPA19)** units, activated
2019. They are white-only bulbs with tunable color temperature (the "orange"
look is just the warm ~2700K end) — not RGB. These are legacy devices that will
be **migrated to self-hosted/local products over time**; this integration exists
to keep them working in the interim, not as a long-term direction.

## Important caveats

- **Cloud-only, not local.** Wyze bulbs speak no local protocol — no mDNS, no
  SSDP, no Matter — which is why Home Assistant's auto-discovery never finds
  them despite the bulbs sitting on the LAN. This integration drives Wyze's
  **unofficial cloud API** (`iot_class: cloud_polling`). Every command round-
  trips through Wyze's servers, so the bulbs go unavailable if Wyze's cloud is
  down or if Wyze revokes API access. Treat that as expected behavior, not a bug.
- **Credentials are NOT stored in this repo.** This repository is public. The
  integration needs a Wyze email, password, Key ID, and API Key; all four are
  entered **once through the Home Assistant UI config flow**, after which they
  live only in HA's `.storage` (outside this repo). `scripts/setup-wyze.sh`
  deliberately does no credential handling.
- API keys are generated at https://developer-api-console.wyze.com/.
- The manifest pulls `wyzeapy>=0.6.1,<0.7` and `websockets` at HA startup into
  `/config/deps`; the HA container needs outbound internet on first load.

## How it is installed

`scripts/setup-wyze.sh` copies this directory into the live HA config's
`custom_components/` and restarts the container. The config entry is then
created by hand in the HA UI (Settings → Devices & Services → Add Integration →
Wyze), because the credentials must not be scripted into a public repo.

To update: re-vendor from a newer upstream commit and bump the pinned SHA above
(review the diff first).
