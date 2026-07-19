# ai-home-server-infra

Source of truth for the home server's containerized services — **Ollama,
Open WebUI, SearXNG (web search), Home Assistant, Wyoming Piper (TTS), Wyoming
Whisper (STT)**, and **Plex** — managed with a single `docker compose` file,
image bumps automated via Dependabot, and applied to the server on a weekly
self-pulling deploy loop.

The server is LAN-only behind NAT and never accepts an inbound push — it pulls
this repo itself. No secret ever lives in git.

## Services

| Service | Image | Network | Notes |
|---|---|---|---|
| ollama | `ollama/ollama:0.31.2` | host, `127.0.0.1:11434` only | GPU reservation (RTX 3090) |
| open-webui | `ghcr.io/open-webui/open-webui:v0.10.2` | host | uses `WEBUI_SECRET_KEY`; web search via the `searxng-mcp` MCP tool (native web search disabled) |
| searxng | `searxng/searxng:2026.7.11-62a1ab7ed` | bridge, `127.0.0.1:8888` only | private metasearch that backs the `searxng-mcp` server; loopback-only, no API keys |
| searxng-mcp | `isokoliuk/mcp-searxng:1.11.0` | host, `127.0.0.1:9200` only | MCP server wrapping SearXNG as tools for **both** the Open WebUI chat and the HA voice agent; streamable-HTTP at `/mcp`, loopback-only |
| comfyui | `mmartial/comfyui-nvidia-docker:ubuntu24_cuda13.1-20260605` | bridge, `127.0.0.1:8188` only | SDXL text-to-image backend for **image generation**; GPU-shared (RTX 3090); loopback-only, no auth; `--normalvram` (free-between-gens). SDXL checkpoint is a manual download |
| comfyui-mcp | `comfyui-mcp:local` (built from `./comfyui-mcp`) | host, `127.0.0.1:9300` only | MCP server exposing `generate_image` (drives ComfyUI); attached to the **`gemma4:12b`** Open WebUI model; streamable-HTTP at `/mcp`, loopback-only |
| homeassistant | `ghcr.io/home-assistant/home-assistant:2026.7.1` | host, privileged | binds `/run/dbus`, `~/Documents/homeassistant` |
| piper | `rhasspy/wyoming-piper:2.2.2` | bridge, `:10200` | Wyoming TTS |
| whisper | `rhasspy/wyoming-whisper:3.5.0` | bridge, `:10300` | Wyoming STT |
| plex | `lscr.io/linuxserver/plex:1.43.2.10687-563d026ea-ls312` | host, `:32400` | **live** — cut over from the native `.deb` on 2026-07-10 (native package since removed); config in `/home/jacob/docker/plex/config`, media bind-mounted from `/var/lib/plexmediaserver/Library`; GPU-shared with Ollama |

## Layout

```
docker-compose.yml   # the stack (pinned images, host networking, GPU reservation)
.env.example         # placeholder; real .env lives only on the server (git-ignored)
searxng/
  settings.yml.example  # tracked template; real searxng/settings.yml is git-ignored (server-only)
comfyui-mcp/         # locally-built MCP server for image generation (Dockerfile + server.py)
  workflow_api.json     # SDXL text-to-image graph (API format) — shared by the MCP tool and HA
deploy.sh            # run on the server: git pull -> compose pull -> up -d -> health check
.github/
  dependabot.yml               # opens PRs to bump the pinned image tags
  workflows/ci.yml             # validate compose + yamllint + gitleaks on every PR/push
  workflows/dependabot-automerge.yml  # auto-merge patch/minor bumps, Home Assistant excluded
monitoring/
  docker-compose.yml           # SEPARATE compose project ("monitoring"): Prometheus + Loki
                                #   + Grafana + exporters. See monitoring/README.md.
```

## Web search (SearXNG via MCP)

Both AI surfaces — the **Open WebUI chat** and the **Home Assistant voice
assistant** — get internet access the same way: the model calls a
`searxng_web_search` tool exposed by the **`searxng-mcp`** MCP server, which
queries a self-hosted **SearXNG** metasearch instance. No third-party API keys,
no queries sent to a search-aggregator account, and **no per-chat toggle** — the
model decides when to search. Only the **`gemma4:31b`** model is wired for this.

Data path: `gemma4:31b` (tool call) → `searxng-mcp` (`127.0.0.1:9200/mcp`,
streamable-HTTP) → `searxng` (`127.0.0.1:8888`) → public search engines.

### SearXNG backend

- **Loopback only:** SearXNG publishes `127.0.0.1:8888` and searxng-mcp
  `127.0.0.1:9200` — never on the LAN, so no ufw rule is needed. Only outbound
  traffic is SearXNG → public search engines.
