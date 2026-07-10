# ai-home-server-infra

Source of truth for the home server's local-AI stack: **Ollama + Open WebUI**,
managed with a single `docker compose` file, image bumps automated via
Dependabot, and applied to the server on a weekly self-pulling deploy loop.

The server is LAN-only behind NAT and never accepts an inbound push — it pulls
this repo itself. No secret ever lives in git.

## Layout

```
docker-compose.yml   # the stack (pinned images, host networking, GPU reservation)
.env.example         # placeholder; real .env lives only on the server (git-ignored)
deploy.sh            # run on the server: git pull -> compose pull -> up -d -> health check
.github/
  dependabot.yml               # opens PRs to bump the pinned image tags
  workflows/ci.yml             # validate compose + yamllint + gitleaks on every PR/push
  workflows/dependabot-automerge.yml  # auto-merge Open WebUI patch/minor only
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
`dependabot-automerge.yml` auto-merges **Open WebUI patch/minor** after CI is
green; **Ollama** bumps and **all major** bumps stay open for manual review
(GPU/inference risk). For auto-merge to fire, the repo needs "Allow auto-merge"
enabled and the CI check set as a required status check on `main`.

## Not automated (by design)

- NVIDIA driver / CUDA host packages (held at the OS level).
- Ollama version bumps and model pulls/prunes (manual).
- Remote/external access (future: WireGuard).
