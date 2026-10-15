"""Deploy an addon into the client's Interface/AddOns tree with safe rollback."""
from pathlib import Path
import os
import shutil
import tempfile

from .validate import check_addon, is_valid

SKIP = {".git", "__pycache__", ".pytest_cache", "tests", ".forge-runs"}


def _files(root: Path) -> dict[str, bytes]:
    out = {}
    if not root.is_dir():
        return out
    for path in root.rglob("*"):
        rel = path.relative_to(root)
        if path.is_file() and not SKIP & set(rel.parts):
            out[rel.as_posix().lower()] = path.read_bytes()
    return out


def differs(addon: Path, wow_dir: Path) -> bool:
    """True when deploying would change what is installed in the client.

    A running client keeps the addon code it loaded at startup, so a change
    means the client must restart (or /reload) before tests see it.
    """
    addon = addon.expanduser().resolve()
    installed = wow_dir.expanduser().resolve() / "Interface" / "AddOns" / addon.name
    return _files(addon) != _files(installed)


def deploy(addon: Path, wow_dir: Path) -> Path:
    addon = addon.expanduser().resolve()
    issues = check_addon(addon)
    if not is_valid(issues):
        raise ValueError("Cannot deploy invalid addon: " + "; ".join(d.message for d in issues if d.severity == "error"))
    if any(p.is_symlink() for p in addon.rglob("*")):
        raise ValueError("Addon source contains symlinks")
    root = wow_dir.expanduser().resolve() / "Interface" / "AddOns"
    if not (wow_dir / "Wow.exe").is_file() and not (wow_dir / "WoW.exe").is_file():
        raise FileNotFoundError(f"Expected Wow.exe in {wow_dir}")
    root.mkdir(parents=True, exist_ok=True)
    dest = root / addon.name
    if not dest.resolve().is_relative_to(root.resolve()):
        raise ValueError("Unsafe destination")
    temp = Path(tempfile.mkdtemp(prefix=".forge-stage-", dir=root))
    backup = root / (".forge-backup-" + addon.name)
    try:
        # copy contents, not the source directory itself
        for item in addon.iterdir():
            if item.name in SKIP:
                continue
            target = temp / item.name
            if item.is_dir():
                shutil.copytree(item, target)
            else:
                shutil.copy2(item, target)
        if backup.exists():
            raise RuntimeError(f"Prior interrupted deployment needs recovery: {backup}")
        if dest.exists():
            os.rename(dest, backup)
        try:
            os.rename(temp, dest)
        except Exception:
            if backup.exists():
                os.rename(backup, dest)
            raise
        if backup.exists():
            shutil.rmtree(backup)
        return dest
    finally:
        if temp.exists():
            shutil.rmtree(temp)
