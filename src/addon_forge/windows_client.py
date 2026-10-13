"""Native Windows controller for an authorized WoW 3.3.5a test client.

Win32 input targets only a visible window owned by the configured Wow.exe.
The test protocol and SavedVariables parsing are shared with Linux/Wine.
This module imports on Linux, but WindowsAPI can only be instantiated on Windows.
"""
from __future__ import annotations

import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import subprocess
import sys
import time

from .config import Config

# Win32 SendInput keyboard structures: sizeof(INPUT) is pointer-size-sensitive.
ULONG_PTR = wintypes.WPARAM


class _MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR),
    ]


class _KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR),
    ]


class _HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]


class _INPUT_UNION(ctypes.Union):
    _fields_ = [("mi", _MOUSEINPUT), ("ki", _KEYBDINPUT), ("hi", _HARDWAREINPUT)]


class _INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUT_UNION)]


def _client_binary(wow_dir: Path) -> Path:
    for basename in ("Wow.exe", "WoW.exe"):
        path = wow_dir / basename
        if path.is_file():
            return path
    raise FileNotFoundError(f"WoW client executable absent from {wow_dir}")


def _same_executable(actual: str, expected: Path) -> bool:
    """Case-insensitive Windows filesystem path check; never title-match alone."""
    import ntpath
    return ntpath.normcase(ntpath.normpath(actual)) == ntpath.normcase(ntpath.normpath(str(expected)))


def validate_chat_command(command: str) -> None:
    if not isinstance(command, str) or not (command == "/reload" or command.startswith("/forge ")):
        raise ValueError("Automated controller permits only /reload and /forge commands")
    # Avoid keystrokes that could leave chat, trigger other actions or paste controls.
    if len(command) > 180 or any(ord(c) < 32 or ord(c) > 126 for c in command):
        raise ValueError("Only single-line printable ASCII commands up to 180 characters are permitted")


