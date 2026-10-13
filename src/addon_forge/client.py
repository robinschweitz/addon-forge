"""X11 input runner for an isolated, permissioned WoW test client."""
from pathlib import Path
import os
import shutil
import subprocess

from .config import Config


class ClientController:
    def __init__(self, cfg: Config):
        self.cfg = cfg

    def start(self) -> int:
        wine = shutil.which("wine")
        if not wine:
            raise RuntimeError("Wine missing; enter 'nix develop' or install Wine")
        binary = self.cfg.wow_dir / "Wow.exe"
        if not binary.exists():
            binary = self.cfg.wow_dir / "WoW.exe"
        if not binary.is_file():
            raise FileNotFoundError(f"Client executable absent from {self.cfg.wow_dir}")
        env = dict(os.environ, WINEPREFIX=str(self.cfg.wine_prefix))
        self.cfg.wine_prefix.mkdir(parents=True, exist_ok=True)
        process = subprocess.Popen([wine, str(binary)], cwd=self.cfg.wow_dir, env=env, start_new_session=True)
        return process.pid

    def window_id(self) -> str:
        if not shutil.which("xdotool"):
            raise RuntimeError("xdotool not found")
        result = subprocess.run(["xdotool", "search", "--onlyvisible", "--name", self.cfg.window_name],
                                capture_output=True, text=True)
        matches = result.stdout.splitlines()
        if result.returncode or not matches:
            raise RuntimeError(f"Visible WoW window not found: {self.cfg.window_name}")
        return matches[-1].strip()

    def command(self, command: str) -> None:
        if not (command == "/reload" or command.startswith("/forge ")):
            raise ValueError("Automated controller permits only /reload and /forge commands")
        if any(c in command for c in "\n\r\0"):
            raise ValueError("Invalid multiline command")
        window = self.window_id()
        def run(*args):
            subprocess.run(["xdotool", *args], check=True, capture_output=True)
        run("windowactivate", "--sync", window)
        run("key", "--clearmodifiers", "Return")
        run("type", "--clearmodifiers", "--delay", "1", "--", command)
        run("key", "Return")

    def screenshot(self, output: Path) -> Path:
        if not shutil.which("import"):
            raise RuntimeError("ImageMagick 'import' tool missing")
        output = output.expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["import", "-window", self.window_id(), str(output)], check=True)
        return output
