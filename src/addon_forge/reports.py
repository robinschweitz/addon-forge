"""Strict Lua SavedVariables subset parser. Never execute SavedVariables as code."""
from pathlib import Path
import re

TOKEN = re.compile(r'''\s+|--[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|-?\d+(?:\.\d+)?|[A-Za-z_][A-Za-z_0-9]*|[{}\[\]=,;]''')


class ReportParseError(ValueError):
    pass


def tokenize(source: str) -> list[str]:
    matches = []
    pos = 0
    while pos < len(source):
        m = TOKEN.match(source, pos)
        if not m:
            raise ReportParseError(f"Unexpected input at position {pos}")
        token = m.group()
        if not token.isspace() and not token.startswith("--"):
            matches.append(token)
        pos = m.end()
    return matches


class Parser:
    def __init__(self, source: str):
        self.tokens = tokenize(source)
        self.pos = 0

    def peek(self) -> str | None:
        return self.tokens[self.pos] if self.pos < len(self.tokens) else None

    def pop(self, expected: str | None = None) -> str:
        value = self.peek()
        if value is None or (expected is not None and value != expected):
            raise ReportParseError(f"Expected {expected or 'token'}, got {value}")
        self.pos += 1
        return value

    def value(self, depth: int = 0):
        if depth > 40:
            raise ReportParseError("Table nesting too deep")
        tok = self.peek()
        if tok == "{":
            return self.table(depth + 1)
        tok = self.pop()
        if tok.startswith(('"', "'")):
            def unescape(m):
                ch = m.group(1)
                if ch.isdigit():
                    return chr(int(ch))
                return {"n":"\n", "r":"\r", "t":"\t", "\\":"\\", '"':'"', "'":"'"}.get(ch, ch)
            return re.sub(r"\\(\d{1,3}|.)", unescape, tok[1:-1])
        if tok in {"true", "false", "nil"}:
            return {"true": True, "false": False, "nil": None}[tok]
        if re.fullmatch(r"-?\d+(?:\.\d+)?", tok):
            return float(tok) if "." in tok else int(tok)
        raise ReportParseError(f"Unsupported bare value: {tok}")

    def table(self, depth: int):
        self.pop("{")
        values = {}
        index = 1
        while self.peek() != "}":
            if self.peek() is None:
                raise ReportParseError("Unterminated Lua table")
            if self.peek() == "[":
                self.pop("[")
                key = self.value(depth)
                self.pop("]")
                self.pop("=")
                value = self.value(depth)
            elif self.pos + 1 < len(self.tokens) and self.tokens[self.pos + 1] == "=":
                key = self.pop()
                self.pop("=")
                value = self.value(depth)
            else:
                while index in values:
                    index += 1
                key = index
                value = self.value(depth)
                index += 1
            if len(values) > 10000:
                raise ReportParseError("Table too large")
            values[key] = value
            if self.peek() in {",", ";"}:
                self.pop()
            elif self.peek() != "}":
                raise ReportParseError("Expected table separator")
        self.pop("}")
        if values and all(isinstance(k, int) and k >= 1 for k in values):
            max_idx = max(values)
            if set(values) == set(range(1, max_idx + 1)):
                return [values[i] for i in range(1, max_idx + 1)]
        return values


def parse_report(source: str) -> dict:
    parser = Parser(source)
    parser.pop("ForgeTestReport")
    parser.pop("=")
    result = parser.value()
    if parser.peek() is not None:
        raise ReportParseError("Trailing statements are disallowed")
    if not isinstance(result, dict):
        raise ReportParseError("Expected report table")
    return result


def latest_report(wow_dir: Path) -> tuple[Path, dict] | None:
    root = wow_dir / "WTF" / "Account"
    matches = root.glob("*/SavedVariables/ForgeTestBridge.lua")
    paths = sorted((p for p in matches if p.is_file()), key=lambda p: p.stat().st_mtime_ns, reverse=True)
    for path in paths:
        try:
            return path, parse_report(path.read_text(encoding="utf-8-sig"))
        except (OSError, ReportParseError, UnicodeDecodeError):
            continue
    return None
