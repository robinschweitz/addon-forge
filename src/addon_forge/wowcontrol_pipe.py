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


ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY = 2, 231


def _connect(transport, *, timeout: float = 5.0, interval: float = 0.05,
             clock=None, sleep=None):
    """Open the SDK pipe, retrying while the SDK is between pipe instances.

    The SDK serves requests on one thread: it creates a pipe instance, answers
    one request, closes it and only then creates the next. In that gap (or
    while another request is being answered) CreateFile fails with "file not
    found" or "pipe busy" even though the SDK is healthy.
    """
    import time
    clock = clock or time.monotonic
    sleep = sleep or time.sleep
    deadline = clock() + timeout
    while True:
        try:
            return transport.CreateFile(PIPE, transport.GENERIC_READ | transport.GENERIC_WRITE,
                                        0, None, transport.OPEN_EXISTING, 0, None)
        except Exception as exc:
            code = getattr(exc, "winerror", None) or (exc.args[0] if exc.args else None)
            if code not in (ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY):
                raise
            if clock() >= deadline:
                raise RuntimeError("WoWControlSDK pipe did not become available within "
                                   f"{timeout:.0f}s; is the injected test client still running?") from exc
            sleep(interval)


def open_verified_pipe(transport, expected_pid: int):
    handle = _connect(transport)
    try:
        verify_server_pid(int(handle), expected_pid)
    except Exception:
        transport.CloseHandle(handle)
        raise
    return handle
