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
    try:
        return subprocess.run(argv, cwd=cwd, check=True, text=True,
                              capture_output=capture)
    except subprocess.CalledProcessError as exc:
        # Compose errors often contain useful detail on stderr already; do not
        # print resolved config or .env values, which can contain passwords.
        raise RuntimeError(
            f"{' '.join(argv)} exited with status {exc.returncode}. "
            "Use 'forge local-realm status' and 'forge local-realm logs' "
            "to diagnose the containers."
        ) from None


def _same_or_inside(path: Path, root: Path) -> bool:
    return path == root or path.is_relative_to(root)


def paths(source: Path | None, target: Path, realm: Path
          ) -> tuple[Path | None, Path, Path]:
    # Source is only necessary if Forge must create the test client.
    supplied = [p.expanduser() for p in (source, target, realm) if p is not None]
    if any(p.is_symlink() or (hasattr(p, "is_junction") and p.is_junction())
           for p in supplied):
        raise ValueError("Linked directories cannot be used for local realm setup")
    source = source.expanduser().resolve() if source is not None else None
    target, realm = target.expanduser().resolve(), realm.expanduser().resolve()
    if source is not None and not any(
            (source / exe).is_file() for exe in ("Wow.exe", "WoW.exe")):
        raise FileNotFoundError(f"No Wow.exe/ WoW.exe in source folder {source}")
    if source is None:
        if not target.is_dir() or not any(
                (target / exe).is_file() for exe in ("Wow.exe", "WoW.exe")):
            raise ValueError(
                "--source-wow is required to create a new test client. "
                "Without it, --test-wow must already contain Wow.exe."
            )
    pairs = [(target, realm), (realm, target)]
    if source is not None:
        pairs += [(source, target), (target, source),
                  (source, realm), (realm, source)]
    if any(_same_or_inside(left, right) for left, right in pairs):
        raise ValueError("The source, test client and AzerothCore paths must be separate")
    return source, target, realm


def verify_test_copy(target: Path, source: Path | None) -> bool:
    if not target.exists():
        return False
    marker = target / MARKER
    if not marker.is_file() or marker.is_symlink():
        raise RuntimeError(f"Refusing to modify existing unmarked folder: {target}")
    try:
        identity = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"Invalid test-client marker: {marker}") from exc
    if source is not None and identity.get("source") != str(source):
        raise RuntimeError("Existing test copy was made from a different source")
    if not any((target / exe).is_file() for exe in ("Wow.exe", "WoW.exe")):
        raise RuntimeError(f"Existing test copy is incomplete: {target}")
    return True



def adopt_existing_test_copy(source: Path | None, target: Path) -> None:
    """Explicitly register an already-copied WoW directory as Forge-only.

    Never remove copied account data. Move the copied WTF directory aside so
    the new test client does not reuse existing Rising Gods credentials.
    """
    if (target / MARKER).is_file():
        verify_test_copy(target, source)
        print(f"Reusing previously registered Forge test client: {target}")
        return
    if not target.is_dir() or target.is_symlink() or (
            hasattr(target, "is_junction") and target.is_junction()):
        raise RuntimeError("Adoption requires a real existing WoW test directory")
    if not any((target / exe).is_file() for exe in ("Wow.exe", "WoW.exe")):
        raise RuntimeError(f"Adoption requires Wow.exe/ WoW.exe inside {target}")
    # Refuse paths that could escape the chosen test directory when used later.
    _check_symlinks(target)
    wtf = target / "WTF"
    saved = target / ".forge-original-WTF-backup"
    if wtf.exists() and saved.exists():
        raise RuntimeError(
            "Found both WTF and .forge-original-WTF-backup in test copy. "
            "Resolve this manually before adoption; no files were changed."
        )
    if wtf.exists():
        if not wtf.is_dir():
            raise RuntimeError("Existing WTF is not a directory")
        wtf.rename(saved)
        print(f"Set aside copied game accounts/settings (not deleted): {saved}")
    (target / MARKER).write_text(json.dumps({"source": str(source) if source is not None else None,
                                             "adopted": True}),
                                encoding="utf-8")
    print(f"Registered existing WoW folder for Forge testing: {target}")


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


