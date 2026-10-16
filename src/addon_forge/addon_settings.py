"""Per-character addon selection in the isolated test client.

WoW 3.3.5a keeps which addons a character loads in
WTF/Account/<ACCOUNT>/<Realm>/<Character>/AddOns.txt ("Name: enabled" or
"Name: disabled"); addons missing from the file load. A two-player plan uses
this to give the second player only the addons a real raid member would run.
"""
from __future__ import annotations

import re
from pathlib import Path

ACCOUNT = re.compile(r"[A-Z][A-Z0-9]{2,15}\Z")
REALM = re.compile(r"[A-Za-z0-9 _-]{2,64}\Z")
CHARACTER = re.compile(r"[A-Za-z]{2,12}\Z")
ALWAYS = ("ForgeTestBridge",)   # the plan's observer must load everywhere


def installed_addons(wow_dir: Path) -> list[str]:
    """Non-Blizzard addon folders (with a matching .toc) of the test client."""
    root = wow_dir / "Interface" / "AddOns"
    return sorted(p.name for p in root.iterdir()
                  if p.is_dir() and not p.name.startswith("Blizzard_") and (p / f"{p.name}.toc").is_file())


def write_character_addons(wow_dir: Path, account: str, realm: str, character: str,
                           enabled: list[str] | tuple[str, ...]) -> Path:
    """Enable exactly `enabled` (plus the test bridge) for one character."""
    if not ACCOUNT.fullmatch(account) or not REALM.fullmatch(realm) or not CHARACTER.fullmatch(character):
        raise ValueError("Invalid account, realm or character for AddOns.txt")
    wanted = set(enabled) | set(ALWAYS)
    addons = installed_addons(wow_dir)
    missing = wanted - set(addons)
    if missing:
        raise RuntimeError(f"Addons not installed in the test client: {sorted(missing)}")
    folder = wow_dir / "WTF" / "Account" / account / realm / character
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "AddOns.txt"
    lines = [f"{name}: {'enabled' if name in wanted else 'disabled'}" for name in addons]
    path.write_text("\r\n".join(lines) + "\r\n", encoding="utf-8")
    return path
