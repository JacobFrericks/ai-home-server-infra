#!/usr/bin/env python3
"""
comfyui-mcp — a tiny MCP server exposing a single `generate_image` tool that
drives a local ComfyUI (SDXL) instance.

Mirrors the searxng-mcp pattern in this stack: streamable-HTTP, bound on
LOOPBACK ONLY (127.0.0.1), host networking so it can reach ComfyUI at
127.0.0.1:8188 and be reached by the host-networked open-webui.

Design notes (see repo README "Image generation"):
  * gemma4:12b is the orchestrator and stays warm; this server NEVER touches
    Ollama. It only talks to ComfyUI (and, for delivery, Open WebUI's files API).
  * VRAM strategy is "free-between-gens": after each image we POST /free so
    SDXL releases the GPU (12b + SDXL only co-reside during the ~10-20s gen).
  * Delivery: when OWUI_UPLOAD_URL/OWUI_PUBLIC_URL/OWUI_USER_ID/WEBUI_SECRET_KEY
    are set, we UPLOAD the PNG to Open WebUI's files API and return a markdown
    image with an ABSOLUTE, same-origin content URL
    (`![](http://<host>:8080/api/v1/files/<id>/content)`). That absolute URL
    renders in both the browser (Open WebUI sends a `token` cookie) and the
    Conduit mobile client (it attaches the Bearer header for same-origin URLs).
    The older path — returning MCP image content and letting Open WebUI re-serve
    it — produces a RELATIVE `/api/v1/files/<id>/content` URL that Conduit does
    not resolve against the server base, so it renders a broken image there.
    If upload is not configured or fails, we fall back to that inline PNG.
  * Inputs are clamped server-side (SDXL native <=1024 buckets, capped steps)
    so a large request can't spike VAE-decode VRAM past the ~4 GB headroom.
"""
import os
import time
import json
import base64
import hmac
import hashlib
import random
import urllib.parse

import httpx
from mcp.server.fastmcp import FastMCP, Image

COMFYUI_URL = os.environ.get("COMFYUI_URL", "http://127.0.0.1:8188").rstrip("/")
CHECKPOINT = os.environ.get("SDXL_CHECKPOINT", "sd_xl_base_1.0.safetensors")
HOST = os.environ.get("MCP_HTTP_HOST", "127.0.0.1")
PORT = int(os.environ.get("MCP_HTTP_PORT", "9300"))
POLL_TIMEOUT = int(os.environ.get("GEN_TIMEOUT", "180"))  # seconds

# Open WebUI delivery (optional). When all four are set, generated images are
# uploaded to Open WebUI and returned as an absolute-URL markdown image so they
# render in both the browser and the Conduit mobile client. See module docstring.
OWUI_UPLOAD_URL = os.environ.get("OWUI_UPLOAD_URL", "").rstrip("/")   # e.g. http://127.0.0.1:8080 (internal POST target)
OWUI_PUBLIC_URL = os.environ.get("OWUI_PUBLIC_URL", "").rstrip("/")   # e.g. http://192.168.86.63:8080 (what clients fetch)
OWUI_USER_ID = os.environ.get("OWUI_USER_ID", "")
WEBUI_SECRET_KEY = os.environ.get("WEBUI_SECRET_KEY", "")

mcp = FastMCP("comfyui", host=HOST, port=PORT)