def _read_private_env(realm: Path) -> tuple[str, dict[str, str], int]:
    path = realm / ".env"
    if not path.is_file() or path.is_symlink():
        raise RuntimeError(f"Expected regular local AzerothCore .env: {path}")
    content = path.read_text(encoding="utf-8")
    values: dict[str, str] = {}
    for line in content.splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            key = key.strip()
            if key in values:
                raise RuntimeError(f"Duplicate setting {key} in .env; refusing to edit")
            values[key] = value.strip()
    if not values.get("DOCKER_DB_ROOT_PASSWORD"):
        raise RuntimeError("Missing local database password in .env")
    for name, internal_port in LOCAL_PORTS.items():
        value = values.get(name, "")
        if not value.startswith("127.0.0.1:"):
            raise RuntimeError(f"{name} must publish only on 127.0.0.1")
        try:
            external = int(value.rsplit(":", 1)[1])
        except ValueError as exc:
            raise RuntimeError(f"Invalid external port for {name}") from exc
        if not 1 <= external <= 65535:
            raise RuntimeError(f"Out-of-range external port for {name}")
        if name != "DOCKER_DB_EXTERNAL_PORT" and external != internal_port:
            raise RuntimeError(f"Unexpected external port in {name}")
    db_port = int(values["DOCKER_DB_EXTERNAL_PORT"].rsplit(":", 1)[1])
    if db_port in (3724, 8085, 7878):
        raise RuntimeError("Database host port collides with a realm service")
    return content, values, db_port


def ensure_local_env(realm: Path, *, db_port: int | None = None,
                     approve_port_change: bool = False) -> None:
    if db_port is not None and (
            not isinstance(db_port, int) or not 1 <= db_port <= 65535
            or db_port in (3724, 8085, 7878)):
        raise ValueError("Choose a valid database host port, e.g. 13306")
    path = realm / ".env"
    if path.exists():
        content, _, previous_port = _read_private_env(realm)
        if db_port is not None and db_port != previous_port:
            if not approve_port_change:
                raise ValueError(
                    "Changing the existing database port requires --approve-port-change"
                )
            # Never change someone else's hand-maintained .env file.
            if not content.startswith("# Local Addon Forge realm only. Keep private."):
                raise RuntimeError(
                    "Existing .env was not created by Addon Forge; refusing automatic edits"
                )
            old = f"DOCKER_DB_EXTERNAL_PORT=127.0.0.1:{previous_port}"
            new = f"DOCKER_DB_EXTERNAL_PORT=127.0.0.1:{db_port}"
            lines = content.splitlines(keepends=True)
            matches = [i for i, line in enumerate(lines) if line.strip() == old]
            if len(matches) != 1:
                raise RuntimeError("Ambiguous DB port setting; refusing automatic edits")
            lines[matches[0]] = lines[matches[0]].replace(old, new, 1)
            temp = path.with_name(f".env.forge-{secrets.token_hex(8)}")
            try:
                with temp.open("x", encoding="utf-8", newline="") as stream:
                    stream.writelines(lines)
                temp.chmod(0o600)
                temp.replace(path)
            finally:
                temp.unlink(missing_ok=True)
            _read_private_env(realm)
            print(f"Changed only the host-side MySQL port {previous_port} -> {db_port}.")
            print("Database password and internal Docker port 3306 are unchanged.")
        else:
            print("Reusing existing loopback-only AzerothCore .env")
        return
    if db_port is not None and not approve_port_change:
        raise ValueError("Using --db-port needs --approve-port-change")
    external_db = db_port if db_port is not None else LOCAL_PORTS["DOCKER_DB_EXTERNAL_PORT"]
    password = secrets.token_hex(32)
    content = "# Local Addon Forge realm only. Keep private.\n"
    content += f"DOCKER_DB_ROOT_PASSWORD={password}\n"
    content += "".join(
        f"{name}=127.0.0.1:{external_db if name == 'DOCKER_DB_EXTERNAL_PORT' else port}\n"
        for name, port in LOCAL_PORTS.items()
    )
    with path.open("x", encoding="utf-8") as stream:
        stream.write(content)
    try:
        path.chmod(0o600)
    except OSError:
        pass  # Windows access rules are controlled by the user's ACLs.
    print("Created private Docker configuration with random DB password")