- **JSON format is required:** `searxng/settings.yml` sets
  `search.formats: [html, json]`. Without `json`, SearXNG returns **HTTP 403**.
  The rate limiter is off (`server.limiter: false`) — fine for a single local
  user, so no redis/valkey sidecar is needed.
- **Secret / config:** `searxng/settings.yml` is **git-ignored** (holds a real
  `server.secret_key`) and lives only on the server; the tracked template is
  `searxng/settings.yml.example`. Being git-ignored, it survives `deploy.sh`'s
  `git reset`-style pull. (Re)create it:
  `cp searxng/settings.yml.example searxng/settings.yml && sed -i "s/ultrasecretkey/$(openssl rand -hex 32)/" searxng/settings.yml`.

### Open WebUI wiring (runtime state in the `open-webui` DB, not in git)

Native web search is **disabled** (`web.search.enable=false`) so MCP is the only
path. Config lives in the `open-webui` named volume (`webui.db`); to reproduce:

1. **Admin → Settings → External Tools** → add server, type *MCP (Streamable
   HTTP)*, URL `http://127.0.0.1:9200/mcp`, auth *None* (stored in the
   `tool_server.connections` config with `info.id: searxng-web`).
2. **Make it always-on:** the `gemma4:31b` workspace model has the tool set as a
   default (`meta.toolIds: ["server:mcp:searxng-web"]`) so it's attached to every
   chat with no toggle. Native function-calling is Open WebUI's default.
3. The model's system prompt tells it to search for current / uncertain
   questions (else it answers from memory).

### Home Assistant wiring (runtime state in HA's `.storage`, not in git)

1. **MCP Client integration** → `http://127.0.0.1:9200/mcp` (Settings → Devices
   & Services → Add Integration → *Model Context Protocol*, or a `mcp` config
   entry in `.storage/core.config_entries`). HA tries streamable-HTTP first,
   then SSE, so `/mcp` works directly — no SSE proxy needed.
2. **Grant the agent access:** MCP registers its own LLM API `mcp-<entry_id>` —
   **not** part of `assist`. The Ollama *conversation* subentry's `llm_hass_api`
   must include **both** `assist` and that `mcp-<entry_id>` id.
