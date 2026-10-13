"""Conservative MySQL volume / password checks for local AzerothCore.

Docker's MySQL image only applies MYSQL_ROOT_PASSWORD when the data directory
is *first initialized*. A generated new .env must not silently reuse an older
database volume with credentials stored in that existing database.
"""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import time


def _capture(argv: list[str], *, cwd: Path | None = None):
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, check=False)


def block_unknown_database_volume(realm: Path) -> None:
    """Fail closed before creating new DB credentials if a data volume exists.

    Compose resolves project naming and override files; never guess a volume
    name from the checkout path. No volumes are opened, modified or deleted.
    """
    if (realm / ".env").exists():
        return
    composed = _capture(["docker", "compose", "config", "--format", "json"], cwd=realm)
    if composed.returncode:
        raise RuntimeError("Cannot inspect Docker Compose database storage. "
                           "No new database password was generated.")
    try:
        definition = json.loads(composed.stdout)
        mounts = definition["services"]["ac-database"]["volumes"]
    except (ValueError, KeyError, TypeError) as exc:
        raise RuntimeError("Could not resolve the MySQL storage mount. "
                           "Refusing to initialize credentials.") from exc
    db_mounts = [entry for entry in mounts
                 if entry.get("target", "").rstrip("/") == "/var/lib/mysql"]
    if len(db_mounts) != 1:
        raise RuntimeError("Expected exactly one MySQL data mount. "
                           "Refusing to initialize credentials.")
    mount = db_mounts[0]
    if mount.get("type") != "volume":
        raise RuntimeError("AzerothCore MySQL uses a non-volume data mount. "
                           "Configure its existing credentials manually before setup.")
    volume_key = mount.get("source")
    volume = definition.get("volumes", {}).get(volume_key, {}).get("name", volume_key)
    if not isinstance(volume, str) or not volume:
        raise RuntimeError("Could not identify the existing database volume safely.")
    # docker volume inspect exits 1 when a volume doesn't exist; distinguish
    # an actual missing volume from other failures with 'volume ls'?
    inspect = _capture(["docker", "volume", "inspect", volume])
    if inspect.returncode == 0:
        raise RuntimeError(
            f"Existing MySQL volume '{volume}' found, but no matching .env exists. "
            "A new password would not be applied to the existing database. "
            "Stop here: restore the original AzerothCore .env or reconcile "
            "the existing MySQL root password first. "
            "Forge will not erase the volume or invent a replacement password."
        )
    if inspect.returncode != 1:
        raise RuntimeError("Docker could not inspect the MySQL data volume.")
    # docker volume inspect often exits 1 for both missing and connection
    # errors. Verify we can enumerate volumes before trusting the result.
    listed = _capture(["docker", "volume", "ls", "--format", "{{.Name}}"])
    if listed.returncode:
        raise RuntimeError("Docker cannot enumerate volumes; refusing new credentials.")
    if volume in listed.stdout.splitlines():
        raise RuntimeError("MySQL data volume exists but volume inspect failed.")
    print("No existing AzerothCore MySQL data volume detected. "
          "Safe to initialize a new database password.")


def verify_database_healthy(realm: Path, *, attempts: int = 25,
                            interval: float = 2) -> None:
    """Start MySQL only; require its credential-authenticated health check.

    This is run *before* Compose may start db-import or worldserver.
    No passwords are logged or passed in CLI argument lists.
    """
    started = _capture(["docker", "compose", "up", "-d", "--no-deps", "ac-database"], cwd=realm)
    if started.returncode:
        raise RuntimeError(
            "Could not start the AzerothCore MySQL container. "
            "Check Docker Desktop, local MySQL port availability, and 'docker compose ps'."
        )
    for attempt in range(attempts):
        result = _capture(["docker", "inspect", "--format",
                           "{{json .State.Health}}", "ac-database"])
        if result.returncode:
            raise RuntimeError("Cannot read the AzerothCore MySQL health check.")
        try:
            health = json.loads(result.stdout)
        except ValueError as exc:
            raise RuntimeError("Invalid Docker MySQL health information.") from exc
        if not isinstance(health, dict):
            raise RuntimeError("MySQL container has no health check; refusing to proceed.")
        state = health.get("Status")
        if state == "healthy":
            print("MySQL health check passed using the configured database password.")
            return
        entries = health.get("Log", [])
        if any("ERROR 1045" in entry.get("Output", "")
               or "Access denied for user" in entry.get("Output", "")
               for entry in entries):
            raise RuntimeError(
                "MySQL is rejecting the database password configured in .env "
                "(ERROR 1045). The existing MySQL volume may have been initialized "
                "with a different password. Restore or reconcile the existing "
                "root credentials; do not delete database volumes. "
                "Forge has not started the importer or worldserver."
            )
        if state not in ("starting", "unhealthy"):
            raise RuntimeError(f"MySQL health check returned unexpected state {state!r}.")
        if attempt < attempts - 1:
            time.sleep(interval)
    raise RuntimeError(
        "MySQL did not become healthy in time. Inspect 'docker compose logs ac-database' "
        "and 'docker inspect ac-database'. No database data was removed."
    )