class WindowsAPI:
    """Minimal user32/kernel32 interface. No background/multi-window key injection."""

    def __init__(self):
        if sys.platform != "win32":
            raise RuntimeError("Native Windows controller requires Windows Python")
        self.user = ctypes.WinDLL("user32", use_last_error=True)
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        enum_callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        self.callback_type = enum_callback

        self.user.EnumWindows.argtypes = [enum_callback, wintypes.LPARAM]
        self.user.EnumWindows.restype = wintypes.BOOL
        for fn in ("IsWindowVisible", "IsIconic"):
            getattr(self.user, fn).argtypes = [wintypes.HWND]
            getattr(self.user, fn).restype = wintypes.BOOL
        self.user.GetWindowTextLengthW.argtypes = [wintypes.HWND]
        self.user.GetWindowTextLengthW.restype = ctypes.c_int
        self.user.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
        self.user.GetWindowTextW.restype = ctypes.c_int
        self.user.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        self.user.GetWindowThreadProcessId.restype = wintypes.DWORD
        self.user.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
        self.user.SetForegroundWindow.argtypes = [wintypes.HWND]
        self.user.SetForegroundWindow.restype = wintypes.BOOL
        self.user.GetForegroundWindow.restype = wintypes.HWND
        self.user.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
        self.user.GetWindowRect.restype = wintypes.BOOL
        self.user.VkKeyScanW.argtypes = [wintypes.WCHAR]
        self.user.VkKeyScanW.restype = ctypes.c_short
        self.user.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(_INPUT), ctypes.c_int]
        self.user.SendInput.restype = wintypes.UINT
        self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.QueryFullProcessImageNameW.argtypes = [
            wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)
        ]
        self.kernel.QueryFullProcessImageNameW.restype = wintypes.BOOL
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.CloseHandle.restype = wintypes.BOOL

    def _process_path(self, pid: int) -> str | None:
        handle = self.kernel.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return None  # E.g. elevated WoW; never inject into unverified process.
        try:
            size = wintypes.DWORD(32768)
            buffer = ctypes.create_unicode_buffer(size.value)
            if not self.kernel.QueryFullProcessImageNameW(handle, 0, buffer, ctypes.byref(size)):
                return None
            return buffer.value
        finally:
            self.kernel.CloseHandle(handle)

    def find_window(self, title: str, binary: Path) -> int:
        matches: list[int] = []

        @self.callback_type
        def visit(hwnd, _):
            if not self.user.IsWindowVisible(hwnd):
                return True
            size = self.user.GetWindowTextLengthW(hwnd)
            if size == 0:
                return True
            buf = ctypes.create_unicode_buffer(size + 1)
            self.user.GetWindowTextW(hwnd, buf, size + 1)
            if title.casefold() not in buf.value.casefold():
                return True
            pid = wintypes.DWORD()
            self.user.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            process_path = self._process_path(pid.value)
            if process_path and _same_executable(process_path, binary):
                matches.append(int(hwnd))
            return True

        if not self.user.EnumWindows(visit, 0):
            raise RuntimeError("Could not enumerate Windows desktop windows")
        if len(matches) != 1:
            raise RuntimeError(
                f"Expected exactly one visible {binary.name} window matching {title!r}; "
                f"found {len(matches)}. Run WoW in windowed mode and close other clients."
            )
        return matches[0]

    def focus(self, hwnd: int) -> None:
        if self.user.IsIconic(hwnd):
            self.user.ShowWindow(hwnd, 9)  # SW_RESTORE
        self.user.SetForegroundWindow(hwnd)
        time.sleep(0.15)
        if self.user.GetForegroundWindow() != hwnd:
            raise RuntimeError(
                "WoW is not the active window. Focus it manually before retrying; "
                "no keys were sent."
            )

    def _key(self, vk: int, up: bool = False):
        item = _INPUT(type=1, u=_INPUT_UNION(
            ki=_KEYBDINPUT(wVk=vk, wScan=0, dwFlags=0x0002 if up else 0, time=0, dwExtraInfo=0)
        ))
        if self.user.SendInput(1, ctypes.byref(item), ctypes.sizeof(_INPUT)) != 1:
            raise OSError("Windows SendInput failed; check WoW privileges and desktop session")

    def tap(self, vk: int):
        self._key(vk)
        self._key(vk, True)

    def type_text(self, text: str):
        for char in text:
            key = self.user.VkKeyScanW(char)
            if key == -1:
                raise RuntimeError(f"Current keyboard layout cannot type {char!r}")
            vk = key & 0xFF
            modifiers = (key >> 8) & 0xFF
            if modifiers & ~0x07:
                raise RuntimeError(f"Unsupported Windows keyboard modifier for {char!r}")
            held = [code for flag, code in ((1, 0x10), (2, 0x11), (4, 0x12))
                    if modifiers & flag]
            for code in held:
                self._key(code)
            try:
                self.tap(vk)
            finally:
                for code in reversed(held):
                    self._key(code, True)
            time.sleep(0.012)

    def rect(self, hwnd: int) -> tuple[int, int, int, int]:
        rect = wintypes.RECT()
        if not self.user.GetWindowRect(hwnd, ctypes.byref(rect)):
            raise OSError("Windows GetWindowRect failed")
        if rect.right <= rect.left or rect.bottom <= rect.top:
            raise RuntimeError("WoW window has invalid bounds")
        return rect.left, rect.top, rect.right, rect.bottom


class WindowsClientController:
    def __init__(self, cfg: Config, api: WindowsAPI | None = None):
        self.cfg = cfg
        self.api = api if api is not None else WindowsAPI()

    def start(self) -> int:
        binary = _client_binary(self.cfg.wow_dir)
        process = subprocess.Popen([str(binary)], cwd=str(self.cfg.wow_dir))
        return process.pid

    def window_id(self) -> str:
        binary = _client_binary(self.cfg.wow_dir)
        return str(self.api.find_window(self.cfg.window_name, binary))

    def command(self, command: str) -> None:
        validate_chat_command(command)
        hwnd = int(self.window_id())
        self.api.focus(hwnd)
        self.api.tap(0x0D)  # Enter opens in-game chat.
        self.api.type_text(command)
        self.api.tap(0x0D)  # Enter sends message to the ForgeTestBridge.
        # Native SendInput does not prove that the game received the command.
        # run_smoke verifies a correlated SavedVariables report after /reload.

    def screenshot(self, output: Path) -> Path:
        try:
            from PIL import ImageGrab
        except ImportError as exc:
            raise RuntimeError(
                "Windows screenshots need Pillow: python -m pip install 'addon-forge[windows]'"
            ) from exc
        hwnd = int(self.window_id())
        self.api.focus(hwnd)
        output = output.expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        ImageGrab.grab(bbox=self.api.rect(hwnd), all_screens=True).save(str(output))
        return output
