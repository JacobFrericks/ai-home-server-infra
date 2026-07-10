# ai-home-server-infra

Source of truth for the home server's containerized services — **Ollama,
Open WebUI, Home Assistant, Wyoming Piper (TTS), Wyoming Whisper (STT)**, and
(pending manual cutover) **Plex** — managed with a single `docker compose`
file, image bumps automated via Dependabot, and applied to the server on a
weekly self-pulling deploy loop.

The server is LAN-only behind NAT and never accepts an inbound push — it pulls
this repo itself. No secret ever lives in git.

## Services

| Service | Image | Network | Notes |
|---|---|---|---|
| ollama | `ollama/ollama:0.30.10` | host, `127.0.0.1:11434` only | GPU reservation (RTX 3090) |
| open-webui | `ghcr.io/open-webui/open-webui:v0.9.6` | host | uses `WEBUI_SECRET_KEY` |
| homeassistant | `ghcr.io/home-assistant/home-assistant:2026.2.1` | host, privileged | binds `/run/dbus`, `~/Documents/homeassistant` |
| piper | `rhasspy/wyoming-piper:2.2.2` | bridge, `:10200` | Wyoming TTS |
| whisper | `rhasspy/wyoming-whisper:3.1.0` | bridge, `:10300` | Wyoming STT |
| plex | `lscr.io/linuxserver/plex:1.43.2.10687-563d026ea-ls312` | host, `:32400` | **defined but not deployed** — gated behind the `plex-cutover` compose profile so it never starts with plain `up -d`; see [Plex cutover runbook](#plex-cutover-runbook); GPU-shared with Ollama |

## Layout

```
docker-compose.yml   # the stack (pinned images, host networking, GPU reservation)
.env.example         # placeholder; real .env lives only on the server (git-ignored)
deploy.sh            # run on the server: git pull -> compose pull -> up -d -> health check
.github/
  dependabot.yml               # opens PRs to bump the pinned image tags
  workflows/ci.yml             # validate compose + yamllint + gitleaks on every PR/push
  workflows/dependabot-automerge.yml  # auto-merge patch/minor bumps, Home Assistant excluded
```

## Secrets

`WEBUI_SECRET_KEY` is provided by a `.env` file that exists **only on the
server** (mode 600, git-ignored). `.env.example` holds a placeholder. CI's
gitleaks scan is the guardrail that keeps a real secret out of this public repo.

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

## Not automated (by design)

- NVIDIA driver / CUDA host packages (held at the OS level).
- Ollama version bumps and model pulls/prunes (manual).
- Home Assistant bumps of any size (manual review always).
- Remote/external access (future: WireGuard).

## Plex cutover runbook

The `plex` service in `docker-compose.yml` is fully authored and validated
(`docker compose config -q`) but **not started**. The native
`plexmediaserver.service` (v1.43.2) still owns `:32400` and the ~1TB library
under `/var/lib/plexmediaserver` (root/`plex`-user owned). Moving to the
containerized version requires `sudo`, which cannot be run non-interactively
over SSH — so this is a manual, on-console (or interactive-SSH) procedure.

**Do this only when ready to cut over; it is reversible until you remove the
native install's data.**

```bash
# 0. On the server, as jacob, with sudo available interactively.
cd /home/jacob/docker/ai-stack

# 1. Stop the native service (keeps files in place; nothing is deleted).
sudo systemctl stop plexmediaserver.service

# 2. Prepare the new config location for the container.
mkdir -p /home/jacob/docker/plex/config

# 3. Copy the existing library/config into it. The linuxserver image's
#    /config maps DIRECTLY to the contents of the native
#    ".../Application Support/Plex Media Server" folder (no extra nesting).
sudo rsync -aHAX --info=progress2 \
  "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/" \
  /home/jacob/docker/plex/config/

# 4. Re-own the copy to match PUID/PGID=1000 (jacob) used by the container.
sudo chown -R 1000:1000 /home/jacob/docker/plex/config

# 5. Disable and mask the native service so it can't race the container for
#    :32400 on future boots (systemctl disable alone is not enough — a
#    manual `systemctl start` or a package update could still bring it back).
sudo systemctl disable plexmediaserver.service
sudo systemctl mask plexmediaserver.service

# 6. Bring up the container. It's gated behind the "plex-cutover" profile
#    (so ordinary `docker compose up -d` / deploy.sh runs never touch it) —
#    activate the profile explicitly. It reuses :32400 on host networking.
docker compose --profile plex-cutover up -d plex

# 7. Verify.
curl -sf http://127.0.0.1:32400/identity   # should return Plex XML identity
docker compose logs -f plex                # watch for "Started Plex Media Server" and no port-bind errors
#   Then open http://<server-ip>:32400/web — libraries/claim/watch history
#   should already be intact since it's the same data, just re-owned.

# 8. Confirm GPU transcode still works: play something that needs
#    transcoding and check Settings > Dashboard for "(hw)" on the stream,
#    or watch: docker exec plex nvidia-smi (if nvidia-smi is in the image)
#    or `nvidia-smi` on the host while a transcode is running.
```

**Rollback** (if anything is wrong — missing libraries, claim issues, no
hardware transcode, etc.):

```bash
docker compose --profile plex-cutover stop plex
sudo systemctl unmask plexmediaserver.service
sudo systemctl enable --now plexmediaserver.service
curl -sf http://127.0.0.1:32400/identity   # native service back up
```

The native data under `/var/lib/plexmediaserver` is untouched by this
procedure (step 3 copies, it does not move) — only delete it once you're
confident in the container cutover and want the disk space back.
