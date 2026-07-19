# Vendored: ComfyUI AI Task (`comfyui_generator`)

This directory is a **vendored copy** of a third-party Home Assistant custom
integration, committed here so the image-generation setup is self-contained and
version-pinned (no reliance on the upstream repo staying available, no download
at rebuild time).

- **Upstream:** https://github.com/Incipiens/ComfyUI-Home-Assistant
- **Pinned commit:** `346d62e892c0e182aad79a8d03df2dc9b1da0f87`
- **License:** MIT © 2025 Adam Conway (see `LICENSE` in this directory)

It exposes an **AI Task → Generate Image** entity backed by a local ComfyUI
server. We use it (instead of driving ComfyUI through the `comfyui-mcp` MCP
tool) because Home Assistant's MCP client has a hard **10 s** tool-call timeout,
which SDXL generation exceeds; the AI Task path has a configurable timeout
(we set 120 s). See the repo README, "Image generation".

`scripts/setup-image-gen.sh` copies this directory into the live HA config's
`custom_components/` and creates the matching config entry
(`scripts/ha-image-gen-config.py`, which drives the config flow via HA's REST
API — no root). To update: re-vendor from a newer upstream commit and bump the
pinned SHA above (review the diff first).
