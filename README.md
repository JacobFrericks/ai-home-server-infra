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
homeassistant/
  custom_components/comfyui_generator/  # VENDORED HA AI Task integration (pinned; see VENDORED.md)
scripts/
  setup-image-gen.sh        # idempotent provisioning for image gen (the "start over" button)
  openwebui-image-gen.py    # Open WebUI DB wiring (tool + gemma4:12b model)
  ha-image-gen-config.py    # inject the HA ComfyUI AI Task config entry (root)
  setup-ha-owui-bridge.sh   # idempotent: let Open WebUI control HA (the "start over" button)
  ha-owui-bridge-config.py  # enable HA's mcp_server integration (config-flow API)
  openwebui-ha-bridge.py    # Open WebUI DB wiring (home-assistant tool + gemma4:31b)
  verify-services.sh        # functional PASS/FAIL check of the whole stack
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
2. **Home Assistant** — the **AI Task → Generate Image** platform, via a
   **vendored** copy of the `comfyui_generator` integration
   (`homeassistant/custom_components/`), pointed at the same ComfyUI. HA generates
   images directly (no LLM) from automations / scripts / Assist-on-a-screen.
   *Why AI Task and not MCP:* HA's MCP client has a hard **10 s** tool-call timeout
   that SDXL generation blows past; the AI Task path has a configurable timeout
   (set to 120 s).

Data path (Open WebUI): `gemma4:12b` (tool call) → `comfyui-mcp`
(`127.0.0.1:9300/mcp`, streamable-HTTP) → `comfyui` (`127.0.0.1:8188`) → PNG.
`comfyui-mcp` then **uploads the PNG to Open WebUI's files API** and returns a
markdown image with an **absolute, same-origin** content URL
(`![](http://<host>:8080/api/v1/files/<id>/content)`).