3. The conversation agent's system prompt was likewise extended to search for
   current / uncertain questions (verified: an un-prompted "who won the most
   recent F1 race?" triggered a live search).

## Image generation (SDXL via ComfyUI)

Local text-to-image, no cloud. A **ComfyUI** service runs **SDXL base 1.0** on the
RTX 3090; two front-ends drive the **same** ComfyUI backend:

1. **Open WebUI chat** — the **`gemma4:12b`** model calls a `generate_image` tool
   exposed by the **`comfyui-mcp`** MCP server (12b writes the prompt / decides
   when to fire; it is the orchestrator and stays warm). 12b is a *dedicated*
   image model — `gemma4:31b` (chat/voice) is untouched.
2. **Home Assistant** — the **ComfyUI-Home-Assistant** custom integration (HA's
   *AI Task → Generate Image*) points at the same ComfyUI. HA generates images
   directly (no LLM, no MCP) from automations / Assist-on-a-screen.

Data path (Open WebUI): `gemma4:12b` (tool call) → `comfyui-mcp`
(`127.0.0.1:9300/mcp`, streamable-HTTP) → `comfyui` (`127.0.0.1:8188`) → PNG
returned as MCP image content (Open WebUI re-serves it to the browser).

### VRAM: free-between-gens (why SDXL and gemma can coexist)

The 24 GB card can't hold `gemma4:31b` (~23 GB) **and** SDXL at once — which is
why the image model is **`gemma4:12b`** (~10 GB). During a generation, 12b +
SDXL ≈ 20 GB fit together; **`comfyui-mcp` POSTs `/free` after every image** so
SDXL releases the GPU immediately, leaving the ~10-20 s generation the only
window of contention. ComfyUI's default **DynamicVRAM** also unloads models to
CPU after each run (we do **not** pass `--highvram`), so even the HA path — which
doesn't call `/free` — auto-releases the GPU after generating. Caveat: an
HA-triggered generation is still a second trigger for an SDXL *load* — if it
fires while `gemma4:31b` is resident, SDXL won't fit and ComfyUI CPU-offloads
(slow, not a crash). Avoid scheduling HA image automations during heavy voice use.

### SDXL checkpoint (manual download, like Ollama model pulls)

Not automated. Place `sd_xl_base_1.0.safetensors` (~6.9 GB) into the
`comfyui-data` volume at `ComfyUI/models/checkpoints/`:

```
docker compose up -d comfyui   # first boot installs ComfyUI + venv into the volume
docker compose exec -u 0 comfyui bash -lc \
  'cd /comfy/mnt/ComfyUI/models/checkpoints && \
   curl -fL -o sd_xl_base_1.0.safetensors \
   https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors'
```

### Open WebUI wiring (runtime state in the `open-webui` DB, not in git)

Mirrors the SearXNG-MCP wiring:

1. **Admin → Settings → External Tools** → add server, type *MCP (Streamable
   HTTP)*, URL `http://127.0.0.1:9300/mcp`, auth *None*.
2. Create a **`gemma4:12b`** workspace model; attach the tool as a default
   (`meta.toolIds: ["server:mcp:comfyui-image"]`) so it's always on.
3. **Disable thinking** for this model and keep **native function calling** on
   (reliable tool-call emission), and **pin `num_ctx`** (e.g. 8192) so the KV
   cache stays small alongside SDXL. A short `keep_alive` avoids 12b lingering.

### Home Assistant wiring (runtime state in HA config, not in git)

The **ComfyUI-Home-Assistant** custom integration is local-only (no API key):

1. Install into `~/Documents/homeassistant/custom_components/` (no HACS is
   installed — drop the component in and restart the `homeassistant` container).
2. Add the integration (Settings → Devices & Services): **ComfyUI URL**
   `http://127.0.0.1:8188` (HA is host-networked, so loopback reaches ComfyUI),
   and the **workflow JSON** — export the SDXL graph from ComfyUI via *Save
   (API)*, or use `comfyui-mcp/workflow_api.json`. Set a generous timeout.
3. Generate via the `ai_task.generate_image` action (automations / scripts /
   Assist). The image surfaces to a dashboard `image` entity — a *screenless*
   voice satellite can't show it, so target a wall tablet / dashboard.

## Secrets

`WEBUI_SECRET_KEY` is provided by a `.env` file that exists **only on the
server** (mode 600, git-ignored). `.env.example` holds a placeholder. The
SearXNG secret lives in the git-ignored `searxng/settings.yml` (see above).
CI's gitleaks scan is the guardrail that keeps a real secret out of this public
repo.

## Deploy model

- **When:** a weekly cron entry runs `deploy.sh` (Sundays 04:30 server time).
- **What it does:** `git pull --ff-only` (skipped until a git remote is
  configured), then `docker compose pull && up -d`, a health check, and an image
  prune. Only changed services are recreated.
- **Manual run:** `cd /home/jacob/docker/ai-stack && ./deploy.sh`.
- **Rollback:** `git reset --hard <previous-sha> && ./deploy.sh`.

## Update automation

Dependabot watches the `image:` tags and opens bump PRs. CI validates them.
`dependabot-automerge.yml` auto-merges **any patch/minor bump** after CI is
green, **except Home Assistant** (smart-home risk stays manual regardless of
bump size). **All major bumps — including Ollama — stay open for manual
review** (GPU/inference risk). For auto-merge to fire, the repo needs "Allow
auto-merge" enabled and the CI check set as a required status check on `main`.

## Observability

A separate Grafana/Prometheus/Loki stack (`monitoring/`, project
`monitoring`) provides host + GPU + per-container dashboards, centralized
container logs, and alert rules — LAN-reachable only at `:3000` (Grafana);
everything else stays off the LAN. See `monitoring/README.md` for the full
service list, dashboards, alert rules, and secrets setup.

## Not automated (by design)

- NVIDIA driver / CUDA host packages (held at the OS level).
- Ollama version bumps and model pulls/prunes (manual).
- Home Assistant bumps of any size (manual review always).
- SDXL checkpoint download + Open WebUI/HA image-gen wiring (manual; see above).
- Remote/external access (future: WireGuard).

## Plex (containerized — cut over 2026-07-10)

Plex was migrated from the native `.deb` to this container, and the native
package has since been **removed** (`apt remove`, *not* purge). The container
owns `:32400`. Verified: server still claimed, libraries intact (Movies + TV
Shows), GPU device present for hardware transcode.

- **Config/DB:** the native `Application Support/Plex Media Server` tree was
  copied into `/home/jacob/docker/plex/config` and re-owned to uid/gid 1000.
  The LSIO image nests it, so the data lives at
  `/config/Library/Application Support/Plex Media Server/`.
- **Media:** retained at its original absolute paths and bind-mounted there
  (`/var/lib/plexmediaserver/Library/{Movies,TVShows}`, owned uid/gid 1000) so
  the DB resolves them with no re-matching; identity/claim and watch state were
  preserved.
- **GPU:** the NVIDIA device is passed through for hardware transcode (shared
  with Ollama).

> **Never `purge` `plexmediaserver`.** The media lives *inside* the old native
> data dir (`/var/lib/plexmediaserver/Library`), and the package's `postrm`
> only `rm -rf`s `/var/lib/plexmediaserver` on `purge`. The native package was
> therefore removed **non-purge**, leaving the media in place. Reinstalling and
> purging later would delete it.

The container is now the source of truth; to stop it use `docker compose stop
plex`. Falling back to a native install would mean reinstalling the package and
re-importing — not a simple `unmask` anymore.
