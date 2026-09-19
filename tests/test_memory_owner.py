#!/usr/bin/env python3
"""Tests for the per-person memory boundary.

The one that matters is test_b_cannot_see_a: everything else is bookkeeping,
but a regression there leaks one family member's private notes into another
member's chat. It is the reason this file exists.

Run: python3 tests/test_memory_owner.py
"""
import asyncio
import importlib.util
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _stub_mcp():
    """Stand in for the `mcp` package so these tests need no dependencies.

    server.py imports MCPServer and decorates its tools at import time. The
    logic under test here (owner parsing, rendering, visibility) is plain
    Python underneath, so a decorator that returns the function unchanged is
    enough -- and it keeps CI from having to install the MCP SDK to check a
    privacy rule.
    """
    import types
    if "mcp" in sys.modules:
        return
    pkg = types.ModuleType("mcp")
    server = types.ModuleType("mcp.server")
    mcpserver = types.ModuleType("mcp.server.mcpserver")

    class MCPServer:
        def __init__(self, *a, **k):
            pass

        def tool(self, *a, **k):
            return lambda fn: fn

        def run(self, *a, **k):
            raise AssertionError("tests must never start the server")

    mcpserver.MCPServer = MCPServer
    server.mcpserver = mcpserver
    pkg.server = server
    sys.modules["mcp"] = pkg
    sys.modules["mcp.server"] = server
    sys.modules["mcp.server.mcpserver"] = mcpserver


_stub_mcp()


def _load(path, name, memory_dir):
    """Import a module with MEMORY_DIR pointed at a scratch dir.

    Both files read MEMORY_DIR at import time, so the env var has to be set
    before the module object is created -- not after.
    """
    os.environ["MEMORY_DIR"] = memory_dir
    spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, path))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


class RecallBoundary(unittest.TestCase):
    """scripts/memory_recall.py -- the half that actually enforces privacy."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.recall = _load("scripts/memory_recall.py", "recall_t", self.dir)
        self.write("shared", "household", "The wifi password is on the fridge.")
        self.write("jacobs", "jacob", "Jacob is allergic to shellfish.")
        self.write("cassies", "cassie", "Cassie's passport expires in March.")
        self.write("legacy", None, "A fact saved before owners existed.")

    def write(self, name, owner, content):
        owner_line = f"owner: {owner}\n" if owner else ""
        with open(os.path.join(self.dir, f"{name}.md"), "w") as f:
            f.write(f"---\nname: {name}\ndescription: d\ntype: user\n"
                    f"{owner_line}---\n\n{content}\n")

    def inject(self, user):
        body = {"messages": [{"role": "user", "content": "hi"}]}
        out = asyncio.run(self.recall.Filter().inlet(body, __user__=user))
        sys_msgs = [m for m in out["messages"] if m["role"] == "system"]
        return sys_msgs[0]["content"] if sys_msgs else ""

    # --- the load-bearing test ---------------------------------------------

    def test_b_cannot_see_a(self):
        """Cassie's chat must never contain Jacob's private fact."""
        text = self.inject({"email": "cassie@example.com", "id": "u2"})
        self.assertIn("passport", text)          # her own
        self.assertIn("wifi password", text)     # shared
        self.assertNotIn("shellfish", text)      # HIS -- the leak
        self.assertNotIn("Jacob is allergic", text)

    def test_a_cannot_see_b(self):
        text = self.inject({"email": "jacob@example.com", "id": "u1"})
        self.assertIn("shellfish", text)
        self.assertIn("wifi password", text)
        self.assertNotIn("passport", text)

    # --- failing closed -----------------------------------------------------

    def test_unknown_user_gets_household_only(self):
        """No identity must mean less, never more."""
        for user in (None, {}, {"email": ""}, "not-a-dict", {"email": "@@"}):
            text = self.inject(user)
            self.assertIn("wifi password", text, f"household lost for {user!r}")
            self.assertNotIn("shellfish", text, f"LEAK for {user!r}")
            self.assertNotIn("passport", text, f"LEAK for {user!r}")

    def test_unowned_legacy_file_is_household(self):
        """Files written before this feature had exactly one possible owner."""
        self.assertIn("before owners existed", self.inject(None))

    def test_owner_key_prefers_email_then_id(self):
        k = self.recall._owner_key
        self.assertEqual(k({"email": "Jacob.F@example.com", "id": "x"}), "jacob-f")
        self.assertEqual(k({"email": "", "id": "abc-123"}), "abc-123")
        self.assertEqual(k({}), "")
        self.assertEqual(k(None), "")

    # --- behaviour that must survive the change -----------------------------

    def test_task_requests_still_skipped(self):
        body = {"messages": [{"role": "user", "content": "hi"}]}
        out = asyncio.run(self.recall.Filter().inlet(
            body, __user__={"email": "jacob@example.com"},
            __metadata__={"task": "title_generation"}))
        self.assertEqual(out["messages"], [{"role": "user", "content": "hi"}])

    def test_injection_is_idempotent(self):
        f = self.recall.Filter()
        user = {"email": "jacob@example.com"}
        body = {"messages": [{"role": "system", "content": "Base prompt."},
                             {"role": "user", "content": "hi"}]}
        for _ in range(3):
            body = asyncio.run(f.inlet(body, __user__=user))
        text = body["messages"][0]["content"]
        self.assertEqual(text.count(self.recall.OPEN), 1)
        self.assertIn("Base prompt.", text)

    def test_block_names_the_person_for_save(self):
        """The model learns who it is talking to, so it can set owner on save."""
        self.assertIn("jacob", self.inject({"email": "jacob@example.com"}))


class ServerStorage(unittest.TestCase):
    """memory-mcp/server.py -- round-tripping the owner field."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.srv = _load("memory-mcp/server.py", "srv_t", self.dir)

    def test_owner_round_trips(self):
        rendered = self.srv._render("n", "d", "user", "body", "cassie")
        self.assertIn("owner: cassie", rendered)
        p = os.path.join(self.dir, "n.md")
        with open(p, "w") as f:
            f.write(rendered)
        self.assertEqual(self.srv._parse(p)["owner"], "cassie")

    def test_missing_owner_parses_as_household(self):
        p = os.path.join(self.dir, "old.md")
        with open(p, "w") as f:
            f.write("---\nname: old\ndescription: d\ntype: user\n---\n\nx\n")
        self.assertEqual(self.srv._parse(p)["owner"], self.srv.HOUSEHOLD)

    def test_norm_owner_folds_garbage_to_household(self):
        # "!!!" is the regression: _slug() turns it into a unique
        # memory-<timestamp> key, which no account matches, so the fact would
        # be invisible to everyone rather than shared.
        for bad in ("", None, "   ", "!!!", "///"):
            self.assertEqual(self.srv._norm_owner(bad), self.srv.HOUSEHOLD)
        self.assertEqual(self.srv._norm_owner("Jacob F"), "jacob-f")

    def test_visible_to_matches_the_filter(self):
        mems = [{"owner": "household"}, {"owner": "jacob"}, {"owner": "cassie"}]
        self.assertEqual(len(self.srv._visible_to(mems, "jacob")), 2)
        self.assertEqual(len(self.srv._visible_to(mems, "")), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
