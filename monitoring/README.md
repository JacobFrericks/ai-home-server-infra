# Monitoring stack (Prometheus + Loki + Grafana)

A local observability stack for the home server: host + GPU + per-container
metrics, centralized container logs, and alert rules — headlined by a
**shared VRAM** view of the RTX 3090 (Ollama CUDA vs Plex NVENC on one 24GB
card).

This is a **separate Compose project** (`name: monitoring`) from the app
stack one directory up (`../docker-compose.yml`, project `ai-stack`). It has
its own bridge network and is brought up/torn down independently.

## Exposure policy

**Only Grafana publishes a host port** (`3000:3000`, LAN-reachable). Every
other service — Prometheus, Loki, Alloy, and all exporters — has **no
published port**; they're reachable only from other containers on the
`monitoring` bridge network by service name. Prometheus and Loki have no
built-in auth, so this is a hard rule, not a preference.

## Layout

```
monitoring/
  docker-compose.yml
  .env.example                       # copy to monitoring/.env on the server (see "Secrets")
  prometheus/
    prometheus.yml                   # scrape jobs + alert rule_files
    alerts.yml                       # alert rules (disk, VRAM, temp, targets, restarts, swap)
    ha_token                         # HA long-lived token — GIT-IGNORED, chmod 600, server-only
  loki/
    loki-config.yml                  # filesystem storage, TSDB schema, ~30d retention
  alloy/
    config.alloy                     # Docker log discovery -> Loki (River config language)
  blackbox/
    blackbox.yml                     # http_2xx + tcp_connect probe modules
  grafana/
    provisioning/
      datasources/datasources.yml    # Prometheus + Loki, provisioned
      dashboards/dashboards.yml      # file-provider pointing at dashboards/json
      dashboards/json/*.json         # dashboards below
  README.md                          # this file
```

## Services

| Service | Image | Exposure | Purpose |
|---|---|---|---|
| grafana | `grafana/grafana-oss:13.0.2` | **`3000:3000` (LAN)** | UI; provisioned datasources + dashboards |
| prometheus | `prom/prometheus:v3.13.1` | internal `9090` | metrics TSDB, 30d retention, alert rules |
| loki | `grafana/loki:3.7.3` | internal `3100` | log store, ~30d retention |
| alloy | `grafana/alloy:v1.17.1` | internal | Docker log discovery -> Loki |
| node-exporter | `prom/node-exporter:v1.11.1` | internal `9100` | host CPU/mem/disk/swap |
| cadvisor | `gcr.io/cadvisor/cadvisor:v0.55.1` | internal `8080` | per-container CPU/mem/IO/restarts |
| nvidia-gpu-exporter | `utkuozdemir/nvidia_gpu_exporter:1.10.0` | internal `9835` | GPU VRAM/util/temp/power/NVENC |
| blackbox-exporter | `prom/blackbox-exporter:v0.28.0` | internal `9115` | up/latency probes of app services |
| plex-exporter | `ajalewis/plex-media-server-exporter:v3.0.0` | internal `9922` | Plex sessions/transcode/library stats |

## Prometheus scrape jobs

Prometheus (and blackbox/plex-exporter) reach the app stack's **host-networked**
services via `host.docker.internal`, resolved through `extra_hosts:
["host.docker.internal:host-gateway"]`:

- `node-exporter`, `cadvisor`, `nvidia-gpu-exporter`, `plex-exporter` — direct
  scrapes of their own `/metrics`.
- `home-assistant` — `host.docker.internal:8123/api/prometheus`, authenticated
  with `bearer_token_file: /etc/prometheus/ha_token`.
- `blackbox-http` — `http_2xx` probes of `open-webui:8080/health` and
  `plex:32400/identity`.
- `blackbox-tcp` — `tcp_connect` probes of `piper:10200` and `whisper:10300`.
- Ollama has no `/metrics` endpoint at all — its load is visible via the GPU
  exporter and cAdvisor's per-container stats instead.

No Alertmanager is deployed in v1: alert rules evaluate and show up in
Prometheus/Grafana's own Alerting UI, but nothing routes/notifies anywhere
yet (no email/Slack/etc.). That's a natural v2 addition if wanted.

## Dashboards (provisioned as JSON, survive redeploys)

All auto-provisioned into the "Home Server" folder:

- **Node Exporter Full** (grafana.com dashboard 1860)
- **cAdvisor** (grafana.com dashboard 14282)
- **nvidia_gpu_exporter** (grafana.com dashboard 14574)
- **Home Assistant** (custom) — scrape up/down, entity availability, unavailable
  entities table, temperature/humidity/binary-sensor series, HA process CPU/RSS.
