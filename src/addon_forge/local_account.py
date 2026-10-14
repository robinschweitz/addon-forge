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
