"""Verified character selection for a marked, isolated WotLK test client.

One-time manual calibration captures static character-selection UI features and
the *visible selected character name*, never credentials. Later runs enter the
world only when all three pixel signatures match in the verified WoW process.
No injected DLL, patched binary, OCR or arbitrary GlueXML is necessary.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import time

from .config import Config
from .win_login import (
    _test_copy, _point, _patch, _encode, _image, _deviation,
    PATCH_SIZE, MAX_DIFFERENCE,
)
from .windows_client import WindowsAPI, _client_binary

CALIBRATION = ".addon-forge-character-calibration.json"
NAME = re.compile(r"[A-Za-z]{2,12}")


def _ensure_name(character: str) -> None:
    if not NAME.fullmatch(character):
        raise ValueError("Character name must be 2-12 ASCII letters")


def calibrate_character(cfg: Config, character: str, *, api: WindowsAPI | None = None) -> Path:
    """One-time supervised setup on the character-selection screen."""
    _ensure_name(character)
    wow = _test_copy(cfg.wow_dir)
    api = api or WindowsAPI()
    hwnd = api.find_window(cfg.window_name, _client_binary(wow))
    print("ONE-TIME SETUP: select character " + character +
          " on the TEST realm, but do NOT enter the world yet.")
    print("Use the same window position and resolution for later unattended runs.")
    first = _point(api, hwnd, "Point at a static CHARACTER-SELECTION UI label/ornament (marker 1).")
    second = _point(api, hwnd, "Point at a DIFFERENT static character-selection UI marker (marker 2).")
    if abs(first[0]-second[0]) + abs(first[1]-second[1]) < 80:
        raise RuntimeError("Character-selection UI markers must be far apart.")
    name = _point(api, hwnd, "Point at the middle of the SELECTED CHARACTER NAME text "
                  "so its exact pixels are included in the name signature.")
    if any(abs(name[0]-p[0]) + abs(name[1]-p[1]) < 56 for p in (first, second)):
        raise RuntimeError("Name marker must be separate from the fixed screen markers.")
    rect = api.rect(hwnd)
    image = _image(rect)
    markers = [{"point": list(p), "rgb": _encode(_patch(image, p))}
               for p in (first, second, name)]
    for marker in markers:
        data = __import__("zlib").decompress(__import__("base64").b64decode(marker["rgb"]))
        if max(data) - min(data) < 45:
            raise RuntimeError("Calibration marker lacks contrast; select a static text/ornament detail.")
    data = {"version": 1, "character": character,
            "dimensions": [rect[2]-rect[0], rect[3]-rect[1]],
            "markers": markers}
    path = wow / CALIBRATION
    if path.exists() or path.is_symlink():
        raise RuntimeError("Character calibration already exists; inspect/remove it explicitly before recalibrating.")
    with path.open("x", encoding="utf-8") as file:
        json.dump(data, file)
    return path


def read_character_calibration(wow: Path, character: str) -> dict:
    _ensure_name(character)
    path = wow / CALIBRATION
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 16000:
        raise RuntimeError("No valid character-selection calibration. "
                           "Run 'forge client character calibrate --character NAME' once.")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        markers = data["markers"]
        dimensions = data["dimensions"]
        if (data["version"] != 1 or data["character"] != character or
            len(markers) != 3 or not isinstance(dimensions, list) or len(dimensions) != 2 or
            any(type(n) is not int or n < PATCH_SIZE*2 or n > 16000 for n in dimensions)):
            raise ValueError("Calibration does not match the requested character")
        import base64
        import zlib
        for m in markers:
            point = m["point"]
            if (not isinstance(point, list) or len(point) != 2 or
                any(type(n) is not int for n in point) or
                not (PATCH_SIZE <= point[0] < dimensions[0] - PATCH_SIZE) or
                not (PATCH_SIZE <= point[1] < dimensions[1] - PATCH_SIZE)):
                raise ValueError("Invalid calibration point")
            compressed = base64.b64decode(m["rgb"], validate=True)
            if len(compressed) > 10000:
                raise ValueError("Invalid calibration patch size")
            patch = zlib.decompress(compressed)
            if len(patch) != PATCH_SIZE*PATCH_SIZE*3:
                raise ValueError("Invalid calibration patch pixels")
    except (ValueError, TypeError, KeyError, UnicodeError, OSError, AttributeError,
            __import__("binascii").Error, __import__("zlib").error) as exc:
        raise RuntimeError("Invalid character-selection calibration; no input was sent.") from exc
    return data


def _matches_character(api: WindowsAPI, hwnd: int, data: dict) -> bool:
    rect = api.rect(hwnd)
    if [rect[2]-rect[0], rect[3]-rect[1]] != data["dimensions"]:
        return False
    import base64
    import zlib
    screenshot = _image(rect)
    return all(_deviation(zlib.decompress(base64.b64decode(m["rgb"])),
                          _patch(screenshot, tuple(m["point"])).tobytes()) <= MAX_DIFFERENCE
               for m in data["markers"])


def enter_character(cfg: Config, character: str, *, pid: int,
                    api: WindowsAPI | None = None, wait_seconds: int = 100) -> None:
    """Wait for the exact selected character screen and press Enter once."""
    wow = _test_copy(cfg.wow_dir)
    data = read_character_calibration(wow, character)
    api = api or WindowsAPI()
    binary = _client_binary(wow)
    deadline = time.monotonic() + wait_seconds
    stable = 0
    while time.monotonic() < deadline:
        hwnd = api.find_window(cfg.window_name, binary)
        if api.window_pid(hwnd) != pid:
            raise RuntimeError("Character-selection WoW window belongs to a different process.")
        if _matches_character(api, hwnd, data):
            stable += 1
            if stable >= 3:
                api.focus(hwnd)
                if api.window_pid(hwnd) != pid or not _matches_character(api, hwnd, data):
                    raise RuntimeError("Character-selection screen changed before Enter; refusing input.")
                api.tap(0x0D)
                # Wait for the selected screen to go away before allowing any
                # in-world /forge commands. The subsequent report is definitive.
                changed = 0
                until = time.monotonic() + 45
                while time.monotonic() < until:
                    if api.window_pid(hwnd) != pid:
                        raise RuntimeError("WoW process changed during world entry.")
                    if not _matches_character(api, hwnd, data):
                        changed += 1
                        if changed >= 3:
                            time.sleep(8)  # Allow world-loading/PLAYER_ENTERING_WORLD
                            return
                    else:
                        changed = 0
                    time.sleep(0.6)
                raise RuntimeError("Character-selection screen did not transition into the world.")
        else:
            stable = 0
        time.sleep(0.7)
    raise RuntimeError("Verified selected character " + character +
                       " was not visible; nothing was selected or entered.")