*Why upload instead of returning the raw PNG:* returning MCP image content makes
Open WebUI store the file and reference it by a **relative** `/api/v1/files/<id>/content`
URL. That renders in the browser (which sends a `token` cookie) but **not** in the
[Conduit](https://conduit.mobile/) mobile client, which passes tool-call image URLs
to its image widget without resolving them against the server base — so a relative
URL loads as a broken image. An **absolute** same-origin URL renders in both: the
browser via its `token` cookie, and Conduit via the `Authorization: Bearer` header
it attaches to same-origin image requests. (Upstream Conduit bug as of `main`
2026-07-18; see `comfyui-mcp/server.py` header for the full rationale.)

Delivery is configured on the `comfyui-mcp` service in `docker-compose.yml` via
`OWUI_UPLOAD_URL` (internal POST target), `OWUI_PUBLIC_URL` (**must match the
origin clients use** — same-origin is required for Conduit to attach its token),
`OWUI_USER_ID`, and `WEBUI_SECRET_KEY` (the MCP mints a short-lived Open WebUI JWT
from it to authenticate the upload). `OWUI_PUBLIC_URL`/`OWUI_USER_ID` live in `.env`
(see `.env.example`). If any are unset the MCP falls back to returning inline image
content (browser-only rendering).

### One-command setup / "start over"

The Docker services are codified in `docker-compose.yml` (brought up by
`deploy.sh`). Everything else — the model pull, the SDXL checkpoint, the Open
WebUI wiring, and the HA component + config entry — is codified in one
**idempotent** script:

```
./deploy.sh                    # bring the stack up (services)
./scripts/setup-image-gen.sh   # provision image gen (re-runnable; no sudo needed)
```

`setup-image-gen.sh` is a no-op for anything already in place, so it doubles as
the rebuild button. It uses `scripts/openwebui-image-gen.py` (Open WebUI DB) and
`scripts/ha-image-gen-config.py` (HA config entry) under the hood. The subsections
below document what each step does (and how to do it by hand).

## Home Assistant control (from Open WebUI)

Open WebUI chat can **control Home Assistant** — "pause the TV", "add milk to the
shopping list", and (once you add smart devices) "turn off the lights". This is
the mirror image of web search: instead of HA reaching out to an MCP server, HA
*exposes* one and Open WebUI consumes it.

- **HA side:** the built-in **`mcp_server`** integration exposes HA's `assist`
  toolset over **Streamable HTTP at `/api/mcp`** (HA 2026.7+). Turn/media/list
  intents for every Assist-*exposed* entity become MCP tools (`HassTurnOn`,
  `HassMediaPause`, `HassListAddItem`, …).
- **Open WebUI side:** a bearer-authed `home-assistant` MCP tool server pointed at
  `http://127.0.0.1:8123/api/mcp`, attached to the **`gemma4:31b`** model (which
  keeps its `searxng-web` tool). Auth uses a **dedicated** HA long-lived token
  ("Open WebUI MCP"), minted at setup and stored only in Open WebUI's DB.

Scope follows HA's Assist exposure: only exposed entities are controllable. New
smart devices show up automatically once integrated into HA and exposed to Assist
— no further wiring here.

### One-command setup / "start over"

```
./deploy.sh                          # bring the stack up (services)
./scripts/setup-ha-owui-bridge.sh    # wire OWUI -> HA control (re-runnable; no sudo)
```

`setup-ha-owui-bridge.sh` is idempotent: it enables `mcp_server`
(`scripts/ha-owui-bridge-config.py`), mints the dedicated token **only** if Open
WebUI isn't already wired, and adds the tool via `scripts/openwebui-ha-bridge.py`.
Reads the HA admin token from `$HA_TOKEN` or the prometheus `ha_token`.

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

### SDXL checkpoint (`setup-image-gen.sh` step 2)

The `sd_xl_base_1.0.safetensors` checkpoint (~6.9 GB) is downloaded into the
`comfyui-data` volume at `ComfyUI/models/checkpoints/`. The script also fixes the
first-run volume ownership (a fresh named volume is root-owned; the ComfyUI image
wants `1000:1000`). By hand:

```
docker compose up -d comfyui   # first boot installs ComfyUI + venv into the volume
docker exec -u 1000 comfyui bash -lc \
  'cd /comfy/mnt/ComfyUI/models/checkpoints && \
   curl -fL -o sd_xl_base_1.0.safetensors \
   https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors'
```

### Open WebUI wiring (`setup-image-gen.sh` step 4)

`scripts/openwebui-image-gen.py` edits the `open-webui` DB (idempotent) to add a
`comfyui-image` MCP tool server (`127.0.0.1:9300/mcp`) and a customized
`gemma4:12b` workspace model with the tool attached, **thinking off**, and
**`num_ctx` 8192** (so its KV cache stays small next to SDXL). Runtime state lives
in the `open-webui` volume, so it's scripted rather than committed. This mirrors
the SearXNG-MCP wiring; the equivalent by hand is Admin → Settings → External
Tools (add MCP server) + a workspace model with `meta.toolIds:
["server:mcp:comfyui-image"]`.

### Home Assistant wiring (`setup-image-gen.sh` step 5)

The **vendored** `comfyui_generator` AI Task integration
(`homeassistant/custom_components/comfyui_generator/`, pinned from
[Incipiens/ComfyUI-Home-Assistant](https://github.com/Incipiens/ComfyUI-Home-Assistant),
MIT — see its `VENDORED.md`) is copied into the live HA `custom_components/`,
along with `comfyui-mcp/workflow_api.json` → `/config/comfyui_workflow_api.json`.
`scripts/ha-image-gen-config.py` then creates the config entry by driving the
integration's **config flow through HA's REST API** (no root — HA does it as
itself): ComfyUI `http://127.0.0.1:8188`, that workflow, node ids **prompt=6 /
resolution=5 / seed=3**, 1024×1024, 120 s timeout. It reads the HA token from
`$HA_TOKEN` or the prometheus container (as `verify-services.sh` does).

Generate via the `ai_task.generate_image` action (automations / scripts / Assist).
The image surfaces to a dashboard `image` entity — a *screenless* voice satellite
can't show it, so target a wall tablet / dashboard.

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
- Image-gen provisioning (model pull, SDXL checkpoint, Open WebUI + HA wiring) is
  **not** part of the weekly `deploy.sh`, but it IS codified + idempotent in
  `scripts/setup-image-gen.sh` — run it once (or to rebuild). See "Image generation".
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
