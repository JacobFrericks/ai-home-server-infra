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
| plex | `lscr.io/linuxserver/plex:1.43.2.10687-563d026ea-ls312` | host, `:32400` | **live** — cut over from the native `.deb` on 2026-07-10 (native package since removed); config in `/home/jacob/docker/plex/config`, media bind-mounted from `/var/lib/plexmediaserver/Library`; GPU-shared with Ollama |

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
