"""Synchronized proof-of-concept: real protocol peer + real WoW UI assertion.

Requires a manually logged-in, in-world local test character. Runs an
AzerothGhost protocol player only as long as the GUI smoke run needs it.
Never modifies Wow.exe, server config, or the user's production client.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from .agent_realm import _preflight
from .client import ClientController
from .config import Config
from .runner import run_smoke

NAME = re.compile(r"[A-Za-z]{2,12}\Z")


def _fixture_env(password: str, port: int, target: str, folder: Path) -> dict:
    env = dict(os.environ)
    env.pop("E2E_ALLOW_SOFT_PASS", None)
    env.update({
        "E2E_AUTH_ADDR": "127.0.0.1:3724",
        "E2E_AUTH_DSN": f"root:{password}@tcp(127.0.0.1:{port})/acore_auth",
        "E2E_CHAR_DSN": f"root:{password}@tcp(127.0.0.1:{port})/acore_characters",
        "E2E_WORLD_DSN": f"root:{password}@tcp(127.0.0.1:{port})/acore_world",
        "FORGE_TARGET_CHARACTER": target,
        "FORGE_PEER_READY": str(folder / "ready.json"),
        "FORGE_PEER_RELEASE": str(folder / "release"),
    })
    return env


def peer_scenario(cfg: Config, *, character: str,
                  approve: bool = False, timeout: int = 100) -> dict:
    if not NAME.fullmatch(character):
        raise ValueError("Use a 2-12-letter local graphical test character name.")
    if not cfg.realm_dir:
        raise RuntimeError("Set [realm] source_dir in forge.local.toml.")
    plan = {
        "scenario": "peer-target",
        "character": character,
        "steps": [
            "Create and log in a temporary AzerothGhost warrior",
            "Teleport the peer to the already in-world graphical test character",
            "Target it using /targetexact in the verified test WoW window",
            "Assert UnitName/UnitIsPlayer via ForgeTestBridge and correlate SavedVariables",
            "Disconnect the protocol peer when the test completes",
        ],
        "limitations": [
            "The graphical test character must already be logged in and in the world",
            "Requires Go 1.26+ and a configured local-only AzerothGhost-compatible realm",
            "Does not test combat, grouping, quest state or arbitrary AI-specified behaviors",
        ],
    }
    if not approve:
        return {"status": "plan_only", **plan}

    realm = cfg.realm_dir.resolve()
    password, port = _preflight(realm)
    go_dir = Path(__file__).resolve().parents[2] / "agent_scenarios"
    if not (go_dir / "go.mod").is_file():
        raise RuntimeError("Missing pinned agent_scenarios/go.mod")
    with tempfile.TemporaryDirectory(prefix="forge-peer-") as temp_dir:
        folder = Path(temp_dir)
        env = _fixture_env(password, port, character, folder)
        args = [
            "go", "test", "-tags=e2e", "-run", "^TestPeerTargetFixture$",
            "-count=1", "-v", "-timeout", "130s", "-parallel", "1", "-p", "1",
        ]
        # Don't inherit child stdout containing auth diagnostics or secret DSNs.
        with (folder / "go-output.log").open("wb+") as log:
            proc = subprocess.Popen(args, cwd=go_dir, env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + timeout
                ready = folder / "ready.json"
                while time.monotonic() < deadline:
                    if ready.is_file():
                        break
                    if proc.poll() is not None:
                        raise RuntimeError("AzerothGhost fixture exited before peer was ready; "
                                           "check Go/realm configuration.")
                    time.sleep(0.2)
                if not ready.is_file():
                    raise RuntimeError("Peer fixture did not become ready in time.")
                meta = json.loads(ready.read_text(encoding="utf-8"))
                name = meta.get("name", "")
                if meta.get("status") != "ready" or not NAME.fullmatch(name):
                    raise RuntimeError("Peer fixture produced an invalid identity.")
                client = ClientController(cfg)
                client.command("/targetexact " + name)
                client.command("/forge expect " + name)
                result = run_smoke(cfg, suite="peer", required_tests=("peer_target_visible",))
                return {
                    "status": result.status, "peer_name": name,
                    "report": result.__dict__, "note": (
                        "One verified real protocol peer + one client-side target assertion; "
                        "not proof of all addon functionality.")
                }
            finally:
                (folder / "release").touch()
                try:
                    proc.wait(timeout=18)
                except subprocess.TimeoutExpired:
                    proc.terminate()
                    try:
                        proc.wait(timeout=6)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait(timeout=5)
