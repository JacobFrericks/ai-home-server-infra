"""
title: Render Tool Images
author: ai-home-server-infra
description: Appends absolute-URL image markdown returned by tool calls into the
    assistant message body, so generated images render in clients (e.g. the
    Conduit Android app) that do not resolve relative tool-call image URLs.
version: 1.0.0
required_open_webui_version: 0.5.0
"""

# WHY THIS EXISTS
# --------------
# Our comfyui-image MCP tool uploads the generated PNG to Open WebUI's files API
# and returns a Markdown image tag with an ABSOLUTE same-origin URL, e.g.
#   ![generated image](http://192.168.86.63:8080/api/v1/files/<id>/content)
# That tag lands in the assistant message's `output` as a `function_call_output`,
# NOT in the visible message `content`. Open WebUI's web UI hides it behind a
# collapsed "View Result" panel, and the model cannot be relied on to copy the
# URL into its reply (gemma refuses to reproduce it). Native/inline image results
# render only via RELATIVE `/api/v1/files/...` URLs, which the Conduit Android
# client fails to resolve against the server base -> broken image.
#
# This outlet filter runs after each completion, scans the assistant message's
# tool outputs for image markdown pointing at the files API, and appends any that
# are missing from the visible content. Open WebUI persists the edited content and
# emits a chat:outlet event, so the image shows in every client, deterministically
# and independent of the model.

import re
import copy

# Matches Markdown images whose URL targets the Open WebUI files content endpoint,
# absolute (http[s]://host/api/v1/files/<id>/content) or relative
# (/api/v1/files/<id>/content).
_IMG_RE = re.compile(
    r"!\[[^\]]*\]\(\s*((?:https?://[^)\s]+)?/api/v1/files/[^)\s]+/content)\s*\)"
)


def _iter_output_texts(output):
    """Yield text strings from an assistant message `output` array's
    function_call_output items (Open WebUI Responses-style output)."""
    if not isinstance(output, list):
        return
    for item in output:
        if not isinstance(item, dict) or item.get("type") != "function_call_output":
            continue
        out = item.get("output")
        if isinstance(out, str):
            yield out
        elif isinstance(out, list):
            for part in out:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    yield part["text"]


def _iter_message_texts(output):
    """Yield output_text strings from an assistant `output` array's message items
    (the surface the client renders)."""
    if not isinstance(output, list):
        return
    for item in output:
        if not isinstance(item, dict) or item.get("type") != "message":
            continue
        for part in item.get("content", []):
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                yield part["text"]


class Filter:
    def __init__(self):
        pass

    async def outlet(self, body: dict, **kwargs) -> dict:
        messages = body.get("messages")
        if not isinstance(messages, list):
            return body

        for msg in messages:
            if not isinstance(msg, dict) or msg.get("role") != "assistant":
                continue

            src_output = msg.get("output")
            if not isinstance(src_output, list):
                continue

            # Collect image tags returned by tool calls, de-duplicated, in order.
            tags = []
            for text in _iter_output_texts(src_output):
                for m in _IMG_RE.finditer(text):
                    tag = m.group(0)
                    if tag not in tags:
                        tags.append(tag)
            if not tags:
                continue

            # What the client actually renders for a tool-augmented reply is the
            # `output` array's `message` item (output_text), NOT top-level
            # `content`. Consider a tag already shown if its URL is in either.
            rendered = msg.get("content") or ""
            for text in _iter_message_texts(src_output):
                rendered += "\n" + text

            missing = [t for t in tags if _IMG_RE.search(t).group(1) not in rendered]
            if not missing:
                continue
            block = "\n\n".join(missing)

            # IMPORTANT: build a NEW output object rather than mutating in place.
            # The outlet handler only persists `output` when the new object is
            # value-different from the stored one; the payload hands us the SAME
            # list object as the stored message, so an in-place edit compares
            # equal and is silently dropped (never written to the DB).
            output = copy.deepcopy(src_output)
            msg_item = self._last_message_item(output)
            if msg_item is None:
                msg_item = {"type": "message", "role": "assistant",
                            "status": "completed", "content": []}
                output.append(msg_item)
            parts = msg_item.setdefault("content", [])
            last_text = next(
                (p for p in reversed(parts)
                 if isinstance(p, dict) and p.get("type") == "output_text"),
                None,
            )
            if last_text is not None:
                sep = "\n\n" if (last_text.get("text") or "").strip() else ""
                last_text["text"] = (last_text.get("text") or "") + sep + block
            else:
                parts.append({"type": "output_text", "text": block})

            msg["output"] = output

        return body

    @staticmethod
    def _last_message_item(output):
        if not isinstance(output, list):
            return None
        for item in reversed(output):
            if isinstance(item, dict) and item.get("type") == "message":
                return item
        return None
