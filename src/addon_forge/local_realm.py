"""Safe local AzerothCore Docker bootstrap for an isolated WoW test copy.

Never touches the user's existing WoW installation or Hetzner Cloud.
All mutations require the explicit 'setup --approve-local-setup' command.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tomllib
import uuid

from .deploy import deploy
from .realm_connect import configure_realmlist

OFFICIAL_REPO = "https://github.com/azerothcore/azerothcore-wotlk.git"
LOCAL_PORTS = {
    "DOCKER_DB_EXTERNAL_PORT": 3306,
    "DOCKER_AUTH_EXTERNAL_PORT": 3724,
    "DOCKER_WORLD_EXTERNAL_PORT": 8085,
    "DOCKER_SOAP_EXTERNAL_PORT": 7878,
}
EXPECTED_PORTS = {
    ("ac-database", 3306),
    ("ac-authserver", 3724),
    ("ac-worldserver", 8085),
    ("ac-worldserver", 7878),
}
SKIP_WOW_ROOT = {"wtf", "cache", "screenshots", "logs", "errors"}
MARKER = ".addon-forge-test-copy.json"


def _run(argv: list[str], *, cwd: Path | None = None, capture: bool = False):
    return subprocess.run(argv, cwd=cwd, check=True, text=True,
                          capture_output=capture)


def _same_or_inside(path: Path, root: Path) -> bool:
    return path == root or path.is_relative_to(root)


def paths(source: Path, target: Path, realm: Path) -> tuple[Path, Path, Path]:
    source, target, realm = (p.expanduser().resolve() for p in (source, target, realm))
    if not any((source / exe).is_file() for exe in ("Wow.exe", "WoW.exe")):
        raise FileNotFoundError(f"No Wow.exe/ WoW.exe in source folder {source}")
    for left, right in ((source, target), (target, source),
                        (source, realm), (realm, source),
                        (target, realm), (realm, target)):
        if _same_or_inside(left, right):
            raise ValueError("The source, test client and AzerothCore paths must be separate")
    if source.is_symlink() or target.is_symlink() or realm.is_symlink():
        raise ValueError("Symlink paths are not supported for local realm setup")
    return source, target, realm


def verify_test_copy(target: Path, source: Path) -> bool:
    if not target.exists():
        return False
    marker = target / MARKER
    if not marker.is_file() or marker.is_symlink():
        raise RuntimeError(f"Refusing to modify existing unmarked folder: {target}")
    try:
        identity = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"Invalid test-client marker: {marker}") from exc
    if identity.get("source") != str(source):
        raise RuntimeError("Existing test copy was made from a different source")
    if not any((target / exe).is_file() for exe in ("Wow.exe", "WoW.exe")):
        raise RuntimeError(f"Existing test copy is incomplete: {target}")
    return True


def _check_symlinks(source: Path):
    # Refuse Windows junctions/symlinks too: copytree must not leave the WoW tree.
    for directory, folders, files in os.walk(source, followlinks=False):
        relative = Path(directory).relative_to(source)
        if not relative.parts:
            folders[:] = [f for f in folders if f.casefold() not in SKIP_WOW_ROOT]
        for name in [*folders, *files]:
            item = Path(directory) / name
            if item.is_symlink() or (hasattr(item, "is_junction") and item.is_junction()):
                raise ValueError(f"WoW source contains a link; refusing to copy: {item}")


def make_test_copy(source: Path, target: Path) -> None:
    if verify_test_copy(target, source):
        return
    if not target.parent.is_dir():
        raise RuntimeError(f"Create the test client's parent directory first: {target.parent}")
    _check_symlinks(source)
    stage = target.with_name(f".{target.name}-forge-stage-{uuid.uuid4().hex[:10]}")
    try:
        def ignore(directory, names):
            if Path(directory) == source:
                return {n for n in names if n.casefold() in SKIP_WOW_ROOT}
            return set()

        shutil.copytree(source, stage, ignore=ignore, symlinks=False)
        (stage / MARKER).write_text(json.dumps({"source": str(source)}),
                                    encoding="utf-8")
        stage.rename(target)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    print(f"Created isolated WoW test copy: {target}")


def verify_azerothcore_checkout(realm: Path) -> bool:
    if not realm.exists():
        return False
    if not realm.is_dir() or realm.is_symlink() or not (realm / "docker-compose.yml").is_file():
        raise RuntimeError(f"Refusing to reuse non-AzerothCore directory: {realm}")
    remote = _run(["git", "-C", str(realm), "remote", "get-url", "origin"],
                  capture=True).stdout.strip()
    if remote.rstrip("/").removesuffix(".git") not in {
        OFFICIAL_REPO.removesuffix(".git"),
        "git@github.com:azerothcore/azerothcore-wotlk",
    }:
        raise RuntimeError("Existing realm directory is not the official AzerothCore checkout")
    return True


def clone_azerothcore(realm: Path) -> None:
    if verify_azerothcore_checkout(realm):
        print(f"Reusing AzerothCore checkout: {realm}")
        return
    if not realm.parent.is_dir():
        raise RuntimeError(f"Create the AzerothCore parent directory first: {realm.parent}")
    _run(["git", "clone", "--depth", "1", OFFICIAL_REPO, str(realm)])
    if not (realm / "docker-compose.yml").is_file():
        raise RuntimeError("Downloaded repository lacks docker-compose.yml")


def ensure_local_env(realm: Path) -> None:
    path = realm / ".env"
    if path.exists():
        if path.is_symlink():
            raise RuntimeError("Refusing to follow .env symlink")
        values = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                name, value = line.split("=", 1)
                values[name.strip()] = value.strip()
        if not values.get("DOCKER_DB_ROOT_PASSWORD") or any(
            values.get(name) != f"127.0.0.1:{port}"
            for name, port in LOCAL_PORTS.items()
        ):
            raise RuntimeError(
                f"Existing {path} must specify a DB password and all four "
                "127.0.0.1 port bindings. Refusing to overwrite it."
            )
        print("Reusing existing loopback-only AzerothCore .env")
        return
    password = secrets.token_hex(32)
    content = "# Local Addon Forge realm only. Keep private.\n"
    content += f"DOCKER_DB_ROOT_PASSWORD={password}\n"
    content += "".join(f"{name}=127.0.0.1:{port}\n"
                       for name, port in LOCAL_PORTS.items())
    with path.open("x", encoding="utf-8") as stream:
        stream.write(content)
    try:
        path.chmod(0o600)
    except OSError:
        pass  # Windows access rules are controlled by the user's ACLs.
    print("Created private Docker configuration with random DB password")


def check_compose(realm: Path) -> None:
    # Capture output: Compose config includes resolved DATABASE PASSWORD!
    # Never log it, even on errors.
    result = _run(["docker", "compose", "config", "--format", "json"],
                  cwd=realm, capture=True)
    config = json.loads(result.stdout)
    services = config.get("services", {})
    found = set()
    for name, service in services.items():
        for item in service.get("ports", []):
            port = int(item.get("target", -1))
            if (name, port) not in EXPECTED_PORTS or item.get("host_ip") != "127.0.0.1":
                raise RuntimeError(f"Unsafe Docker host binding: {name}:{port}. "
                                   "Only known loopback ports are permitted.")
            if str(item.get("published", "")) != str(port):
                raise RuntimeError(f"Unexpected forwarded port: {name}:{port}")
            found.add((name, port))
    if found != EXPECTED_PORTS:
        raise RuntimeError(f"Compose ports incomplete: {sorted(EXPECTED_PORTS - found)}")
    # Ensure a shell environment override did not silently replace .env secrets.
    values = {}
    for line in (realm / ".env").read_text(encoding="utf-8").splitlines():
        if line.startswith("DOCKER_DB_ROOT_PASSWORD="):
            values["pw"] = line.partition("=")[2]
    actual = services.get("ac-database", {}).get("environment", {}).get("MYSQL_ROOT_PASSWORD")
    if not values.get("pw") or actual != values["pw"]:
        raise RuntimeError("Docker environment overrides configured database password")
    print("Verified Docker Compose binds DB, auth, world and SOAP only to 127.0.0.1")


def check_tools() -> None:
    for binary in ("docker", "git"):
        if not shutil.which(binary):
            raise RuntimeError(f"Missing {binary}. Install Git and Docker Desktop first.")
    if os.environ.get("DOCKER_HOST"):
        raise RuntimeError("DOCKER_HOST is set: refusing possibly remote Docker daemon.")
    context = _run(["docker", "context", "show"], capture=True).stdout.strip()
    if context not in ("default", "desktop-linux"):
        raise RuntimeError(f"Unexpected Docker context {context!r}; use local Docker Desktop.")
    ostype = _run(["docker", "info", "--format", "{{.OSType}}"],
                  capture=True).stdout.strip()
    if ostype != "linux":
        raise RuntimeError("Docker must be running with Linux containers")
    _run(["docker", "compose", "version"], capture=True)


def _toml_path(path: Path) -> str:
    return json.dumps(path.as_posix())


def local_config_file(config_path: Path, target: Path, realm: Path) -> None:
    if config_path.exists():
        with config_path.open("rb") as stream:
            config = tomllib.load(stream)
        if (Path(config.get("client", {}).get("wow_dir", "")).resolve() != target
                or Path(config.get("realm", {}).get("source_dir", "")).resolve() != realm):
            raise RuntimeError(f"Existing config {config_path} points elsewhere; won't overwrite")
        return
    config = (
        "# Generated for the isolated local realm, not Rising Gods.\n"
        "[client]\n"
        f"wow_dir = {_toml_path(target)}\n"
        'window_name = "World of Warcraft"\n'
        "report_timeout = 60\n\n"
        "[realm]\n"
        f"source_dir = {_toml_path(realm)}\n"
    )
    with config_path.open("x", encoding="utf-8") as stream:
        stream.write(config)
    print(f"Wrote isolated test configuration: {config_path}")


def setup(source: Path, target: Path, realm: Path, locale: str | None,
          config_path: Path, *, approve: bool = False) -> None:
    source, target, realm = paths(source, target, realm)
    config_path = config_path.expanduser().resolve()
    print(f"Original WoW (untouched): {source}")
    print(f"Separate Forge WoW copy:  {target}")
    print(f"AzerothCore checkout:    {realm}")
    print(f"Forge test configuration: {config_path}")
    if config_path.name == "forge.toml":
        raise ValueError("Use forge.local.toml; refusing to overwrite your existing forge.toml")
    if not approve:
        print("Plan only. Run 'forge local-realm setup ... --approve-local-setup' "
              "to clone files, download/build Docker images and start local containers.")
        return
    check_tools()
    # Refuse to mutate arbitrary pre-existing client directories.
    verify_test_copy(target, source)
    clone_azerothcore(realm)
    ensure_local_env(realm)
    check_compose(realm)
    make_test_copy(source, target)
    client_realmlist, backup = configure_realmlist(target, locale=locale)
    print(f"Test realmlist: {client_realmlist} (backup: {backup})")
    local_config_file(config_path, target, realm)
    for path in ("wow/ForgeTestBridge", "examples/ForgeExample"):
        addon = Path.cwd() / path
        if not addon.is_dir():
            raise RuntimeError(f"Run setup from Addon Forge repository root: {addon}")
        print(f"Installed test addon: {deploy(addon, target)}")
    print("Building and starting the local AzerothCore containers...")
    _run(["docker", "compose", "up", "-d", "--build"], cwd=realm)
    print("Docker Compose started. Database/client-data imports may still be running.")
    _run(["docker", "compose", "ps"], cwd=realm)
    print("Next: forge local-realm status; when ac-worldserver is running, "
          "forge local-realm console; type 'account create FORGETEST YOUR_PASSWORD'.")
    print("Detach without stopping the server: Ctrl+P, then Ctrl+Q.")
    print(f"Use local WoW through: forge --config {config_path} client start")


def operate(action: str, realm: Path) -> int:
    realm = realm.expanduser().resolve()
    if not verify_azerothcore_checkout(realm):
        raise RuntimeError(f"AzerothCore not yet cloned into {realm}")
    check_tools()
    if not (realm / ".env").is_file():
        raise RuntimeError("No local realm .env found; run setup first")
    check_compose(realm)
    commands = {
        "status": ["docker", "compose", "ps", "--all"],
        "logs": ["docker", "compose", "logs", "--tail", "80", "ac-worldserver", "ac-authserver", "ac-db-import"],
        "stop": ["docker", "compose", "down"],  # Never remove volumes.
        "console": ["docker", "attach", "ac-worldserver"],
    }
    if action == "console":
        print("Worldserver console: account create FORGETEST YOUR_PASSWORD")
        print("Detach with Ctrl+P, Ctrl+Q. Ctrl+C can stop the worldserver!")
    return subprocess.run(commands[action], cwd=realm, check=False).returncode
