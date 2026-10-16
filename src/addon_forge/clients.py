"""Which test-client process plays which role in a plan.

A plan normally drives one test client ("main"). A two-player plan adds a
second client ("member") logged in with another account. Sessions register
each client's process ID here; window lookups, key presses, screenshots and
SDK calls then reach the right one. With nothing registered, lookups fall
back to "the one visible test client", as before.
"""
from __future__ import annotations

ROLES = ("main", "member")
_pids: dict[str, int] = {}


def register(role: str, pid: int) -> None:
    if role not in ROLES:
        raise ValueError(f"Client role must be one of {ROLES}")
    if not isinstance(pid, int) or pid <= 0:
        raise ValueError("A client process ID is required")
    _pids[role] = pid


def pid_of(role: str = "main") -> int | None:
    if role not in ROLES:
        raise ValueError(f"Client role must be one of {ROLES}")
    return _pids.get(role)


def clear() -> None:
    _pids.clear()
