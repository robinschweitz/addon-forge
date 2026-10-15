"""Minimal stdio MCP server exposing Addon Forge as typed tools.

Agents get structured results instead of composing shell commands. Paths are
confined to the projects directory. Real-client plan execution mutates the
disposable test realm, so it is only available when the *human* started the
server with --allow-fixtures; an agent cannot grant itself that approval.
"""
from __future__ import annotations

from contextlib import redirect_stdout
from dataclasses import asdict
import json
from pathlib import Path
import sys
import traceback

from . import __version__

PROTOCOL_VERSION = "2025-06-18"

INSTRUCTIONS = """Addon Forge builds and tests WoW 3.3.5a (Interface 30300, Lua 5.1) addons.
Loop: forge_new or edit files under projects/<Addon>/ -> forge_check -> forge_spec (offline
headless specs in projects/<Addon>/tests/*.spec.lua) -> forge_plan_preview -> forge_run_plan.
Use forge_api_lookup before relying on an API you are unsure exists in 3.3.5a. Never weaken an
acceptance plan's checks to make an addon pass; fix the addon instead."""

TOOLS = [
    {"name": "forge_new", "description": "Create projects/<name>/ (toc, Core.lua, offline spec) and "
     "projects/<name>-acceptance.json. Fails if either exists.",
     "inputSchema": {"type": "object", "required": ["name"], "properties": {
         "name": {"type": "string", "description": "CapitalizedName, 3-40 letters/digits"},
         "notes": {"type": "string", "description": "One-line .toc description"}}}},
    {"name": "forge_check", "description": "Static checks: TOC, Lua 5.1 syntax, APIs missing from 3.3.5a, "
     "accidental globals. Returns diagnostics with file:line.",
     "inputSchema": {"type": "object", "required": ["addon"], "properties": {
         "addon": {"type": "string", "description": "Addon folder name under projects/"}}}},
    {"name": "forge_spec", "description": "Load the addon in the headless 3.3.5a emulation and run its "
     "tests/*.spec.lua. Fast feedback; not proof of in-client behaviour.",
     "inputSchema": {"type": "object", "required": ["addon"], "properties": {
         "addon": {"type": "string"}}}},
    {"name": "forge_api_lookup", "description": "Does a global (e.g. GetNumGroupMembers) or Widget:Method "
     "(e.g. Button:SetTextColor) exist on 3.3.5a? Returns hints for replacements.",
     "inputSchema": {"type": "object", "required": ["names"], "properties": {
         "names": {"type": "array", "items": {"type": "string"}, "maxItems": 50}}}},
    {"name": "forge_plan_preview", "description": "Validate an acceptance plan and list the operations a "
     "real-client run would perform. No side effects.",
     "inputSchema": {"type": "object", "required": ["plan"], "properties": {
         "plan": {"type": "string", "description": "Plan file name under projects/, e.g. MyAddon-acceptance.json"}}}},
    {"name": "forge_run_plan", "description": "Run the plan against the real test client: static + offline "
     "gates, deploy, fixtures, bridge suite, independent checks. Only works when the human started the "
     "server with --allow-fixtures and the test client is logged in.",
     "inputSchema": {"type": "object", "required": ["plan"], "properties": {"plan": {"type": "string"}}}},
]


