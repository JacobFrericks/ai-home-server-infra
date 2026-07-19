#!/usr/bin/env python3
"""
comfyui-mcp — a tiny MCP server exposing a single `generate_image` tool that
drives a local ComfyUI (SDXL) instance.

Mirrors the searxng-mcp pattern in this stack: streamable-HTTP, bound on
LOOPBACK ONLY (127.0.0.1), host networking so it can reach ComfyUI at
127.0.0.1:8188 and be reached by the host-networked open-webui.

Design notes (see repo README "Image generation"):
  * gemma4:12b is the orchestrator and stays warm; this server NEVER touches
    Ollama. It only talks to ComfyUI.
  * VRAM strategy is "free-between-gens": after each image we POST /free so
    SDXL releases the GPU (12b + SDXL only co-reside during the ~10-20s gen).
  * The image is returned as MCP image content (the PNG itself), NOT a ComfyUI
    /view URL: that URL is 127.0.0.1-only and would not resolve in the user's
    browser. Open WebUI ingests image content and re-serves it to the browser.
  * Inputs are clamped server-side (SDXL native <=1024 buckets, capped steps)
    so a large request can't spike VAE-decode VRAM past the ~4 GB headroom.
"""
import os
import time
import json
import random
import urllib.parse

import httpx
from mcp.server.fastmcp import FastMCP, Image

COMFYUI_URL = os.environ.get("COMFYUI_URL", "http://127.0.0.1:8188").rstrip("/")
CHECKPOINT = os.environ.get("SDXL_CHECKPOINT", "sd_xl_base_1.0.safetensors")
HOST = os.environ.get("MCP_HTTP_HOST", "127.0.0.1")
PORT = int(os.environ.get("MCP_HTTP_PORT", "9300"))
POLL_TIMEOUT = int(os.environ.get("GEN_TIMEOUT", "180"))  # seconds

mcp = FastMCP("comfyui", host=HOST, port=PORT)


def _clamp_dim(v: int) -> int:
    """Clamp a width/height to SDXL-friendly range and snap to a multiple of 64."""
    try:
        v = int(v)
    except (TypeError, ValueError):
        v = 1024
    v = max(512, min(1024, v))
    return (v // 64) * 64 or 512


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


@mcp.tool()
def generate_image(prompt: str, negative_prompt: str = "",
                   width: int = 1024, height: int = 1024,
                   steps: int = 25, seed: int = -1) -> Image:
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

    return Image(data=png, format="png")


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
