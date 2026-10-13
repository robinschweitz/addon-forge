"""Guarded AI code generation and repair using a configurable OpenAI-compatible endpoint.

The AI has no shell access and can only replace/add addon source files.
"""
from pathlib import Path, PurePosixPath
import json
import os
import shutil
import subprocess
import tempfile
import urllib.request

from .validate import check_addon, is_valid
from .config import Config
from .deploy import deploy
from .runner import run_smoke

ALLOWED_EXTENSIONS = {".lua", ".toc", ".xml"}
MAX_RESPONSE_BYTES = 500_000


def ask_model(system: str, prompt: str) -> dict:
    url = os.environ.get("FORGE_AI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
    model = os.environ.get("FORGE_AI_MODEL")
    api_key = os.environ.get("FORGE_AI_API_KEY")
    if not model or not api_key:
        raise RuntimeError("Set FORGE_AI_MODEL and FORGE_AI_API_KEY to use AI commands")
    payload = {
        "model": model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": prompt}],
        "temperature": 0.1,
        "response_format": {"type": "json_object"},
    }
    # Base URL is controlled by the user, not by model output.
    request = urllib.request.Request(url + "/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"},
        method="POST")
    with urllib.request.urlopen(request, timeout=90) as response:
        raw = response.read(MAX_RESPONSE_BYTES + 1)
    if len(raw) > MAX_RESPONSE_BYTES:
        raise ValueError("AI response exceeded maximum allowed size")
    message = json.loads(raw)["choices"][0]["message"]["content"]
    return json.loads(message)


def safe_changes(candidate: dict) -> list[tuple[PurePosixPath, str]]:
    changes = candidate.get("changes")
    if not isinstance(changes, list) or not changes or len(changes) > 15:
        raise ValueError("AI must return between 1 and 15 file changes")
    outputs = []
    seen = set()
    for item in changes:
        if not isinstance(item, dict) or not isinstance(item.get("path"), str) or not isinstance(item.get("content"), str):
            raise ValueError("Invalid change record")
        raw = item["path"].replace("\\", "/")
        path = PurePosixPath(raw)
        if path.is_absolute() or not path.parts or any(part in {"..", ".", "tests", ".git"} for part in path.parts):
            raise ValueError(f"Disallowed path: {raw}")
        if path.suffix.lower() not in ALLOWED_EXTENSIONS:
            raise ValueError(f"Disallowed extension: {raw}")
        if raw in seen or len(item["content"].encode("utf-8")) > 100_000:
            raise ValueError("Duplicate file or excessive content")
        seen.add(raw)
        outputs.append((path, item["content"]))
    return outputs


def apply_changes(directory: Path, changes: list[tuple[PurePosixPath, str]]) -> None:
    directory = directory.resolve()
    for rel, content in changes:
        dst = directory.joinpath(*rel.parts)
        if dst.exists() and dst.is_symlink():
            raise ValueError("Refusing to overwrite a symlink")
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not dst.resolve().is_relative_to(directory):
            raise ValueError("Path escaped addon directory")
        dst.write_text(content, encoding="utf-8")


def files_context(directory: Path) -> str:
    context = []
    for path in sorted(directory.rglob("*")):
        if path.is_file() and not path.is_symlink() and path.suffix.lower() in ALLOWED_EXTENSIONS:
            if len(context) >= 25:
                break
            src = path.read_text(encoding="utf-8", errors="replace")[:30_000]
            context.append(f"FILE {path.relative_to(directory)}\n{src}")
    return "\n\n".join(context)[:120_000]


SYSTEM = ("You write addons for original WoW WotLK 3.3.5a build 12340, Lua 5.1 and Interface 30300. "
          "No Retail/modern Classic APIs. Return ONLY a JSON object with a 'changes' array of "
          "{path, content} and a short 'reason'. Addon files only (.toc, .xml, .lua). "
          "Do not edit tests, remove checks, or include shell commands. Minimize changes when repairing.")


