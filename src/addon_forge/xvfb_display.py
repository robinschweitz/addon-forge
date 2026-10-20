"""A private, invisible X display with OpenGL for the Linux test client.

Under a Wayland desktop, XWayland accepts synthetic key presses only for the
window the compositor focused, and xdotool cannot focus it; a rootful Xwayland
or a headless Weston aborts on XTEST input. A separate Xvfb display has no such
limits: xdotool types into the client, screenshots work, and the user's desktop
is never touched. WoW renders there through Mesa's software rasterizer.

Xvfb only offers GLX when its Mesa DRI drivers match the Mesa it was built
with. On NixOS the system drivers (/run/opengl-driver) may not; `xvfb = "nix"`
takes Xvfb and Mesa from the same nixpkgs (xorg.xorgserver, mesa) instead.
"""
from __future__ import annotations

from pathlib import Path
import os
import re
import shutil
import subprocess
import time

from .config import Config

SCREEN = "1280x800x24"
NIX_XVFB, NIX_MESA = "nixpkgs#xorg.xorgserver", "nixpkgs#mesa"


def _nix_path(installable: str, *, run=subprocess.run) -> Path:
    if not shutil.which("nix"):
        raise RuntimeError('xvfb = "nix" needs the nix command')
    result = run(["nix", "build", "--no-link", "--print-out-paths", installable],
                 capture_output=True, text=True, timeout=900)
    paths = result.stdout.split()
    if result.returncode or not paths:
        raise RuntimeError(f"nix build {installable} failed")
    return Path(paths[0])


def xvfb_command(cfg: Config, *, run=subprocess.run) -> tuple[list[str], dict]:
    """The Xvfb argv and environment for cfg.display (never a TCP listener)."""
    if not cfg.display or not re.fullmatch(r":[0-9]{1,3}", cfg.display):
        raise ValueError('Set [client] display, e.g. display = ":79", for the headless client')
    env = dict(os.environ)
    dri = cfg.dri_path
    if cfg.xvfb == "nix":
        binary = _nix_path(NIX_XVFB, run=run) / "bin" / "Xvfb"
        dri = dri or _nix_path(NIX_MESA, run=run) / "lib" / "dri"
    else:
        found = shutil.which(cfg.xvfb)
        if not found:
            raise RuntimeError(f"{cfg.xvfb} not found; install Xvfb or set xvfb = \"nix\"")
        binary = Path(found)
    if dri:
        env["LIBGL_DRIVERS_PATH"] = str(dri)
    return [str(binary), cfg.display, "-screen", "0", SCREEN, "-nolisten", "tcp", "+extension", "GLX"], env


def socket_path(display: str) -> Path:
    return Path("/tmp/.X11-unix") / f"X{display.lstrip(':')}"


def start_display(cfg: Config, *, run=subprocess.run, popen=subprocess.Popen, sleep=time.sleep,
                  timeout: float = 15) -> int | None:
    """Start the headless display; returns its PID, or None if it is already up."""
    sock = socket_path(cfg.display or "")
    if cfg.display and sock.exists():
        return None
    argv, env = xvfb_command(cfg, run=run)
    process = popen(argv, env=env, start_new_session=True,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if sock.exists():
            return process.pid
        if process.poll() is not None:
            raise RuntimeError(f"Xvfb on {cfg.display} exited during start")
        sleep(0.2)
    raise RuntimeError(f"Xvfb on {cfg.display} did not come up")
