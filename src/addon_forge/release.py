"""forge release (FR-15): ship an addon only after every live plan passed.

The release runs each acceptance plan of the addon as a live session on the
files being released, then copies them into the owner's wow-addons checkout
and, when configured, syncs the raid-website's embedded addon bundle with the
website's own `cmd/sync-addons`. Each repository gets a new branch, made in a
temporary git worktree so the user's checkouts stay as they are. Nothing is
pushed (SECURITY.md SC-020): the human or agent pushes and opens the PRs.
Git runs only as fixed argument lists, never through a shell.
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

from .config import Config
from .validate import check_addon, is_valid, load_order, read_toc

PASSED = "passed"
WEBSITE_PAGES = "web/src"   # where the website names the addons in prose (pages, changelog)


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                          encoding="utf-8", check=check)


def _version(toc_text: str) -> str | None:
    match = re.search(r"(?im)^##\s*Version\s*:\s*(\S+)\s*$", toc_text)
    return match.group(1) if match else None


def addon_plans(addon: Path) -> list[Path]:
    """The plan files beside the addon's folder whose `addon` is this addon (FR-15.2)."""
    plans = []
    for path in sorted(addon.parent.glob("*.json")):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(data, dict) and data.get("version") == 1 and data.get("addon") == addon.name:
            plans.append(path)
    return plans


def release_files(addon: Path) -> list[str]:
    """The .toc, the files it loads (XML includes too) and README.md (FR-15.1, FR-15.3)."""
    addon = addon.resolve()
    toc = read_toc(addon)
    if toc is None:
        raise ValueError(f"{addon.name} has no single .toc")
    files = {toc.path, *toc.files, *load_order(addon)}
    readme = addon / "README.md"
    if readme.is_file():
        files.add(readme)
    names = sorted(p.resolve().relative_to(addon).as_posix() for p in files)
    for name in names:
        if name.split("/")[0] in ("tests", ".forge-runs") or "ForgeTestBridge" in name:
            raise ValueError(f"{name} must not be released")
    return names


def content_hash(addon: Path, files: list[str]) -> str:
    digest = hashlib.sha256()
    for name in files:
        digest.update(name.encode() + b"\0" + (addon / name).read_bytes() + b"\0")
    return digest.hexdigest()


def _released_version(repo: Path, name: str) -> str | None:
    shown = _git(repo, "show", f"origin/main:{name}/{name}.toc", check=False)
    return _version(shown.stdout) if shown.returncode == 0 else None


