# Prompts — server-only, never in git

Model system prompts live here as plain text files. **The directory is
git-ignored** (`prompts/*` with an exception for this README): the repo is
public, and a system prompt is configuration for how the assistant behaves,
not something to publish.

This mirrors the pattern `scripts/openwebui-assistant-model.py` already uses —
it copies the system prompt out of the running Open WebUI DB rather than
carrying a copy in the source.

## Required files

The setup scripts fail loudly if one of these is missing, rather than silently
installing a model with no prompt.

| File | Consumed by | Becomes |
|---|---|---|
| `image-gen-system.txt` | `scripts/openwebui-image-gen.py` (via `setup-image-gen.sh`) | `params.system` on the `gemma4:12b` image-gen model row |
| `memory-system.txt` | `scripts/openwebui-memory.py` (via `setup-memory.sh`) | appended once to the `assistant` model's `params.system` |
| `memory-recall-header.txt` | `scripts/openwebui-install-filter.py --prompt-file` (via `setup-memory.sh`) | substituted into the `memory_recall` filter source at install time, replacing the `@@RECALL_HEADER@@` token |

## Backup

These are not in git, so they are **not** covered by a `git clone` restore.
They belong in the same backup set as `.env`, `monitoring/.env`,
`monitoring/prometheus/ha_token` and `searxng/settings.yml` — see
`DISASTER-RECOVERY.md`.

If they are lost, the assistant keeps working: the prompts are also stored
inside Open WebUI's `webui.db` (in the model rows and the filter's `content`
column), so they can be recovered from a running instance or a DB backup.
