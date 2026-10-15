"""Marked test-copy check and Windows Credential Manager credentials.

The SDK login (wowcontrol.launch_and_enter) reads the account from the vault
and passes it over the PID-verified pipe; it is never typed, logged or put on a
command line. The former pixel-calibrated keyboard login was removed.
"""
from __future__ import annotations

import getpass
import hashlib
from pathlib import Path
import re
import sys

from .windows_client import _client_binary

TEST_MARKER = ".addon-forge-test-copy.json"


def _test_copy(wow_dir: Path) -> Path:
    wow = wow_dir.expanduser().resolve()
    marker = wow / TEST_MARKER
    if not marker.is_file() or marker.is_symlink():
        raise RuntimeError(
            "Automatic login requires a marked, isolated Forge test WoW copy; "
            "it will never run on an unmarked installation."
        )
    _client_binary(wow)
    return wow


def _vault_service(wow_dir: Path) -> str:
    import os
    # Case-insensitive Windows path: secrets scoped only to this test client.
    path = os.path.normcase(str(wow_dir.resolve()))
    return "AddonForge-WoW-Test-" + hashlib.sha256(path.encode("utf-8")).hexdigest()[:24]


def _vault():
    if sys.platform != "win32":
        raise RuntimeError("Automatic login is only available on native Windows.")
    try:
        import keyring
    except ImportError as exc:
        raise RuntimeError(
            "Windows Credential Manager support missing; run "
            r'.\.venv\Scripts\python.exe -m pip install -e ".[windows]"'
        ) from exc
    backend = keyring.get_keyring()
    if not type(backend).__module__.startswith("keyring.backends.Windows"):
        raise RuntimeError(
            "Expected Windows Credential Manager keyring backend; "
            "refusing to store credentials in a fallback/plaintext backend."
        )
    return keyring


def save_credentials(wow_dir: Path, account: str, *, read_password=None) -> None:
    wow = _test_copy(wow_dir)
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]{2,15}", account):
        raise ValueError("Use a 3-16 character ASCII test account name.")
    keyring = _vault()
    password = (read_password or getpass.getpass)("Local test account password (hidden): ")
    try:
        if not password or len(password) > 16 or not password.isascii() or not password.isprintable():
            raise ValueError("WoW test-account password must be 1-16 printable ASCII characters.")
        service = _vault_service(wow)
        keyring.set_password(service, "account", account.upper())
        keyring.set_password(service, "password", password)
    finally:
        password = ""
    print("Saved test-account credentials in Windows Credential Manager. "
          "Nothing was written to forge.local.toml or PowerShell history.")


def _credentials(wow_dir: Path) -> tuple[str, str]:
    keyring = _vault()
    service = _vault_service(wow_dir)
    account = keyring.get_password(service, "account")
    password = keyring.get_password(service, "password")
    if not account or not password:
        raise RuntimeError("No stored local test account. Run 'forge ... client login save --account FORGETEST'.")
    return account, password
