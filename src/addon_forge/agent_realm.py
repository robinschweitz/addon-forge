"""Agent-facing gateway to official AzerothCore/AzerothGhost e2e fixtures.

Only predefined upstream e2e tests can run here. No arbitrary SQL, GM
commands, generated Go source, shell, remote realms or volume deletion.
Fixtures mutate the explicitly approved disposable local Docker realm.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from .local_realm import (
    _read_private_env,
    check_compose,
    check_tools,
    verify_azerothcore_checkout,
)

# Fixed, reviewed tests in AzerothCore's official e2e/smoke package.
SCENARIOS = {
    "create-character": "TestSmoke_FirstTimeCharacterCreate",
    "login-world": "TestSmoke_ValidLoginEnterWorld",
    "teleport": "TestSmoke_TeleportPadSuccess",
}
MIN_GO_VERSION = (1, 26)
ENV_MARKER = "# Local Addon Forge realm only. Keep private."


def capabilities() -> dict:
    return {
        "experimental": True,
        "available": {
            "addon_static_validation": "forge check",
            "addon_deploy": "forge deploy",
            "graphical_client_assertions": "forge test",
            "upstream_server_fixtures": list(SCENARIOS),
        },
        "in_progress": [
            "persistent multi-player fixture sessions for GUI addon tests",
            "server state controls: health, items, buffs, combat, parties and quests",
            "automatic character-selection/enter-world verification",
            "AI-generated independent acceptance scenarios and coverage reports",
        ],
        "boundaries": [
            "local isolated AzerothCore test realm only",
            "explicit approval for state-changing fixture tests",
            "no arbitrary AI shell/SQL/worldserver commands",
            "no deletion of Docker volumes or public-realm interactions",
        ],
    }


def scenario_plan(scenario: str, realm: Path) -> dict:
    if scenario not in SCENARIOS:
        raise ValueError(f"Unsupported fixture scenario {scenario!r}")
    return {
        "scenario": scenario,
        "source": "Official AzerothCore e2e/smoke via AzerothGhost",
        "realm_dir": str(realm.expanduser().resolve()),
        "changes": [
            "Creates temporary test-realm account/character fixtures via the upstream Go harness",
            "Exercises real AzerothCore authserver/worldserver and local MySQL",
            "Upstream test performs cleanup where implemented; realm database can still change",
        ],
        "requires": [
            "Official AzerothCore checkout and marked Forge-generated local .env",
            "Running local Docker Desktop realm with loopback-only ports",
            "Go 1.26+ installed on this computer",
            "AC_WARDEN_ENABLED=0 configured for the disposable worldserver",
            "Explicit --approve-fixtures",
        ],
        "does_not_do": [
            "Generate Go code, modify addon files, control your GUI test character",
            "Remove Docker volumes or change server passwords",
        ],
    }


def _go_version() -> None:
    if not shutil.which("go"):
        raise RuntimeError("Go 1.26+ is required for official AzerothGhost e2e; install Go first.")
    result = subprocess.run(["go", "version"], capture_output=True, text=True, check=False)
    m = re.search(r"\bgo(\d+)\.(\d+)(?:\.\d+)?\b", result.stdout)
    if result.returncode or not m or tuple(map(int, m.groups())) < MIN_GO_VERSION:
        raise RuntimeError("Official AzerothCore e2e requires Go 1.26 or newer.")


def _compose_environment(realm: Path) -> dict:
    result = subprocess.run(["docker", "compose", "config", "--format", "json"],
                            cwd=realm, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError("Could not verify the local Compose server configuration.")
    try:
        config = json.loads(result.stdout)
        env = config["services"]["ac-worldserver"].get("environment", {})
        if isinstance(env, list):
            env = dict(row.split("=", 1) for row in env)
    except (ValueError, KeyError, TypeError) as exc:
        raise RuntimeError("Could not inspect worldserver environment.") from exc
    return env


def _preflight(realm: Path) -> tuple[str, int]:
    if not verify_azerothcore_checkout(realm):
        raise RuntimeError("Only an official local AzerothCore checkout can run fixture tests.")
    check_tools()
    content, values, db_port = _read_private_env(realm)
    if not content.startswith(ENV_MARKER):
        raise RuntimeError("Fixture tests require a Forge-generated, disposable local realm .env.")
    check_compose(realm)
    if not (realm / "e2e" / "go.mod").is_file():
        raise RuntimeError(
            "Official AzerothCore checkout has no e2e/go.mod; update it to a "
            "version that includes the AzerothGhost e2e harness."
        )
    # The upstream harness currently cannot log in with Warden enabled.
    # Require an unambiguous, test-only opt-in. Never edit worldserver config
    # or change a running service automatically.
    if str(_compose_environment(realm).get("AC_WARDEN_ENABLED", "")) != "0":
        raise RuntimeError(
            "Official AzerothGhost tests currently require AC_WARDEN_ENABLED=0 "
            "on the disposable local worldserver. Configure this in a "
            "local-only Docker Compose override and restart the worldserver "
            "before running fixtures; Forge will not disable Warden silently."
        )
    running = subprocess.run(
        ["docker", "compose", "ps", "--services", "--status", "running"],
        cwd=realm, capture_output=True, text=True, check=False,
    )
    if running.returncode:
        raise RuntimeError("Cannot read running local realm services.")
    required = {"ac-database", "ac-authserver", "ac-worldserver"}
    if not required.issubset(set(running.stdout.splitlines())):
        raise RuntimeError("AzerothCore database, auth and world services must be running.")
    # Generated password is restricted to hex; Go's DSN grammar can then be
    # assembled without interpreting separator characters or credential output.
    password = values["DOCKER_DB_ROOT_PASSWORD"]
    if not re.fullmatch(r"[0-9a-f]{64}", password):
        raise RuntimeError(
            "Fixture runner requires the random root password originally generated "
            "by Forge. Refusing to interpret other database passwords in DSNs."
        )
    _go_version()
    return password, db_port


def run_realm_smoke(realm: Path, *, scenario: str,
                    approve: bool = False, executor=None) -> dict:
    realm = realm.expanduser().resolve()
    plan = scenario_plan(scenario, realm)
    if not approve:
        return {"status": "plan_only", **plan}
    password, port = _preflight(realm)
    # Never pass credentials in a process command line or return/log them.
    env = dict(os.environ)
    env["E2E_AUTH_ADDR"] = "127.0.0.1:3724"
    for prefix, schema in (
        ("E2E_AUTH_DSN", "acore_auth"),
        ("E2E_CHAR_DSN", "acore_characters"),
        ("E2E_WORLD_DSN", "acore_world"),
    ):
        env[prefix] = f"root:{password}@tcp(127.0.0.1:{port})/{schema}"
    env.pop("E2E_ALLOW_SOFT_PASS", None)  # Never count unjudgeable scenarios as passes.
    argv = [
        "go", "test", "-tags=e2e", "./smoke",
        "-run", f"^{SCENARIOS[scenario]}$",
        "-count=1", "-v", "-timeout", "12m", "-p", "1", "-parallel", "1",
    ]
    try:
        result = (executor or subprocess.run)(
            argv, cwd=realm / "e2e", env=env, capture_output=True, text=True,
            timeout=780, check=False,
        )
    except subprocess.TimeoutExpired:
        return {"status": "infrastructure_error", "scenario": scenario,
                "error": "Official AzerothGhost fixture test timed out"}
    # Redact the root password even if the upstream test prints its DSN.
    output = ((result.stdout or "") + "\n" + (result.stderr or "")).replace(
        password, "[REDACTED_DB_PASSWORD]"
    )
    return {
        "status": "passed" if result.returncode == 0 else "failed",
        "scenario": scenario,
        "e2e_test": SCENARIOS[scenario],
        "returncode": result.returncode,
        "log_tail": output[-12000:],
        "note": "A successful protocol-level fixture does not verify a graphical addon; "
                "run forge test with independent addon assertions separately.",
    }
