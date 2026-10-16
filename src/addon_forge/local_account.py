"""Opt-in local AzerothCore account creation via its own worldserver console.

The official account command creates SRP6 credentials. Never write account
passwords into shell history, process argv, a Git file or MySQL SQL.
"""
from __future__ import annotations

import getpass
import re
import subprocess

ACCOUNT_PATTERN = re.compile(r"[A-Za-z][A-Za-z0-9]{2,15}\Z")
PASSWORD_PATTERN = re.compile(r"[!-~]{8,16}\Z")


CHARACTER_PATTERN = re.compile(r"[A-Z][a-z]{1,11}\Z")


def create_member_account(cfg, account: str, character: str, *, run=None, save=None) -> str:
    """Create the second test player (account + character) for two-client plans.

    The account must not exist yet (the fixture refuses existing ones, so no
    credentials are ever reset). A random password is generated here, passed
    only through the Go fixture's environment, and stored in the "member"
    Windows Credential Manager slot once the fixture succeeded. Returns the
    character name the realm accepted.
    """
    import json
    import secrets
    import string
    import tempfile
    from pathlib import Path

    from .agent_realm import _go_environment, _preflight
    from .win_login import save_credentials

    if not ACCOUNT_PATTERN.fullmatch(account):
        raise ValueError("Account name must be 3-16 ASCII letters/digits and start with a letter")
    if not CHARACTER_PATTERN.fullmatch(character):
        raise ValueError("Character name must be 2-12 letters, capitalized (e.g. Raidmember)")
    db_password, port = _preflight(Path(cfg.realm_dir).resolve())
    alphabet = string.ascii_letters + string.digits
    password = "".join(secrets.choice(alphabet) for _ in range(16))
    try:
        with tempfile.TemporaryDirectory(prefix="forge-member-") as folder:
            result = Path(folder) / "result.json"
            env = _go_environment()
            env.pop("E2E_ALLOW_SOFT_PASS", None)
            env.update({
                "E2E_AUTH_ADDR": "127.0.0.1:3724",
                "E2E_AUTH_DSN": f"root:{db_password}@tcp(127.0.0.1:{port})/acore_auth",
                "E2E_CHAR_DSN": f"root:{db_password}@tcp(127.0.0.1:{port})/acore_characters",
                "E2E_WORLD_DSN": f"root:{db_password}@tcp(127.0.0.1:{port})/acore_world",
                "FORGE_MEMBER_USER": account.upper(), "FORGE_MEMBER_PASSWORD": password,
                "FORGE_MEMBER_CHAR": character, "FORGE_MEMBER_RESULT": str(result),
            })
            proc = (run or subprocess.run)(
                ["go", "test", "-tags=e2e", "-run", "^TestCreateMemberAccount$", "-count=1", "-v",
                 "-timeout", "180s"],
                cwd=Path(__file__).resolve().parents[2] / "agent_scenarios", env=env,
                capture_output=True, text=True, timeout=240, check=False)
            if proc.returncode != 0 or not result.is_file():
                tail = (proc.stdout or "")[-1500:].replace(password, "<redacted>")
                raise RuntimeError("Member account fixture failed:\n" + tail)
            created = json.loads(result.read_text(encoding="utf-8"))
        (save or save_credentials)(cfg.wow_dir, account, read_password=lambda _prompt: password, slot="member")
        return str(created.get("character"))
    finally:
        password = ""


def create_test_account(account: str, *, input_password=None, attach=None) -> None:
    if not ACCOUNT_PATTERN.fullmatch(account):
        raise ValueError("Account name must be 3-16 ASCII letters/digits and start with a letter")
    read = input_password or getpass.getpass
    password = read("New local AzerothCore account password (not your Rising Gods password): ")
    try:
        if not PASSWORD_PATTERN.fullmatch(password):
            raise ValueError("Choose 8-16 printable ASCII characters without spaces")
        # The password is sent directly to the local worldserver's STDIN via
        # docker attach. No shell history or docker exec argv includes it.
        # TTY detach keys ^P^Q preserve the worldserver process.
        command = f"account create {account.upper()} {password}\n".encode("ascii")
        operation = attach or subprocess.run
        result = operation(
            ["docker", "attach", "--sig-proxy=false",
             "--detach-keys=ctrl-p,ctrl-q", "ac-worldserver"],
            input=command + b"\x10\x11", capture_output=True, timeout=12,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError("Worldserver account command could not be submitted. "
                               "Inspect worldserver logs, then check whether the account exists.")
        print(f"Account creation command submitted for {account.upper()}. "
              "Confirm login in the game client.")
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            "Docker attach timed out. The account may have been created; "
            "check before trying again. Do not interrupt the worldserver."
        ) from None
    finally:
        password = ""  # Do not retain the reference any longer than necessary.
