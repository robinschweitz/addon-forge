"""Authenticate each SDK pipe handle to the verified WoW process ID."""
from __future__ import annotations
import ctypes
from ctypes import wintypes
import sys

PIPE = r"\\.\pipe\WowGameCommand"


def verify_server_pid(handle: int, expected_pid: int, *, kernel=None) -> None:
    if not isinstance(expected_pid, int) or expected_pid <= 0:
        raise RuntimeError("A verified WoW process ID is required")
    real_kernel = kernel is None
    if real_kernel:
        if sys.platform != "win32":
            raise RuntimeError("Windows named pipes only")
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    function = kernel.GetNamedPipeServerProcessId
    if real_kernel:
        function.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.ULONG)]
        function.restype = wintypes.BOOL
    actual = wintypes.ULONG()
    if not function(int(handle), ctypes.byref(actual)) or actual.value != expected_pid:
        raise RuntimeError("SDK pipe owner does not match the marked WoW window PID")


def open_verified_pipe(transport, expected_pid: int):
    handle = transport.CreateFile(PIPE, transport.GENERIC_READ | transport.GENERIC_WRITE,
                                  0, None, transport.OPEN_EXISTING, 0, None)
    try:
        verify_server_pid(int(handle), expected_pid)
    except Exception:
        transport.CloseHandle(handle)
        raise
    return handle
