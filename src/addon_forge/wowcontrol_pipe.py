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
        raise RuntimeError(f"SDK pipe owner {actual.value} does not match the marked WoW window PID {expected_pid}")


ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY = 2, 231


def _connect(transport, *, timeout: float = 5.0, interval: float = 0.05,
             clock=None, sleep=None, name: str = PIPE):
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
            return transport.CreateFile(name, transport.GENERIC_READ | transport.GENERIC_WRITE,
                                        0, None, transport.OPEN_EXISTING, 0, None)
        except Exception as exc:
            code = getattr(exc, "winerror", None) or (exc.args[0] if exc.args else None)
            if code not in (ERROR_FILE_NOT_FOUND, ERROR_PIPE_BUSY):
                raise
            if clock() >= deadline:
                raise RuntimeError("WoWControlSDK pipe did not become available within "
                                   f"{timeout:.0f}s; is the injected test client still running?") from exc
            sleep(interval)


# Processes whose SDK serves a per-process pipe ("WowGameCommand-<pid>", the
# Forge build of the SDK) or only the shared name (older builds).
_named: dict[int, bool] = {}


def pipe_name(pid: int) -> str:
    return f"{PIPE}-{int(pid)}"


def open_verified_pipe(transport, expected_pid: int, *, attempts: int = 40, sleep=None, verify=None,
                       connect=None):
    """Open the SDK pipe of the WoW process `expected_pid`.

    The Forge build of the SDK serves one pipe per process, which reaches the
    right client directly. Older builds serve one shared name: with two test
    clients a connection may reach the other one; such a handle is closed
    unused (that SDK just answers a read error and serves its next instance)
    and the connection is retried until the right process answers. The owner
    is verified either way.
    """
    import time
    sleep = sleep or time.sleep
    verify = verify or verify_server_pid
    connect = connect or _connect
    if _named.get(expected_pid, True):
        try:
            handle = connect(transport, name=pipe_name(expected_pid), timeout=5.0 if expected_pid in _named else 1.5)
        except RuntimeError:
            if _named.get(expected_pid):
                raise   # this client did serve its own pipe before: it is gone or busy, not old
            _named[expected_pid] = False
        else:
            _named[expected_pid] = True
            try:
                verify(int(handle), expected_pid)
            except Exception:
                transport.CloseHandle(handle)
                raise
            return handle
    for attempt in range(attempts):
        handle = connect(transport)
        try:
            verify(int(handle), expected_pid)
            return handle
        except RuntimeError as exc:
            transport.CloseHandle(handle)
            if "does not match" not in str(exc) or attempt == attempts - 1:
                raise
            sleep(0.02)
        except Exception:
            transport.CloseHandle(handle)
            raise