def check_compose(realm: Path) -> None:
    # Capture output: Compose config includes resolved DATABASE PASSWORD!
    # Never print the JSON or captured stderr to logs.
    _, values, db_port = _read_private_env(realm)
    result = _run(["docker", "compose", "config", "--format", "json"],
                  cwd=realm, capture=True)
    config = json.loads(result.stdout)
    services = config.get("services", {})
    expected_published = {
        ("ac-database", 3306): db_port,
        ("ac-authserver", 3724): 3724,
        ("ac-worldserver", 8085): 8085,
        ("ac-worldserver", 7878): 7878,
    }
    found = set()
    for name, service in services.items():
        for item in service.get("ports", []):
            port = int(item.get("target", -1))
            key = (name, port)
            if key not in expected_published or item.get("host_ip") != "127.0.0.1":
                raise RuntimeError(
                    f"Unsafe Docker host binding: {name}:{port}. "
                    "Only known loopback ports are permitted."
                )
            if str(item.get("published", "")) != str(expected_published[key]):
                raise RuntimeError(f"Unexpected published host port: {name}:{port}")
            found.add(key)
    if found != EXPECTED_PORTS:
        raise RuntimeError(f"Compose ports incomplete: {sorted(EXPECTED_PORTS - found)}")
    actual = services.get("ac-database", {}).get("environment", {}).get("MYSQL_ROOT_PASSWORD")
    if actual != values["DOCKER_DB_ROOT_PASSWORD"]:
        raise RuntimeError("Docker environment overrides configured database password")
    print("Verified Docker Compose binds DB, auth, world and SOAP only to 127.0.0.1")
    print(f"Local MySQL uses 127.0.0.1:{db_port} -> container 3306")


def start_existing(realm: Path, *, db_port: int | None = None,
                   approve_port_change: bool = False) -> int:
    """Resume previously built local containers without rebuilding images."""
    realm = realm.expanduser().resolve()
    if not verify_azerothcore_checkout(realm):
        raise RuntimeError(f"No official AzerothCore checkout in {realm}")
    check_tools()
    ensure_local_env(realm, db_port=db_port,
                     approve_port_change=approve_port_change)
    check_compose(realm)
    print("Resuming existing images and volumes; no rebuild or data deletion.")
    _run(["docker", "compose", "up", "-d", "--no-build"], cwd=realm)
    _run(["docker", "compose", "ps"], cwd=realm)
    print("Realm containers requested; check logs if worldserver is not running.")
    return 0


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


def setup(source: Path | None, target: Path, realm: Path, locale: str | None,
          config_path: Path, *, approve: bool = False,
          adopt_existing: bool = False) -> None:
    source, target, realm = paths(source, target, realm)
    config_path = config_path.expanduser().resolve()
    print(f"Original WoW (untouched): {source if source else 'not supplied'}")
    print(f"Separate Forge WoW copy:  {target}")
    print(f"AzerothCore checkout:    {realm}")
    print(f"Forge test configuration: {config_path}")
    if config_path.name == "forge.toml":
        raise ValueError("Use forge.local.toml; refusing to overwrite your existing forge.toml")
    if source is None:
        print("No original source supplied: only the existing test WoW folder "
              "will be used. Verify this is NOT your Rising Gods installation.")
    if target.exists() and not (target / MARKER).is_file():
        if not adopt_existing:
            print("Existing test WoW folder has no Forge marker; will refuse to "
                  "modify it unless --adopt-existing-test-wow is provided.")
        else:
            print("Existing test WoW copy will be explicitly adopted, not copied. "
                  "Copied WTF settings will be moved aside without deletion.")
    elif target.exists():
        print("Previously registered Forge WoW test copy will be reused.")
    else:
        print("A new isolated WoW test copy will be created.")
    if realm.exists():
        print("Existing AzerothCore checkout will be verified and reused.")
    else:
        print("Official AzerothCore will be cloned.")
    if not approve:
        print("Plan only. Run 'forge local-realm setup ... --approve-local-setup' "
              "to clone/copy files, download/build Docker images and start local containers.")
        return
    check_tools()
    if target.exists() and not (target / MARKER).is_file():
        if not adopt_existing:
            raise RuntimeError(
                "Refusing to modify an existing unregistered WoW directory. "
                "Use --adopt-existing-test-wow only after verifying this is "
                "a separate COPY, not your Rising Gods original."
            )
        # Do this before modifying the AzerothCore checkout or Docker.
        adopt_existing_test_copy(source, target)
    else:
        verify_test_copy(target, source)
    clone_azerothcore(realm)
    ensure_local_env(realm)
    check_compose(realm)
    if not target.exists():
        if source is None:
            raise RuntimeError("Cannot create a test WoW folder without --source-wow")
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