- **Container Logs (Loki)** (custom) — per-container log volume + a live logs
  panel, filterable by a `container` template variable.
- **Shared GPU / VRAM (Ollama vs Plex)** (custom) — the headline panel: total
  VRAM used vs the 24GB card, VRAM % gauge, GPU util/temp, Ollama-vs-Plex
  container CPU/memory, and NVENC encoder/decoder utilization.

## Alert rules (`prometheus/alerts.yml`)

- `HostDiskSpaceLow` — root filesystem >85% full for 10m.
- `HostSustainedSwapUsage` — swap usage >20% for 15m.
- `GpuVramNearCapacity` — combined VRAM usage >90% of the 24GB card for 5m.
- `GpuHighTemperature` — GPU >80C for 5m.
- `TargetDown` / `BlackboxProbeFailing` — any scrape target or probe down for 5m.
- `ContainerRestartLoop` — a container's start time has changed >2 times in 15m.

## Secrets

Compose resolves `${VAR}` interpolation and its default `.env` file **relative
to the directory of the compose file passed via `-f`** — not the working
directory the command is run from (verified empirically). Since we always run
`docker compose -f monitoring/docker-compose.yml ...` from the repo root,
that means monitoring's secrets live in **`monitoring/.env`**, a *different*
file from the app stack's root `.env`.

1. **`monitoring/.env`** (copy from `monitoring/.env.example`, chmod 600,
   git-ignored):
   - `GRAFANA_ADMIN_PASSWORD` — Grafana admin login.
   - `PLEX_TOKEN` — read from the running Plex container:
     ```
     docker exec plex cat "/config/Library/Application Support/Plex Media Server/Preferences.xml" \
       | grep -o 'PlexOnlineToken="[^"]*"'
     ```
2. **`monitoring/prometheus/ha_token`** (chmod 600, git-ignored) — a Home
   Assistant long-lived access token, used as a plain bearer token file (not
   an env var) by the `home-assistant` scrape job.

Both files must exist on the server **before** `docker compose -p monitoring
up -d` is run — `deploy.sh` checks for them and skips the monitoring stack
with a warning if either is missing, so a fresh clone never fails a deploy
over it.

### Home Assistant integration

Add to `/home/jacob/Documents/homeassistant/configuration.yaml` (jacob-owned,
no sudo needed):

```yaml
prometheus:
```

Then restart the container once to load it: `docker restart homeassistant`.

**Token rotation:** HA UI -> Profile -> Security -> Long-Lived Access Tokens
-> delete the old one, create a new one -> overwrite
`monitoring/prometheus/ha_token` on the server (keep it `chmod 600`) ->
`docker compose -p monitoring -f monitoring/docker-compose.yml restart prometheus`.

## Plex exporter

The plan's suggested image, `jsclayton/prometheus-plex-exporter`, ships **no
versioned tag** on either Docker Hub or GHCR — only `latest`/`main` — which
fails the "pin every image to an explicit tag" rule and isn't something to
build a long-lived scrape job on. `ctrox/plex_exporter` was checked too and
is stale (last published 2019, `latest`-only). Instead this stack uses
**`ajalewis/plex-media-server-exporter`**, which ships real semver tags on
Docker Hub (`v3.0.0` current, actively published), takes `PLEX_SERVER` +
`PLEX_TOKEN` env vars directly, and exposes metrics on `:9922` — a clean fit
for the existing `host.docker.internal` + `.env` pattern. It was not dropped;
NVENC (via the GPU exporter) and cAdvisor remain the fallback signal for
transcode load regardless.

## Deploy

Folded into the top-level `deploy.sh` (step 2b): if `monitoring/.env` and
`monitoring/prometheus/ha_token` both exist, it runs
`docker compose -p monitoring -f monitoring/docker-compose.yml pull && up -d`
right after the app stack. Otherwise it logs a warning and skips — so the
weekly cron and any fresh clone never fail over a missing secret file.

Manual bring-up from the repo root:

```bash
cd /home/jacob/docker/ai-stack
docker compose -p monitoring -f monitoring/docker-compose.yml up -d
```

Firewall: `sudo ufw allow 3000/tcp` (Grafana only — everything else stays off
the LAN by design).

## Update automation

Dependabot watches `monitoring/docker-compose.yml`'s pinned tags via a
second `docker-compose` entry (directory `/monitoring`) in
`../.github/dependabot.yml`. CI validates both compose files and yamllints
the monitoring YAML on every PR/push. The existing auto-merge policy
(`../.github/workflows/dependabot-automerge.yml`) already applies here
unchanged: patch/minor bumps auto-merge once CI is green, all majors stay
open for manual review.
