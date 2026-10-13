#!/usr/bin/env python3
"""Verify rendered AzerothCore Compose semantics, not just JSON syntax.

Expected inputs are *resolved* output from `docker compose config --format json`.
This is intentionally Docker-daemon-independent and suitable for Nix builds.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REQUIRED = {
    "ac-database",
    "ac-client-data",
    "ac-db-import",
    "ac-authserver",
    "ac-worldserver",
}


def validate(config: dict) -> list[str]:
    problems: list[str] = []
    services = config.get("services", {})
    for name in sorted(REQUIRED - services.keys()):
        problems.append(f"Missing service: {name}")
    if problems:
        return problems

    for name, expected_port in (("ac-authserver", 3724), ("ac-worldserver", 8085)):
        ports = services[name].get("ports", [])
        matches = [p for p in ports if int(p.get("target", -1)) == expected_port]
        if len(matches) != 1 or matches[0].get("host_ip") != "127.0.0.1":
            problems.append(f"{name}: TCP {expected_port} must bind only to 127.0.0.1")
        elif str(matches[0].get("published", "")) != str(expected_port):
            problems.append(f"{name}: incorrect published port")

    for name, service in services.items():
        if name not in {"ac-authserver", "ac-worldserver"} and service.get("ports"):
            problems.append(f"{name}: should not expose host ports")

    password = services["ac-database"].get("environment", {}).get("MYSQL_ROOT_PASSWORD")
    if password != "ci-placeholder-not-a-secret":
        problems.append("MySQL password was not interpolated from the external .env")
    for name in ("ac-authserver", "ac-worldserver", "ac-db-import"):
        database_string = services[name].get("environment", {}).get("AC_LOGIN_DATABASE_INFO", "")
        if ";ci-placeholder-not-a-secret;" not in database_string:
            problems.append(f"{name}: database password interpolation missing")

    mounts = services["ac-database"].get("volumes", [])
    if not any(m.get("type") == "volume" and m.get("target") == "/var/lib/mysql" for m in mounts):
        problems.append("Database lacks persistent volume at /var/lib/mysql")

    importer = services["ac-db-import"].get("depends_on", {}).get("ac-database", {})
    if importer.get("condition") != "service_healthy":
        problems.append("Database import must wait for MySQL healthcheck")

    for name in ("ac-authserver", "ac-worldserver"):
        dep = services[name].get("depends_on", {}).get("ac-db-import", {})
        if dep.get("condition") != "service_completed_successfully":
            problems.append(f"{name}: must wait for completed database import")
    return problems


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_compose.py RENDERED_JSON", file=sys.stderr)
        return 2
    config = json.loads(Path(sys.argv[1]).read_text())
    errors = validate(config)
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    if errors:
        return 1
    print("AzerothCore Compose topology, credentials, ports and volume validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
