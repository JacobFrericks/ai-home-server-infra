# Disaster recovery — rebuild from nothing

This is the runbook for bringing the stack back when you have **only the git
repo** (fresh machine, or the runtime state is gone). Everything committed here is
reproducible with `./deploy.sh` + the `scripts/setup-*.sh` provisioners; the parts
that are **not** in git — the `open-webui` volume, `.env`, and a few other
server-only secrets — must be restored from backup or recreated by hand. The value
of this document is the **ordering**: a from-scratch rebuild hits several
bootstrap dependencies that fail confusingly if done out of order. See `README.md`
for the live design; nothing here changes it.

## What's reproducible vs runtime-only

| Thing | In git? | How it comes back |
|-------|---------|-------------------|
| Services, pinned images, GPU/network config | ✅ | `docker-compose.yml` → `./deploy.sh` |
| `generate` tool connection, gemma4:12b model + params, both OWUI filters, HA config entries | ✅ (as code) | `scripts/setup-image-gen.sh`, `scripts/setup-ha-owui-bridge.sh` (idempotent) |
| SDXL checkpoint, gemma4:12b pull | ✅ (as steps) | `setup-image-gen.sh` re-downloads |
| Open WebUI users, chat history, uploaded images, the config DB | ❌ | `open-webui` volume (restore, or lost) |
| `WEBUI_SECRET_KEY`, `OWUI_USER_ID`, `OWUI_PUBLIC_URL` | ❌ | `.env` (from `.env.example`) |
| SearXNG secret, monitoring secrets, HA token | ❌ | `searxng/settings.yml`, `monitoring/.env`, `monitoring/prometheus/ha_token` |
| Other Ollama models (gemma4:31b, …) | ❌ (large) | `ollama pull <model>` |

Server-only (git-ignored) files that must exist before things work: `.env`,
`searxng/settings.yml`, `monitoring/.env`, `monitoring/prometheus/ha_token`.

## Path A — restore from backup (preferred)

If you have a backup of the `open-webui` volume **and** the matching `.env`:

1. Recreate the external volume and restore into it:
   ```
   docker volume create open-webui
   docker run --rm -v open-webui:/data -v "$PWD":/backup alpine \
     tar xzf /backup/open-webui-YYYY-MM-DD.tar.gz -C /data
   ```
2. Put back `.env` — its `WEBUI_SECRET_KEY` **must be the one this volume was
   created with** (see the secret-key note below), and the other server-only
   secret files.
3. `./deploy.sh`.
4. The `setup-*.sh` scripts are idempotent — run them to reconcile, but with a
   restored volume they are essentially no-ops.

Chat history and uploaded images survive this path.

## Path B — rebuild from scratch (no volume backup)

Do these **in order** — steps 5–7 are the bootstrap dependencies:

1. **Clone the repo.** Create `.env` from `.env.example`. Generate a secret and
   record it somewhere safe (a password manager), then set the origin clients use:
   ```
   openssl rand -hex 32          # -> WEBUI_SECRET_KEY, save this
   ```
   `WEBUI_SECRET_KEY=<generated>`, `OWUI_PUBLIC_URL=http://<host>:8080`.
   Leave `OWUI_USER_ID` blank for now.
   > Do **not** leave `WEBUI_SECRET_KEY` empty. If it is, Open WebUI generates its
   > own key inside the volume, but `comfyui-mcp` would mint upload JWTs from an
   > empty key and image uploads would fail. It must be set and shared.
2. **Recreate the other server-only secrets:** `searxng/settings.yml` (from its
   `.example`, set a fresh `secret_key`), and the monitoring secrets
   (`monitoring/.env`, `monitoring/prometheus/ha_token`).
3. **Create the external Open WebUI volume** — compose will not start without it:
   ```
   docker volume create open-webui
   ```
4. **`./deploy.sh`** — services come up. Open WebUI now has **zero users**.
5. **Create the admin account.** `ENABLE_SIGNUP=false` is hard-set in compose, so
   signup is blocked even for the first user. Temporarily allow it: set
   `ENABLE_SIGNUP=true` on the `open-webui` service, `docker compose up -d
   open-webui`, open the UI and **register the first account** (the first user
   always becomes admin), then set `ENABLE_SIGNUP=false` again and recreate.
6. **Wire `OWUI_USER_ID`** (circular dependency: `comfyui-mcp` needs the admin's
   UUID, which only exists once the admin is created). Read it:
   ```
   docker exec -i open-webui python3 -c \
     "import sqlite3; print(sqlite3.connect('/app/backend/data/webui.db')\
     .execute('select id from user order by created_at limit 1').fetchone()[0])"
   ```
   Put that value in `.env` as `OWUI_USER_ID=…`, then pick it up:
   ```
   docker compose up -d --force-recreate comfyui-mcp
   ```
7. **Provision.** These require the admin to exist (they key off the first user)
   and recreate the tool connection, the gemma4:12b model, both filters, and the
   HA entries — and pull gemma4:12b + the SDXL checkpoint:
   ```
   ./scripts/setup-image-gen.sh
   ./scripts/setup-ha-owui-bridge.sh
   ```
8. **Re-pull any other models** you use: `ollama pull gemma4:31b` (chat/voice), etc.
9. **Verify:** `./scripts/verify-services.sh`.

Accepted data loss on this path: **chat history and uploaded images**. Everything
else — tools, model config, filters, HA wiring — is recreated by the scripts.

## `WEBUI_SECRET_KEY` — the one secret you must preserve

It signs Open WebUI's session tokens and the JWTs `comfyui-mcp` uses to upload
images. Two cases:

- **Restoring a volume:** the key **must match** the one the volume was created
  with. A mismatch invalidates existing sessions (users must re-login) and can
  make already-stored file URLs return 401.
- **Fresh rebuild:** generate a new one and back it up. It cannot be re-derived.

## What to back up regularly

| Backup | Why |
|--------|-----|
| `open-webui` volume (or at least `webui.db` inside it) | users, chats, tool/model/filter config, uploaded images |
| `.env` (incl. `WEBUI_SECRET_KEY`) | pair it with the volume; the key must match |
| `searxng/settings.yml` | SearXNG secret |
| HA `/config` (esp. `.storage`) | HA config entries, including the AI Task / bridge |
| `monitoring/.env`, `monitoring/prometheus/ha_token` | monitoring stack secrets |

Skip `comfyui-data` (SDXL checkpoint) and Ollama models — large and
re-downloadable by the setup script / `ollama pull`.

Volume backup command:
```
docker run --rm -v open-webui:/data -v "$PWD":/backup alpine \
  tar czf /backup/open-webui-$(date +%F).tar.gz -C /data .
```