def create_addon(directory: Path, description: str) -> list[str]:
    if directory.exists():
        raise FileExistsError(f"Refusing to overwrite {directory}")
    name = directory.name
    if not name.isidentifier():
        raise ValueError("Addon directory name must be an identifier")
    candidate = ask_model(SYSTEM, f"Create a full addon named {name}. Description: {description}. "
                          f"Root .toc must be named {name}.toc and include ## Interface: 30300. "
                          "If ForgeTestBridge exists, register a smoke assertion named addon_smoke that tests actual addon state. ")
    changes = safe_changes(candidate)
    if not any(str(path) == f"{name}.toc" for path, _ in changes):
        raise ValueError("Generated addon is missing the expected TOC")
    directory.mkdir(parents=True)
    apply_changes(directory, changes)
    issues = check_addon(directory)
    if not is_valid(issues):
        shutil.rmtree(directory)
        raise RuntimeError("Generated addon failed static validation: " + "; ".join(d.message for d in issues))
    # Acceptance contract is not in the set of file types the AI may modify.
    (directory / "forge.spec.json").write_text(json.dumps({"required_tests": ["bridge_loaded", "addon_smoke"]}, indent=2) + "\n")
    return [str(path) for path, _ in changes]


def acceptance_contract(directory: Path) -> tuple[str, ...]:
    spec = directory / "forge.spec.json"
    if not spec.is_file():
        raise ValueError("In-client repair requires immutable forge.spec.json required_tests contract")
    obj = json.loads(spec.read_text(encoding="utf-8"))
    names = obj.get("required_tests")
    if not isinstance(names, list) or not names or any(not isinstance(n, str) or not n for n in names):
        raise ValueError("forge.spec.json must contain nonempty required_tests")
    return tuple(names)


def repair_addon(directory: Path, cfg: Config | None = None, in_client: bool = False,
                 max_attempts: int = 3) -> dict:
    if max_attempts < 1 or max_attempts > 5:
        raise ValueError("max_attempts must be between 1 and 5")
    if in_client and cfg is None:
        raise ValueError("Client tests require a forge.toml configuration")
    directory = directory.resolve()
    required = acceptance_contract(directory) if in_client else ()
    with tempfile.TemporaryDirectory(prefix="forge-repair-") as tmp:
        backup = Path(tmp) / "original"
        shutil.copytree(directory, backup)
        log = []
        success = False
        try:
            for attempt in range(max_attempts + 1):
                issues = check_addon(directory)
                static_ok = is_valid(issues)
                result = None
                if static_ok and in_client:
                    deploy(directory, cfg.wow_dir)
                    result = run_smoke(cfg, out_dir=directory.parent / ".forge-runs",
                                       required_tests=required)
                success = static_ok and (not in_client or result.status == "passed")
                log.append({"attempt": attempt, "static": [d.__dict__ for d in issues],
                            "client": result.__dict__ if result else None})
                if success:
                    return {"status": "passed", "attempts": attempt, "runs": log}
                if result and result.status == "infrastructure_error":
                    return {"status": "infrastructure_error", "attempts": attempt,
                            "runs": log, "note": "No source changes; fix client/test infrastructure"}
                if attempt == max_attempts:
                    break
                failure = json.dumps(log[-1], default=str)[:16_000]
                candidate = ask_model(SYSTEM, "Fix this addon without weakening tests.\n" +
                                      files_context(directory) + "\nFAILURE:\n" + failure)
                changes = safe_changes(candidate)
                if any(p.suffix == ".toc" and p.name != (directory.name + ".toc") for p, _ in changes):
                    raise ValueError("Unexpected TOC filename")
                apply_changes(directory, changes)
            return {"status": "failed", "attempts": max_attempts, "runs": log,
                    "note": "Original addon sources restored after failed repair"}
        finally:
            # Always revert unsuccessful runs, including malformed AI output and network exceptions.
            if not success:
                shutil.rmtree(directory)
                shutil.copytree(backup, directory)
