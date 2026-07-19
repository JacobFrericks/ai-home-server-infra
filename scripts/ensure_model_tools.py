"""
title: Ensure Model Tools
author: ai-home-server-infra
description: Re-attaches a workspace model's configured tools when the client
    omits them, so tools keep working on follow-up turns from clients (e.g. the
    Conduit Android app) that only send tool_ids on the first message of a chat.
version: 1.0.0
required_open_webui_version: 0.5.0
"""

# WHY THIS EXISTS
# --------------
# Open WebUI only attaches tools that the CLIENT sends in the request
# (`tool_ids`); it never falls back to the model's stored `meta.toolIds`
# server-side. The Conduit Android client sends `tool_ids` on the first message
# of a chat but NOT on follow-up messages, so a follow-up like "make it blue"
# arrives with no tools -> the model still tries to call `generate_image` ->
# 'Error: Tool "generate_image" not found.'
#
# This inlet filter runs BEFORE Open WebUI resolves tools (middleware.py:2428,
# ahead of the tool_ids pop at 2500). For a real user turn it merges the model's
# own configured `toolIds` into the request, so the model's tools are available
# on every turn regardless of what the client sends. Internal task requests
# (title / tag / follow-up / autocomplete generation) set `metadata['task']` and
# are skipped, so they keep running tool-free.


class Filter:
    def __init__(self):
        pass

    async def inlet(self, body: dict, __model__=None, __metadata__=None, **kwargs) -> dict:
        metadata = __metadata__ or {}
        # Internal generations (title/tags/follow-up/etc.) intentionally omit
        # tools; never inject into those.
        if metadata.get("task"):
            return body

        model = __model__ or {}
        model_tool_ids = (
            ((model.get("info") or {}).get("meta") or {}).get("toolIds")
        ) or []
        if not model_tool_ids:
            return body

        existing = body.get("tool_ids") or []
        merged = list(existing)
        for tid in model_tool_ids:
            if tid not in merged:
                merged.append(tid)

        # Only rewrite if we actually added something.
        if merged != existing:
            body["tool_ids"] = merged
        return body
