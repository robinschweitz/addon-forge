"""Experimental Windows-only auto-login for a marked, isolated WoW test copy.

Credentials live in Windows Credential Manager via keyring. A one-time
calibration records two user-chosen STATIC login-panel regions. The launcher
checks both signatures in the freshly started verified WoW.exe before any
password keystrokes; it refuses if they are missing/changed.
"""
from __future__ import annotations

import base64
import getpass
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import zlib

from .windows_client import WindowsAPI, _client_binary
from .config import Config

CALIBRATION = ".addon-forge-login-calibration.json"
TEST_MARKER = ".addon-forge-test-copy.json"
PATCH_SIZE = 48
# Mean RGB absolute deviation per channel. Keep intentionally strict; a
# false negative is preferable to sending a password to game chat.
MAX_DIFFERENCE = 8.0


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


def _image(rect: tuple[int, int, int, int]):
    try:
        from PIL import ImageGrab
    except ImportError as exc:
        raise RuntimeError("Pillow required; install the Windows Forge extras.") from exc
    return ImageGrab.grab(bbox=rect, all_screens=True).convert("RGB")


def _point(api: WindowsAPI, hwnd: int, prompt: str) -> tuple[int, int]:
    print(prompt)
    input("Move the mouse to the spot in the WoW window, then press Enter here...")
    x, y = api.cursor()
    left, top, right, bottom = api.rect(hwnd)
    if not (left + PATCH_SIZE <= x < right - PATCH_SIZE and
            top + PATCH_SIZE <= y < bottom - PATCH_SIZE):
        raise RuntimeError("Selected point must be inside the WoW window, away from its borders.")
    return x - left, y - top


def _patch(screen, point: tuple[int, int]):
    x, y = point
    half = PATCH_SIZE // 2
    return screen.crop((x - half, y - half, x + half, y + half))


def _encode(patch) -> str:
    # Calibration stores a tiny compressed RGB patch, never a password or a
    # full login screenshot. Tell users to choose STATIC non-sensitive details.
    return base64.b64encode(zlib.compress(patch.tobytes(), 9)).decode("ascii")


def _deviation(a: bytes, b: bytes) -> float:
    if len(a) != len(b) or not a:
        raise ValueError("Invalid login-screen calibration patch")
    return sum(abs(x-y) for x,y in zip(a,b)) / len(a)


def calibrate(cfg: Config, *, api: WindowsAPI | None = None) -> Path:
    wow = _test_copy(cfg.wow_dir)
    api = api or WindowsAPI()
    hwnd = api.find_window(cfg.window_name, _client_binary(wow))
    print("ONE-TIME CALIBRATION. Be at WoW's ACCOUNT/PASSWORD LOGIN SCREEN, "
          "not in-game. Clear both fields first.")
    print("Choose distinctive, non-animated and non-sensitive pixels on the login PANEL "
          "(e.g. fixed labels or ornamentation). Don't select the game background, "
          "password fields, or blinking caret.")
    a = _point(api, hwnd, "Choose a STATIC point on the login panel (marker 1).")
    b = _point(api, hwnd, "Choose a different STATIC point on the login panel (marker 2).")
    if abs(a[0]-b[0]) + abs(a[1]-b[1]) < 80:
        raise RuntimeError("Choose two distinct login panel areas for visual verification.")
    name = _point(api, hwnd, "Choose the CENTER of the ACCOUNT NAME field.")
    password = _point(api, hwnd, "Choose the CENTER of the PASSWORD field.")
    if abs(name[1]-password[1]) < 15:
        raise RuntimeError("Account and password points must be separate fields.")
    rect = api.rect(hwnd)
    screen = _image(rect)
    template = {
        "version": 1,
        "dimensions": [rect[2]-rect[0], rect[3]-rect[1]],
        "markers": [{"point": list(p), "rgb": _encode(_patch(screen, p))}
                    for p in (a, b)],
        "fields": {"account": list(name), "password": list(password)}
    }
    # Refuse blank/textureless regions, which are unsafe visual identifiers.
    for marker in template["markers"]:
        raw = zlib.decompress(base64.b64decode(marker["rgb"]))
        spread = max(raw) - min(raw)
        if spread < 45:
            raise RuntimeError("A marker has too little visual detail. "
                               "Choose a high-contrast label or fixed design on the login panel.")
    path = wow / CALIBRATION
    if path.is_symlink():
        raise RuntimeError("Refusing linked calibration path")
    if path.exists():
        raise RuntimeError(f"Existing calibration {path}; remove it manually to recalibrate.")
    with path.open("x", encoding="utf-8") as out:
        json.dump(template, out)
    print("Login-screen calibration saved for this TEST client only. "
          "No account password is in the calibration.")
    return path


