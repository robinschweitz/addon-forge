"""Safe video configuration for a dedicated WotLK 3.3.5a test client.

The game must be closed before changes: its client writes Config.wtf at exit.
"""
from __future__ import annotations

from pathlib import Path
import re


def configure_windowed(wow_dir: Path, *, resolution: str = "1280x720",
                       maximized: bool = False) -> tuple[Path, Path | None]:
    match = re.fullmatch(r"([1-9][0-9]{2,4})x([1-9][0-9]{2,4})", resolution)
    if match is None:
        raise ValueError("Resolution must look like 1280x720")
    width, height = (int(value) for value in match.groups())
    if not (640 <= width <= 7680 and 480 <= height <= 4320):
        raise ValueError("Choose resolution between 640x480 and 7680x4320")
    wow = wow_dir.expanduser().resolve()
    if not (wow / "Wow.exe").is_file() and not (wow / "WoW.exe").is_file():
        raise FileNotFoundError(f"WoW.exe not found in {wow}")
    wtf = wow / "WTF"
    if wtf.is_symlink() or (hasattr(wtf, "is_junction") and wtf.is_junction()):
        raise RuntimeError("Refusing to edit linked WTF directory")
    if not wtf.exists():
        wtf.mkdir()
    path = wtf / "Config.wtf"
    if path.is_symlink() or not path.resolve().is_relative_to(wow):
        raise RuntimeError("Unsafe Config.wtf path")
    if path.exists() and not path.is_file():
        raise RuntimeError("Config.wtf is not a regular file")
    backup = path.with_name("Config.wtf.forge-backup")
    original = path.read_bytes() if path.exists() else None
    try:
        source = original.decode("utf-8-sig") if original is not None else ""
    except UnicodeDecodeError as exc:
        raise RuntimeError("Config.wtf is not UTF-8; edit the video settings manually") from exc
    changed = source
    for key, value in (
        ("gxWindow", "1"),
        ("gxMaximize", "1" if maximized else "0"),
        ("gxResolution", resolution),
    ):
        updated = f'SET {key} "{value}"'
        changed, count = re.subn(
            rf"(?im)^[ \t]*SET[ \t]+{key}[ \t]+[^\r\n]*",
            lambda _: updated,
            changed,
        )
        if count > 1:
            raise RuntimeError(f"Multiple {key} settings in Config.wtf; edit manually")
        if not count:
            changed = changed.rstrip("\r\n") + ("\n" if changed.strip() else "") + updated + "\n"
    if changed == source:
        return path, backup if backup.is_file() else None
    if backup.exists():
        raise RuntimeError(f"Existing backup {backup}; will not overwrite video settings")
    if original is not None:
        with backup.open("xb") as stream:
            stream.write(original)
    path.write_bytes(changed.encode("utf-8"))
    return path, backup if original is not None else None
