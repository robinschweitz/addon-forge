"""X11 input runner for an isolated, permissioned WoW test client."""
from pathlib import Path
import os
import shutil
import subprocess
import time

from .config import Config
import sys

# Typed chat lines: WoW's chat box takes at most 255 characters, and it opens a
# moment after Return, so typing right away loses the first characters (live
# run 2026-10-20: "/forge ..." arrived as "rge ..." and was said in /say).
CHAT_LIMIT = 255
CHAT_OPEN_DELAY = 0.7
# The window appears before the login screen takes input (software rendering on Xvfb).
LOGIN_SCREEN_DELAY = 8


class LinuxClientController:
    def __init__(self, cfg: Config, *, run=subprocess.run, sleep=time.sleep):
        self.cfg = cfg
        self._run = run
        self._sleep = sleep

    def _env(self) -> dict:
        env = dict(os.environ)
        if self.cfg.display:
            # The headless display: never type into a window on the user's desktop.
            env["DISPLAY"] = self.cfg.display
            env.pop("WAYLAND_DISPLAY", None)
        return env

    def start(self) -> int:
        wine = shutil.which("wine")
        if not wine:
            raise RuntimeError("Wine missing; enter 'nix develop' or install Wine")
        binary = self.cfg.wow_dir / "Wow.exe"
        if not binary.exists():
            binary = self.cfg.wow_dir / "WoW.exe"
        if not binary.is_file():
            raise FileNotFoundError(f"Client executable absent from {self.cfg.wow_dir}")
        env = dict(self._env(), WINEPREFIX=str(self.cfg.wine_prefix))
        # Skip Wine's Mono/Gecko install dialogs in a fresh prefix: nobody can click them headless.
        env.setdefault("WINEDLLOVERRIDES", "mscoree,mshtml=")
        self.cfg.wine_prefix.mkdir(parents=True, exist_ok=True)
        process = subprocess.Popen([wine, str(binary)], cwd=self.cfg.wow_dir, env=env, start_new_session=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return process.pid

    def _xdotool(self, *args, stdin: str | None = None) -> str:
        if not shutil.which("xdotool"):
            raise RuntimeError("xdotool not found")
        result = self._run(["xdotool", *args], input=stdin, capture_output=True, text=True, env=self._env())
        if result.returncode:
            raise RuntimeError(f"xdotool {args[0]} failed")
        return result.stdout

    def window_id(self) -> str:
        if not shutil.which("xdotool"):
            raise RuntimeError("xdotool not found")
        result = self._run(["xdotool", "search", "--onlyvisible", "--name", self.cfg.window_name],
                           capture_output=True, text=True, env=self._env())
        matches = result.stdout.splitlines()
        if result.returncode or not matches:
            raise RuntimeError(f"Visible WoW window not found: {self.cfg.window_name}")
        return matches[-1].strip()

    def _wait_for_window(self, timeout: float) -> str:
        until = time.monotonic() + timeout
        while True:
            try:
                return self.window_id()
            except RuntimeError:
                if time.monotonic() >= until:
                    raise
                self._sleep(1)

    def _focus(self) -> None:
        # windowactivate needs a window manager (_NET_ACTIVE_WINDOW); the headless
        # Xvfb display has none, but plain X input focus works everywhere. Keys
        # then go through XTEST: Wine ignores synthetic events sent to a window.
        self._xdotool("windowfocus", "--sync", self.window_id())

    def _type_chat(self, line: str) -> None:
        if len(line) > CHAT_LIMIT or any(c in line for c in "\n\r\0"):
            raise ValueError("A chat line is one line of at most 255 characters")
        self._focus()
        self._xdotool("key", "--clearmodifiers", "Return")
        self._sleep(CHAT_OPEN_DELAY)
        # Text goes through stdin, never through the process list.
        self._xdotool("type", "--clearmodifiers", "--delay", "15", "--file", "-", stdin=line)
        self._xdotool("key", "Return")

    def command(self, command: str) -> None:
        if not (command == "/reload" or command.startswith("/forge ")):
            raise ValueError("Automated controller permits only /reload and /forge commands")
        if any(c in command for c in "\n\r\0"):
            raise ValueError("Invalid multiline command")
        self._type_chat(command)

    def run_lua(self, line: str) -> None:
        """Type one '/run' line that plan_steps generated from a validated plan step.

        A typed line runs inside a real key press, so it may call functions the
        client allows only from hardware input (CalendarAddEvent and friends).
        """
        if not line.startswith("/run "):
            raise ValueError("Plan steps are sent as /run lines")
        self._type_chat(line)

    def login(self, slot: str = "main", *, enter_world: bool = True, wait: float = 20) -> None:
        """Log in from the login screen with the stored test account, then enter the world
        with the character selected on the character screen.

        The account name must already be in the client's WTF/Config.wtf (SET accountName);
        the password comes from the credential vault and is typed through stdin.
        """
        from .win_login import _credentials, _test_copy
        _test_copy(self.cfg.wow_dir)
        _, password = _credentials(self.cfg.wow_dir, slot)
        self._wait_for_window(timeout=90)
        self._sleep(LOGIN_SCREEN_DELAY)
        try:
            self._focus()
            # The password field has focus on the login screen.
            self._xdotool("type", "--delay", "50", "--file", "-", stdin=password)
        finally:
            password = ""
        self._xdotool("key", "Return")
        if enter_world:
            self._sleep(wait)
            self._focus()
            self._xdotool("key", "Return")

    def screenshot(self, output: Path) -> Path:
        if not shutil.which("import"):
            raise RuntimeError("ImageMagick 'import' tool missing")
        output = output.expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        self._run(["import", "-window", self.window_id(), str(output)], check=True, env=self._env())
        return output


# Preserve the existing Linux/Wine backend; select Win32 on native Windows.
if sys.platform == "win32":
    from .windows_client import WindowsClientController as ClientController
else:
    ClientController = LinuxClientController