class Forge:
    def __init__(self, projects: Path, config: Path, allow_fixtures: bool):
        self.projects = projects.resolve()
        self.config = config
        self.allow_fixtures = allow_fixtures

    def _inside(self, name: str, *, suffix: str | None = None) -> Path:
        if not isinstance(name, str) or not name or "\0" in name:
            raise ValueError("Expected a path relative to projects/")
        path = (self.projects / name).resolve()
        if not path.is_relative_to(self.projects) or path == self.projects:
            raise ValueError("Path must stay inside projects/")
        if suffix and path.suffix.lower() != suffix:
            raise ValueError(f"Expected a {suffix} file")
        return path

    def forge_new(self, name: str, notes: str = "Created with Addon Forge"):
        from .scaffold import new_addon
        return new_addon(name, root=self.projects, notes=notes)

    def forge_check(self, addon: str):
        from .validate import check_addon, is_valid
        diagnostics = check_addon(self._inside(addon))
        return {"valid": is_valid(diagnostics), "diagnostics": [asdict(d) for d in diagnostics]}

    def forge_spec(self, addon: str):
        from .headless import run_specs
        return run_specs(self._inside(addon))

    def forge_api_lookup(self, names: list):
        from .wowapi import lookup
        if not isinstance(names, list) or len(names) > 50:
            raise ValueError("names must be a list of up to 50 strings")
        return [lookup(str(n)) for n in names]

    def forge_plan_preview(self, plan: str):
        from .agent_workflow import run_plan
        from .config import load_config
        return run_plan(load_config(self.config), self._inside(plan, suffix=".json"), approve=False)

    def forge_run_plan(self, plan: str):
        if not self.allow_fixtures:
            return {"status": "not_authorized",
                    "error": "Real-client runs need human approval: restart the MCP server with "
                             "'forge mcp --allow-fixtures' (or run 'forge agent run-plan ... "
                             "--approve-fixtures' yourself)."}
        from .agent_workflow import run_plan
        from .config import load_config
        return run_plan(load_config(self.config), self._inside(plan, suffix=".json"), approve=True)


def _reply(msg_id, result=None, error=None):
    body = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        body["error"] = error
    else:
        body["result"] = result
    return body


def handle(forge: Forge, message: dict) -> dict | None:
    method, msg_id = message.get("method"), message.get("id")
    if msg_id is None:
        return None  # Notifications (initialized, cancelled) need no reply.
    if method == "initialize":
        requested = (message.get("params") or {}).get("protocolVersion")
        return _reply(msg_id, {"protocolVersion": requested or PROTOCOL_VERSION,
                               "capabilities": {"tools": {"listChanged": False}},
                               "serverInfo": {"name": "addon-forge", "version": __version__},
                               "instructions": INSTRUCTIONS})
    if method == "ping":
        return _reply(msg_id, {})
    if method == "tools/list":
        return _reply(msg_id, {"tools": TOOLS})
    if method == "tools/call":
        params = message.get("params") or {}
        name, args = params.get("name"), params.get("arguments") or {}
        if name not in {t["name"] for t in TOOLS} or not isinstance(args, dict):
            return _reply(msg_id, error={"code": -32602, "message": f"Unknown tool {name!r}"})
        try:
            # Tools must never write to stdout: it carries the JSON-RPC stream.
            with redirect_stdout(sys.stderr):
                result = getattr(forge, name)(**args)
            return _reply(msg_id, {"content": [{"type": "text", "text": json.dumps(result, indent=2, default=str)}],
                                   "isError": False})
        except (TypeError, ValueError, OSError, RuntimeError) as exc:
            return _reply(msg_id, {"content": [{"type": "text", "text": f"{type(exc).__name__}: {exc}"}],
                                   "isError": True})
        except Exception:  # pragma: no cover - surface unexpected failures to the agent
            return _reply(msg_id, {"content": [{"type": "text", "text": traceback.format_exc(limit=5)}],
                                   "isError": True})
    return _reply(msg_id, error={"code": -32601, "message": f"Method not found: {method}"})


def serve(projects: Path, config: Path, *, allow_fixtures: bool = False,
          stdin=None, stdout=None) -> int:
    if stdin is None:
        sys.stdin.reconfigure(encoding="utf-8")  # MCP is UTF-8 regardless of console code page.
        sys.stdout.reconfigure(encoding="utf-8")
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    forge = Forge(projects, config, allow_fixtures)
    for line in stdin:
        line = line.strip().lstrip("﻿")  # Some Windows shells prefix a BOM.
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            response = _reply(None, error={"code": -32700, "message": "Parse error"})
        else:
            response = handle(forge, message) if isinstance(message, dict) else \
                _reply(None, error={"code": -32600, "message": "Invalid request"})
        if response is not None:
            stdout.write(json.dumps(response) + "\n")
            stdout.flush()
    return 0
