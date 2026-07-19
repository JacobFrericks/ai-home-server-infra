# Incident: generated images not rendering in Conduit (2026-07-19)

This is a **historical record** of why Open WebUI image generation did not work in
the [Conduit](https://github.com/cogwheel0/conduit) Android client, and what was
done to fix it. It is kept for posterity — not current setup docs (see the repo
`README.md`, "Image generation", for the live design). Nothing here needs to be
re-done; the fix is already deployed and codified in `comfyui-mcp/`, `scripts/`,
and `docker-compose.yml`.

## Symptom

Asking the `gemma4:12b` image model to "generate an image of X" from Conduit
produced **no image**. The same model + tool worked in the Open WebUI browser UI.
Over several test rounds the failure mode changed as each layer was fixed,
eventually surfacing as `Error: Tool "generate_image" not found.`

## TL;DR

**Four independent bugs stacked on top of each other.** Two were server-side
delivery/rendering problems; two were Conduit client behaviors that had to be
worked around on the server because the client can't be changed from here.

| # | Failure | Layer | Fix |
|---|---------|-------|-----|
| 1 | Broken image icon | Delivery | MCP uploads PNG, returns an **absolute** URL |
| 2 | Prose reply, no image at all | Rendering | **Outlet filter** injects the image into the rendered message |
| 3 | First call: `Tool "generate_image" not found` | Tool routing | Rename so the tool **registers as `generate_image`** |
| 4 | Follow-up call: same error | Tool attachment | **Inlet filter** re-attaches the model's tools |

## Root causes and fixes, in the order they were found

### 1. Relative image URL renders broken in Conduit

The MCP tool originally returned the generated image as raw MCP image content.
Open WebUI stored it and referenced it by a **relative** URL
(`/api/v1/files/<id>/content`). The browser resolves that against its origin and
sends a `token` cookie, so it renders there. Conduit hands tool-call image URLs to
its image widget **without** resolving them against the server base, so a relative
URL loads as a broken image.

**Fix:** `comfyui-mcp` now uploads the PNG to Open WebUI's files API (authenticated
with a short-lived JWT minted from `WEBUI_SECRET_KEY`) and returns a markdown image
with an **absolute, same-origin** URL
(`![](http://<host>:8080/api/v1/files/<id>/content)`). That renders in both the
browser (cookie) and Conduit (which attaches an `Authorization: Bearer` header to
same-origin image requests). Requires `OWUI_UPLOAD_URL`, `OWUI_PUBLIC_URL`,
`OWUI_USER_ID`, `WEBUI_SECRET_KEY` on the `comfyui-mcp` service.

### 2. The image lived in the tool result, not the visible message

With delivery fixed, Conduit still showed only a prose sentence and no image. The
image markdown was in the assistant message's `output` array as a
`function_call_output` (the collapsed "View Result" panel), **not** in the surface
a client renders. Open WebUI never copies it out, and the model cannot be relied on
to echo the URL (gemma refuses to reproduce it, and often flatly hallucinates
"I cannot generate images, I am a text-based model").

**Fix:** a new **outlet filter** `render_tool_images` (`scripts/render_tool_images.py`).
After each completion it scans the tool outputs for a files-API image URL and, if
missing from the rendered text, appends the markdown into the message's
`output_text`. One subtlety cost real time: Open WebUI only persists an edited
`output` when it's a **different object** (a value comparison), so the filter must
`deepcopy` the array and reassign — mutating in place is silently dropped.

### 3. First tool call: `Tool "generate_image" not found`

The model's tool call named the bare `generate_image`, but Open WebUI had
registered the tool as `comfyui_image_generate_image` and routes by exact match, so
it 404'd. Open WebUI **always** registers an MCP tool as
`{connection_id}_{mcp_tool_name}`. Two things conspire:

- In **prompt-based ("legacy") tool calling**, the small model free-forms the tool
  name as text and drops what looks like a namespace prefix — turning
  `comfyui_image_generate_image` into `generate_image`.
- Conduit forces this legacy mode on some requests regardless of the model's
  `function_calling: native` setting.

Diagnosis used a small **logging reverse-proxy inserted between Open WebUI and
Ollama** (plus JWT-minted self-test requests) to capture the exact tool spec sent
to the model and the name it emitted. This also surfaced an unrelated gotcha: Open
WebUI reads the Ollama URL from a persisted **DB** value (`ollama.base_urls`), not
the `OLLAMA_BASE_URL` env var, so redirecting it required a DB edit, not a compose
change.

**Fix:** make the registered name equal what the model emits in **both** modes.
The model always emits `generate_image` (the canonical name), so the tool is
registered as exactly that:

- MCP tool renamed `generate_image` → **`image`** (`@mcp.tool(name="image")`; the
  Python function keeps its readable name, and Open WebUI still invokes the server
  by the raw name `image`).
- Connection id `comfyui_image` → **`generate`**.
- `{connection_id}_{tool_name}` = `generate` + `image` = **`generate_image`** ✓

`function_calling: native` is kept as belt-and-suspenders for clients that honour
it, but the naming is what makes it robust when they don't.

### 4. Follow-up tool call: same `not found` error

After #3, the **first** generation worked, but any follow-up ("make it blue")
failed with the same error. Temporary `tool_ids` logging in the middleware caught
it red-handed:

```
first request:  tool_ids=['server:mcp:generate']   -> worked
follow-up:      tool_ids=None                       -> "not found"
```

**Conduit only sends the model's `tool_ids` on the first message of a chat**, and
Open WebUI never falls back to a model's stored `meta.toolIds` server-side — so a
follow-up arrives with no tools, the model still tries to call `generate_image`,
and it 404s.

**Fix:** a new **inlet filter** `ensure_model_tools` (`scripts/ensure_model_tools.py`).
It runs before Open WebUI resolves tools and re-attaches the model's configured
`toolIds` when the request omits them. Internal task requests (title / tag /
follow-up / autocomplete generation) set `metadata['task']` and are skipped, so
those keep running tool-free.

## Which of these are Conduit bugs

Two of the four are upstream Conduit behaviors, worked around on the server:

- **#1** — doesn't resolve relative tool-call image URLs against the server base.
- **#3** — forces legacy prompt-based tool calling, where the small model mangles a
  namespaced tool name. (#4's follow-up `tool_ids` drop is the same class of
  client-side tool-handling gap.)

The server-side workarounds (absolute URLs, the naming strategy, and the two
filters) mean the fix holds regardless of whether Conduit ever changes.

## How to reproduce the fix from nothing

Everything is idempotent and codified:

```
./deploy.sh                    # services
./scripts/setup-image-gen.sh   # image-gen wiring incl. both filters
```

`setup-image-gen.sh` installs both filters via the generic
`scripts/openwebui-install-filter.py`. Diagnostic scaffolding used during the
investigation (the Ollama proxy, temporary middleware logging) was all removed;
none of it persists.

## Verification performed

- Renamed MCP tool `image` generates + uploads an absolute URL end to end.
- Native self-test: model emits exactly `generate_image` → routes.
- Legacy self-test (`function_calling: legacy`): model emits `generate_image`.
- Follow-up self-test (request with **no** `tool_ids`): inlet filter re-attaches
  `server:mcp:generate`; the model's call routes.
- On-device: first generation **and** a follow-up edit both render in Conduit.