def _branch_exists(repo: Path, branch: str) -> bool:
    return _git(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{branch}", check=False).returncode == 0


def go_sync(website_tree: Path, addons_tree: Path) -> str:
    """The website's own bundle sync (raid-website ADR 085)."""
    done = subprocess.run(["go", "run", "./cmd/sync-addons", str(addons_tree)], cwd=website_tree,
                          capture_output=True, text=True, encoding="utf-8")
    if done.returncode != 0:
        raise RuntimeError(f"cmd/sync-addons failed: {done.stderr.strip() or done.stdout.strip()}")
    return done.stdout.strip()


class _Worktree:
    """A new branch from origin/main in a temporary worktree, removed again on exit."""

    def __init__(self, repo: Path, branch: str):
        self.repo, self.branch = repo, branch
        self.path = Path(tempfile.mkdtemp(prefix="forge-release-")) / repo.name

    def __enter__(self) -> Path:
        _git(self.repo, "worktree", "add", "-q", "-b", self.branch, str(self.path), "origin/main")
        return self.path

    def __exit__(self, *exc):
        _git(self.repo, "worktree", "remove", "--force", str(self.path), check=False)
        shutil.rmtree(self.path.parent, ignore_errors=True)


def _commit(tree: Path, paths: list[str], message: str) -> str:
    _git(tree, "add", "-A", "--", *paths)
    if _git(tree, "diff", "--cached", "--quiet", check=False).returncode == 0:
        raise RuntimeError(f"Nothing to commit in {tree.name}")
    _git(tree, "commit", "-q", "-m", message)
    return _git(tree, "rev-parse", "HEAD").stdout.strip()


def _summary(outcome: dict) -> dict:
    """Run ID and, for a failure, where and why: what to look at next."""
    result = outcome.get("plan_result") or {}
    test = result.get("test") or {}
    summary = {"run_id": test.get("run_id")}
    if test.get("member_run_id"):
        summary["member_run_id"] = test["member_run_id"]
    if outcome.get("status") != PASSED:
        for key in ("stage", "error"):
            value = result.get(key) or outcome.get(key)
            if value:
                summary[key] = value
        if outcome.get("preparation") and outcome.get("status") == "infrastructure_error" and not result:
            summary["preparation"] = outcome["preparation"].get("status")
        checks = (result.get("independent") or {}).get("checks") or []
        failing = [check for check in checks if not check.get("passed")]
        if failing:
            summary["failed_checks"] = failing
    return summary


def release(cfg: Config, addon: Path, *, approve: bool = False, session=None, sync=None) -> dict:
    """Preview (default) or run a release of `addon`; see the module docstring."""
    addon = addon.resolve()
    name = addon.name
    if cfg.release_addons_repo is None:
        raise ValueError("Set [release] addons_repo (your wow-addons checkout) in forge.local.toml")
    if not is_valid(check_addon(addon)):
        raise ValueError(f"{name} does not pass forge check")
    files = release_files(addon)
    version = _version((addon / f"{name}.toc").read_text(encoding="utf-8-sig"))
    if not version:
        raise ValueError(f"{name}.toc has no ## Version")
    plans = addon_plans(addon)
    if not plans:
        raise ValueError(f"{name} has no acceptance plans beside its folder")
    addons_repo, website_repo = cfg.release_addons_repo, cfg.release_website_repo
    branches = {"wow-addons": f"release/{name}-{version}"}
    if website_repo:
        branches["raid-website"] = f"addons/{name}-{version}"
    result = {"addon": name, "version": version, "plans": [p.name for p in plans], "files": files,
              "branches": branches}
    if not approve:
        return {"status": "plan_only", **result,
                "released_version": _released_version(addons_repo, name)}   # as of the last fetch

    # Refuse before spending live time (FR-15.4).
    repos = {"wow-addons": addons_repo, **({"raid-website": website_repo} if website_repo else {})}
    for label, repo in repos.items():
        _git(repo, "fetch", "-q", "origin", "main")
        if _branch_exists(repo, branches[label]):
            return {"status": "refused", **result, "error": f"Branch {branches[label]} already exists in {label}"}
    released = _released_version(addons_repo, name)
    if released == version:
        return {"status": "refused", **result,
                "error": f"{name} {version} is already on wow-addons main; raise the version in {name}.toc"}
    if website_repo and sync is None:
        if shutil.which("go") is None:
            raise RuntimeError("The website sync needs Go (go run ./cmd/sync-addons)")
        sync = go_sync
    if session is None:
        from .agent_session import run_session as session

    # Every plan, live, on these files (FR-15.2); old result files are never read.
    before = content_hash(addon, files)
    plan_results, failed = [], []
    for plan in plans:
        try:
            outcome = session(cfg, plan, approve=True)
        except Exception as exc:   # a session that cannot even start is not a pass
            outcome = {"status": "infrastructure_error", "error": str(exc)}
        plan_results.append({"plan": plan.name, "status": outcome.get("status"), **_summary(outcome)})
        if outcome.get("status") != PASSED:
            failed.append(plan.name)
    result["plan_results"] = plan_results
    if failed:
        return {"status": "failed", **result, "failed_plans": failed}
    if content_hash(addon, files) != before:
        return {"status": "refused", **result, "error": f"{name} changed during the live runs; release again"}

    runs = "\n".join(f"- {p['plan']}: {p['run_id']}" for p in plan_results)
    try:
        with _Worktree(addons_repo, branches["wow-addons"]) as tree:
            target = (tree / name).resolve()
            if not target.is_relative_to(tree.resolve()):
                raise ValueError("Addon target escapes the wow-addons worktree")
            shutil.rmtree(target, ignore_errors=True)   # files the new .toc no longer lists go
            for rel in files:
                (target / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(addon / rel, target / rel)
            result["commits"] = {"wow-addons": _commit(tree, [name], (
                f"{name} {version}\n\nReleased with forge release after every live plan passed on these files"
                f" ({released or 'new'} -> {version}):\n{runs}\n"))}
            if website_repo:
                with _Worktree(website_repo, branches["raid-website"]) as site:
                    synced = sync(site, tree)
                    result["website_sync"] = synced
                    # The website syncs every bundled addon; only this one may change, or
                    # an unmerged release of another addon would be undone.
                    _git(site, "add", "-A", "--", "internal/addons/bundle")
                    changed = _git(site, "diff", "--cached", "--name-only").stdout.split()
                    others = [path for path in changed if not path.startswith(f"internal/addons/bundle/{name}/")]
                    if others:
                        raise RuntimeError("The website sync would also change " + ", ".join(others)
                                           + ": merge the open release PRs of the other addon first")
                    result["commits"]["raid-website"] = _commit(site, ["internal/addons/bundle"], (
                        f"feat: ship {name} {version}\n\nSynced from wow-addons branch {branches['wow-addons']}"
                        f" with cmd/sync-addons (forge release).\n\n{synced}\n"))
                    listed = _git(site, "grep", "-l", "-F", name, "--", WEBSITE_PAGES, check=False).stdout
                    result["website_files_to_review"] = sorted(line for line in listed.splitlines() if line)
    except Exception:
        # No half release: drop the branches this run made, then report the error.
        for label, repo in repos.items():
            if _branch_exists(repo, branches[label]):
                _git(repo, "branch", "-D", branches[label], check=False)
        raise

    steps = [f"git -C {addons_repo} push -u origin {branches['wow-addons']}"]
    if website_repo:
        steps.append(f"git -C {website_repo} push -u origin {branches['raid-website']}")
        steps.append("Before the website PR: update the addon pages and the changelog (web/src/release.ts) "
                     "in the files listed under website_files_to_review")
    return {"status": "released", **result, "next_steps": steps}
