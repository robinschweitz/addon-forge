"""Embedded Lua 5.1 (via lupa) for syntax checks and global-access analysis.

WoW 3.3.5a runs Lua 5.1. Compiling with a real 5.1 parser rejects 5.2+ syntax
(goto, //, integer literals) exactly as the client would. Global reads and
writes are read from the compiled bytecode (GETGLOBAL/SETGLOBAL), which is
precise for every valid 5.1 source, unlike a regular-expression scan.
"""
from __future__ import annotations

from dataclasses import dataclass
import struct

GETGLOBAL, GETTABLE, SETGLOBAL, SELF = 5, 6, 7, 11


@dataclass(frozen=True)
class GlobalAccess:
    kind: str        # "get" | "set"
    name: str
    line: int
    field: str | None = None   # constant field read right after a global get (C_Timer.After)
    method: str | None = None  # constant method name used with ':' anywhere in the chunk


def runtime(*, encoding=None):
    try:
        import lupa.lua51 as lua51
    except ImportError as exc:  # pragma: no cover - dependency is declared
        raise RuntimeError("lupa is required: pip install -e .") from exc
    return lua51.LuaRuntime(encoding=encoding, unpack_returned_tuples=True)


def compile_chunk(source: bytes, chunkname: str, lua=None):
    """Return (function, None) or (None, error message) using Lua 5.1 loadstring."""
    lua = lua or runtime()
    result = lua.globals().loadstring(source, b"@" + chunkname.encode())
    if isinstance(result, tuple):
        fn, err = (result + (None,))[:2]
    else:
        fn, err = result, None
    if fn is None:
        msg = err.decode("utf-8", "replace") if isinstance(err, bytes) else str(err)
        return None, msg
    return fn, None


def syntax_error(source: bytes, chunkname: str) -> str | None:
    return compile_chunk(source, chunkname)[1]


class _Reader:
    def __init__(self, data: bytes):
        self.data, self.pos = data, 0
        if data[:4] != b"\x1bLua" or data[4] != 0x51:
            raise ValueError("Not Lua 5.1 bytecode")
        endian = "<" if data[6] == 1 else ">"
        self.int_fmt = endian + {4: "i", 8: "q"}[data[7]]
        self.size_fmt = endian + {4: "I", 8: "Q"}[data[8]]
        self.ins_fmt = endian + "I"
        self.num_fmt = endian + {8: "d", 4: "f"}[data[10]]
        self.pos = 12

    def take(self, fmt):
        value = struct.unpack_from(fmt, self.data, self.pos)[0]
        self.pos += struct.calcsize(fmt)
        return value

    def byte(self):
        self.pos += 1
        return self.data[self.pos - 1]

    def string(self):
        size = self.take(self.size_fmt)
        if size == 0:
            return None
        raw = self.data[self.pos:self.pos + size - 1]
        self.pos += size
        return raw.decode("utf-8", "replace")


def _walk(reader: _Reader, out: list[GlobalAccess]) -> None:
    reader.string()                       # source
    reader.take(reader.int_fmt)           # linedefined
    reader.take(reader.int_fmt)           # lastlinedefined
    for _ in range(4):                    # nups, numparams, is_vararg, maxstacksize
        reader.byte()
    code = [reader.take(reader.ins_fmt) for _ in range(reader.take(reader.int_fmt))]
    constants = []
    for _ in range(reader.take(reader.int_fmt)):
        kind = reader.byte()
        if kind == 0:
            constants.append(None)
        elif kind == 1:
            constants.append(bool(reader.byte()))
        elif kind == 3:
            constants.append(reader.take(reader.num_fmt))
        elif kind == 4:
            constants.append(reader.string())
        else:
            raise ValueError(f"Unknown constant type {kind}")
    protos = reader.take(reader.int_fmt)
    children: list[list[GlobalAccess]] = []
    for _ in range(protos):
        child: list[GlobalAccess] = []
        _walk(reader, child)
        children.append(child)
    lines = [reader.take(reader.int_fmt) for _ in range(reader.take(reader.int_fmt))]
    for _ in range(reader.take(reader.int_fmt)):   # locvars
        reader.string(); reader.take(reader.int_fmt); reader.take(reader.int_fmt)
    for _ in range(reader.take(reader.int_fmt)):   # upvalue names
        reader.string()

    def const(rk):
        return constants[rk - 256] if rk >= 256 and isinstance(constants[rk - 256], str) else None

    for pc, ins in enumerate(code):
        op, a = ins & 0x3F, (ins >> 6) & 0xFF
        c, b, bx = (ins >> 14) & 0x1FF, (ins >> 23) & 0x1FF, (ins >> 14) & 0x3FFFF
        line = lines[pc] if pc < len(lines) else 0
        if op in (GETGLOBAL, SETGLOBAL):
            name = constants[bx]
            field = None
            if op == GETGLOBAL and pc + 1 < len(code):
                nxt = code[pc + 1]
                if nxt & 0x3F in (GETTABLE, SELF) and (nxt >> 23) & 0x1FF == a:
                    field = const((nxt >> 14) & 0x1FF)
            out.append(GlobalAccess("get" if op == GETGLOBAL else "set", name, line, field))
        elif op == SELF and const(c):
            out.append(GlobalAccess("method", "", line, method=const(c)))
    for child in children:
        out.extend(child)


def global_accesses(source: bytes, chunkname: str) -> list[GlobalAccess]:
    """Every global get/set (and ':' method name) in a chunk, with line numbers."""
    lua = runtime()
    fn, err = compile_chunk(source, chunkname, lua)
    if fn is None:
        raise SyntaxError(err)
    dumped = lua.globals().string.dump(fn)
    out: list[GlobalAccess] = []
    _walk(_Reader(dumped), out)
    return sorted(out, key=lambda x: (x.line, x.kind, x.name))