def _clamp_dim(v: int) -> int:
    """Clamp a width/height to SDXL-friendly range and snap to a multiple of 64."""
    try:
        v = int(v)
    except (TypeError, ValueError):
        v = 1024
    v = max(512, min(1024, v))
    return (v // 64) * 64 or 512


def _b64url(b: bytes) -> bytes:
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def _owui_bearer():
    """Mint a short-lived Open WebUI JWT from WEBUI_SECRET_KEY, matching Open
    WebUI's HS256 {"id": <user_id>} scheme, so the MCP can upload files as that
    user. Returns None when Open WebUI delivery isn't fully configured."""
    if not (OWUI_UPLOAD_URL and OWUI_PUBLIC_URL and OWUI_USER_ID and WEBUI_SECRET_KEY):
        return None
    header = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = _b64url(json.dumps({"id": OWUI_USER_ID}, separators=(",", ":")).encode())
    signing_input = header + b"." + payload
    sig = _b64url(hmac.new(WEBUI_SECRET_KEY.encode(), signing_input, hashlib.sha256).digest())
    return (signing_input + b"." + sig).decode()


def _upload_png_to_owui(client, png):
    """Upload the PNG to Open WebUI's files API and return an ABSOLUTE content
    URL both the browser and the Conduit mobile client can load, or None on any
    failure so the caller can fall back to inline MCP image content."""
    bearer = _owui_bearer()
    if not bearer:
        return None
    try:
        r = client.post(
            f"{OWUI_UPLOAD_URL}/api/v1/files/?process=false",
            headers={"Authorization": f"Bearer {bearer}"},
            files={"file": ("generated.png", png, "image/png")},
            timeout=60,
        )
        r.raise_for_status()
        fid = r.json().get("id")
        if not fid:
            return None
        return f"{OWUI_PUBLIC_URL}/api/v1/files/{fid}/content"
    except Exception:
        return None  # best-effort; fall back to inline image content


def _build_workflow(prompt, negative_prompt, width, height, steps, seed):
    """SDXL text-to-image graph in ComfyUI API format. Kept in sync with
    comfyui-mcp/workflow_api.json (used by the Home Assistant integration)."""
    return {
        "4": {"class_type": "CheckpointLoaderSimple",
              "inputs": {"ckpt_name": CHECKPOINT}},
        "5": {"class_type": "EmptyLatentImage",
              "inputs": {"width": width, "height": height, "batch_size": 1}},
        "6": {"class_type": "CLIPTextEncode",
              "inputs": {"text": prompt, "clip": ["4", 1]}},
        "7": {"class_type": "CLIPTextEncode",
              "inputs": {"text": negative_prompt, "clip": ["4", 1]}},
        "3": {"class_type": "KSampler",
              "inputs": {"seed": seed, "steps": steps, "cfg": 7.0,
                         "sampler_name": "dpmpp_2m", "scheduler": "karras",
                         "denoise": 1.0, "model": ["4", 0],
                         "positive": ["6", 0], "negative": ["7", 0],
                         "latent_image": ["5", 0]}},
        "8": {"class_type": "VAEDecode",
              "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
        "9": {"class_type": "SaveImage",
              "inputs": {"filename_prefix": "mcp", "images": ["8", 0]}},
    }


def _free_vram(client):
    """Release ComfyUI's VRAM so gemma/other work has the GPU back."""
    try:
        client.post(f"{COMFYUI_URL}/free",
                    json={"unload_models": True, "free_memory": True},
                    timeout=30)
    except Exception:
        pass  # best-effort; never fail a generation over cleanup


# The MCP tool is named "image" (not "generate_image") on purpose: Open WebUI
# registers MCP tools as "<connection_id>_<tool_name>" and the image-gen
# connection id is "generate", so this registers as "generate_image" — the
# canonical name gemma reproduces verbatim in BOTH native and prompt-based
# (legacy) tool calling. Open WebUI still invokes this server by the raw name.
@mcp.tool(name="image")
def generate_image(prompt: str, negative_prompt: str = "",
                   width: int = 1024, height: int = 1024,
                   steps: int = 25, seed: int = -1):
    """Generate an image from a text prompt using the local SDXL model and
    return the PNG. Call this when the user asks to create, draw, generate, or
    imagine a picture/image/art. `prompt` should be a vivid, detailed English
    description of the desired image. Optional: `negative_prompt` (things to
    avoid), `width`/`height` (256-1024, default 1024x1024), `steps` (1-40,
    default 25), `seed` (-1 = random). The generated image is shown to the user
    automatically; in your reply just confirm it and describe what you made."""
    width = _clamp_dim(width)
    height = _clamp_dim(height)
    try:
        steps = max(1, min(40, int(steps)))
    except (TypeError, ValueError):
        steps = 25
    try:
        seed = int(seed)
    except (TypeError, ValueError):
        seed = -1
    if seed < 0:
        seed = random.randint(0, 2**32 - 1)

    client_id = f"mcp-{random.randint(0, 2**31)}"
    workflow = _build_workflow(prompt, negative_prompt, width, height, steps, seed)

    with httpx.Client() as client:
        try:
            r = client.post(f"{COMFYUI_URL}/prompt",
                            json={"prompt": workflow, "client_id": client_id},
                            timeout=30)
            r.raise_for_status()
            prompt_id = r.json()["prompt_id"]

            # Poll history until this prompt has outputs.
            deadline = time.time() + POLL_TIMEOUT
            outputs = None
            while time.time() < deadline:
                h = client.get(f"{COMFYUI_URL}/history/{prompt_id}", timeout=30)
                hist = h.json()
                if prompt_id in hist and hist[prompt_id].get("outputs"):
                    outputs = hist[prompt_id]["outputs"]
                    break
                time.sleep(1.0)
            if not outputs:
                raise RuntimeError(f"generation timed out after {POLL_TIMEOUT}s")

            # Find the SaveImage output.
            img = None
            for node in outputs.values():
                for im in node.get("images", []):
                    img = im
                    break
                if img:
                    break
            if not img:
                raise RuntimeError("ComfyUI returned no image")

            q = urllib.parse.urlencode({
                "filename": img["filename"],
                "subfolder": img.get("subfolder", ""),
                "type": img.get("type", "output"),
            })
            v = client.get(f"{COMFYUI_URL}/view?{q}", timeout=60)
            v.raise_for_status()
            png = v.content
        finally:
            _free_vram(client)

    # Preferred delivery: upload to Open WebUI and hand back an absolute-URL
    # markdown image (renders in the browser AND the Conduit mobile client).
    with httpx.Client() as up:
        url = _upload_png_to_owui(up, png)
    if url:
        return f"![generated image]({url})"

    # Fallback: inline MCP image content (Open WebUI re-serves it; this is the
    # path that renders a broken image in Conduit, but keeps the browser working
    # when Open WebUI delivery isn't configured or the upload failed).
    return Image(data=png, format="png")


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
