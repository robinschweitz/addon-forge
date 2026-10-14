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

from .agent_realm import _preflight, _go_environment
from .client import ClientController
from .config import Config
from .runner import run_smoke

NAME = re.compile(r"[A-Za-z]{2,12}\Z")


def _fixture_env(password: str, port: int, target: str, folder: Path, peers: int = 1) -> dict:
    env = _go_environment()
    env.pop("E2E_ALLOW_SOFT_PASS", None)
    env.update({
        "E2E_AUTH_ADDR": "127.0.0.1:3724",
        "E2E_AUTH_DSN": f"root:{password}@tcp(127.0.0.1:{port})/acore_auth",
        "E2E_CHAR_DSN": f"root:{password}@tcp(127.0.0.1:{port})/acore_characters",
        "E2E_WORLD_DSN": f"root:{password}@tcp(127.0.0.1:{port})/acore_world",
        "FORGE_TARGET_CHARACTER": target,
        "FORGE_PEER_COUNT": str(peers),
        "FORGE_PEER_READY": str(folder / "ready.json"),
        "FORGE_PEER_RELEASE": str(folder / "release"),
        "FORGE_PEER_LEAVE": str(folder / "request-leave"),
        "FORGE_PEER_LEFT": str(folder / "left"),
    })
    return env


def _read_ready(path: Path, *, target: str, count: int) -> list[str]:
    """Read a bounded handshake, including old one-peer fixture results."""
    if path.is_symlink() or path.stat().st_size > 4096:
        raise RuntimeError("Untrusted or oversized peer readiness data")
    try:
        meta = json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeError, OSError) as exc:
        raise RuntimeError("Invalid peer readiness JSON") from exc
    if not isinstance(meta, dict) or meta.get("status") != "ready":
        raise RuntimeError("Peer fixture did not report ready status")
    if meta.get("target") != target:
        raise RuntimeError("Peer fixture targeted a different character")
    names = meta.get("names")
    if names is None and count == 1 and meta.get("version") is None:
        names = [meta.get("name")]
    if (not isinstance(names, list) or len(names) != count
            or any(not isinstance(n, str) or not NAME.fullmatch(n) for n in names)
            or len(set(names)) != count):
        raise RuntimeError("Peer fixture returned an invalid player name list")
    if meta.get("name") != names[0]:
        raise RuntimeError("Peer fixture primary name differs from names list")
    if meta.get("version") is not None and (
            meta.get("version") != 2 or type(meta.get("count")) is not int
            or meta["count"] != count):
        raise RuntimeError("Peer fixture handshake version/count mismatch")
    return names


def peer_scenario(cfg: Config, *, character: str,
                  approve: bool = False, timeout: int = 100,
                  peers: int = 1, suite: str = "peer",
                  required_tests: tuple[str, ...] = ("peer_target_visible",),
                  output_dir: Path | None = None,
                  lifecycle: bool = False) -> dict:
    if not NAME.fullmatch(character):
        raise ValueError("Use a 2-12-letter local graphical test character name.")
    if lifecycle and peers < 3:
        raise ValueError("Party lifecycle requires three or four peer players")
    if peers < 1 or peers > 4:
        raise ValueError("peers must be between 1 and 4")
    if not suite.isalnum() or not required_tests:
        raise ValueError("Invalid suite or required tests")
    if not cfg.realm_dir:
        raise RuntimeError("Set [realm] source_dir in forge.local.toml.")
    plan = {
        "scenario": "peer-target",
        "character": character,
        "peers": peers,
        "lifecycle": lifecycle,
        "suite": suite,
        "required_tests": list(required_tests),
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
            "Bot-to-bot parties only; the real WoW character is not a party member",
            "Does not test combat, quest state or arbitrary AI-specified behaviors",
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
        env = _fixture_env(password, port, character, folder, peers=peers)
        args = [
            "go", "test", "-tags=e2e", "-run", "^TestPeerTargetFixture$",
            "-count=1", "-v", "-timeout", "260s", "-parallel", "1", "-p", "1",
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
                names = _read_ready(ready, target=character, count=peers)
                name = names[0]
                client = ClientController(cfg)
                client.command("/targetexact " + name)
                client.command("/forge expect " + name)
                result = run_smoke(cfg, suite=suite, required_tests=required_tests,
                                   out_dir=output_dir)
                if not lifecycle:
                    return {
                        "status": result.status, "peer_name": name, "peer_names": names,
                        "report": result.__dict__, "note": (
                            "Verified real protocol peer and client-side target assertion.")}
                # Do not proceed to the departure stage unless the first
                # independently correlated in-game assertion passed.
                stages = [{"step": "all_peers_online", "report": result.__dict__}]
                if result.status != "passed":
                    return {"status": result.status, "peer_names": names, "stages": stages}
                (folder / "request-leave").touch()
                left = folder / "left"
                until = time.monotonic() + 25
                while time.monotonic() < until and not left.is_file():
                    if proc.poll() is not None:
                        break
                    time.sleep(0.2)
                if not left.is_file():
                    return {"status": "infrastructure_error", "peer_names": names,
                            "stages": stages,
                            "error": "Protocol party departure was not acknowledged"}
                remaining = names[:-1]
                client.command("/targetexact " + remaining[0])
                client.command("/forge expect " + remaining[0])
                after = run_smoke(cfg, suite=suite, required_tests=required_tests,
                                  out_dir=output_dir)
                stages.append({"step": "peer_departed", "report": after.__dict__})
                return {"status": after.status, "peer_names": names,
                        "remaining_peer_names": remaining, "stages": stages,
                        "note": "Bot-to-bot party changed; GUI character was not added to their party."}
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