def _read_calibration(wow_dir: Path) -> dict:
    path = wow_dir / CALIBRATION
    if not path.is_file() or path.is_symlink():
        raise RuntimeError("No login calibration; run 'forge ... client login calibrate' "
                           "at the test client's login screen first.")
    data = json.loads(path.read_text(encoding="utf-8"))
    if (data.get("version") != 1 or len(data.get("markers", [])) != 2
            or not isinstance(data.get("dimensions"), list)
            or set(data.get("fields", {})) != {"account", "password"}):
        raise RuntimeError("Invalid login calibration; refusing to send credentials.")
    return data


def _matches(api: WindowsAPI, hwnd: int, template: dict) -> bool:
    rect = api.rect(hwnd)
    if [rect[2]-rect[0], rect[3]-rect[1]] != template["dimensions"]:
        return False
    screen = _image(rect)
    for marker in template["markers"]:
        expected = zlib.decompress(base64.b64decode(marker["rgb"]))
        current = _patch(screen, tuple(marker["point"])).tobytes()
        if _deviation(expected, current) > MAX_DIFFERENCE:
            return False
    return True


def _wait_verified_window(cfg: Config, api: WindowsAPI, pid: int,
                          *, seconds: int = 65) -> int:
    end = time.monotonic() + seconds
    stable = 0
    while time.monotonic() < end:
        try:
            hwnd = api.find_window(cfg.window_name, _client_binary(cfg.wow_dir))
            if api.window_pid(hwnd) != pid:
                raise RuntimeError(
                    "The visible WoW window belongs to another process; "
                    "automatic login stopped."
                )
            if _matches(api, hwnd, _read_calibration(cfg.wow_dir)):
                stable += 1
                if stable >= 3:
                    return hwnd
            else:
                stable = 0
        except RuntimeError as exc:
            # Zero windows is normal until the newly launched client appears.
            if "found 0." not in str(exc):
                raise
        time.sleep(0.7)
    raise RuntimeError(
        "Could not verify the calibrated login screen in the newly launched WoW window. "
        "No credentials were typed. Check windowed resolution, visual markers, "
        "and whether the account/password screen is visible."
    )


def start_and_login(cfg: Config, *, api: WindowsAPI | None = None,
                    launcher=None) -> int:
    wow = _test_copy(cfg.wow_dir)
    # Fail closed BEFORE launching the game when configuration is incomplete.
    calibration = _read_calibration(wow)
    account, password = _credentials(wow)
    api = api or WindowsAPI()
    binary = _client_binary(wow)
    try:
        api.find_window(cfg.window_name, binary)
    except RuntimeError as exc:
        if "found 0." not in str(exc):
            raise
    else:
        raise RuntimeError(
            "WoW is already running. Close the existing client first: automatic "
            "login only operates on a freshly launched, verified test client."
        )
    launch = launcher or subprocess.Popen
    process = launch([str(binary)], cwd=str(wow))
    hwnd = _wait_verified_window(cfg, api, process.pid)
    api.focus(hwnd)
    if not _matches(api, hwnd, calibration):
        raise RuntimeError("Login screen changed after focus; credentials not typed.")
    # No clipboard, stdout, command args, config file or chat commands used.
    api.click(hwnd, tuple(calibration["fields"]["account"]))
    api.ctrl_a()
    api.type_text(account, hwnd=hwnd)
    time.sleep(0.15)
    api.focus(hwnd)
    if not _matches(api, hwnd, calibration):
        raise RuntimeError("Login screen changed before password entry; password not typed.")
    api.click(hwnd, tuple(calibration["fields"]["password"]))
    api.ctrl_a()
    api.type_text(password, hwnd=hwnd)
    api.tap(0x0D)
    print("Credentials submitted to the verified WoW login screen. "
          "Check the game for login success and select your test character.")
    return process.pid
