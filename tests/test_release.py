"""forge release (FR-15): live plans gate a copy into wow-addons and a website
bundle sync, each on its own branch; nothing is pushed."""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

from addon_forge.config import Config
from addon_forge import release

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="needs git")


def git(cwd, *args):
    return subprocess.run(["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True).stdout.strip()


def make_addon(root: Path, version="2.0.0"):
    addon = root / "Demo"
    (addon / "tests").mkdir(parents=True)
    (addon / "Demo.toc").write_text(f"## Interface: 30300\n## Title: Demo\n## Version: {version}\nCore.lua\n", encoding="utf-8")
    (addon / "Core.lua").write_text("DemoDB = DemoDB or {}\n", encoding="utf-8")
    (addon / "README.md").write_text("# Demo\n", encoding="utf-8")
    (addon / "tests" / "demo.spec.lua").write_text('test("x", function() end)\n', encoding="utf-8")
    (root / ".forge-runs").mkdir()
    (root / ".forge-runs" / "old.json").write_text('{"status": "passed"}', encoding="utf-8")
    for name, owner in (("Demo-acceptance.json", "Demo"), ("Demo-two-acceptance.json", "Demo"),
                        ("Other-acceptance.json", "Other")):
        (root / name).write_text(json.dumps({"version": 1, "addon": owner, "character": "Test", "peers": 0,
                                             "checks": [{"type": "no_lua_errors", "value": True}]}), encoding="utf-8")
    return addon


def make_repo(tmp: Path, name: str, files: dict[str, str]) -> Path:
    """A clone whose origin/main holds `files` (the GitHub repository)."""
    origin = tmp / f"{name}-origin.git"
    seed = tmp / f"{name}-seed"
    subprocess.run(["git", "init", "-q", "-b", "main", str(seed)], check=True)
    git(seed, "config", "core.autocrlf", "false")
    git(seed, "config", "user.email", "t@example.com")
    git(seed, "config", "user.name", "T")
    for path, text in files.items():
        (seed / path).parent.mkdir(parents=True, exist_ok=True)
        (seed / path).write_text(text, encoding="utf-8", newline="\n")   # stored with LF, as on GitHub
    git(seed, "add", "-A")
    git(seed, "commit", "-q", "-m", "seed")
    subprocess.run(["git", "clone", "-q", "--bare", str(seed), str(origin)], check=True)
    clone = tmp / name
    subprocess.run(["git", "clone", "-q", str(origin), str(clone)], check=True)
    git(clone, "config", "user.email", "t@example.com")
    git(clone, "config", "user.name", "T")
    return clone


OLD_ADDON = {"Demo/Demo.toc": "## Interface: 30300\n## Version: 1.0.0\nCore.lua\nOld.lua\n",
             "Demo/Core.lua": "-- old\n", "Demo/Old.lua": "-- removed in 2.0.0\n", "README.md": "# wow-addons\n"}


class Sessions:
    def __init__(self, statuses=None, change=None):
        self.statuses, self.change, self.ran = statuses or {}, change, []

    def __call__(self, cfg, plan, approve=False):
        assert approve is True
        self.ran.append(plan.name)
        if self.change:
            self.change(len(self.ran))
        status = self.statuses.get(plan.name, "passed")
        # The shape agent_session.run_session returns: run IDs live in the bridge test result.
        checks = [{"type": "chat_contains", "value": "x", "passed": status == "passed"}]
        return {"status": status, "plan_result": {"status": status, "test": {"run_id": f"run{len(self.ran)}"},
                                                  "independent": {"status": status, "checks": checks}}}


def website_sync(calls):
    def sync(website_tree: Path, addons_tree: Path):
        calls.append((website_tree, addons_tree))
        bundle = website_tree / "internal" / "addons" / "bundle" / "Demo"
        bundle.mkdir(parents=True, exist_ok=True)
        for name in ("Demo.toc", "Core.lua"):
            shutil.copy(addons_tree / "Demo" / name, bundle / name)
        return "Demo: 1.0.0 -> 2.0.0 (2 files)"
    return sync


def cfg(tmp, addons=None, website=None):
    return Config(wow_dir=tmp / "WoW", wine_prefix=tmp / "wine",
                  release_addons_repo=addons, release_website_repo=website)


def setup(tmp_path, with_website=True):
    addon = make_addon(tmp_path / "examples")
    addons = make_repo(tmp_path, "wow-addons", OLD_ADDON)
    website = make_repo(tmp_path, "raid-website", {
        "internal/addons/bundle/Demo/Demo.toc": "## Version: 1.0.0\n",
        "web/src/pages/Addons.tsx": "// Demo addon page\n", "web/src/release.ts": "// changelog: Demo 1.0.0\n",
        "README.md": "# site\n"}) if with_website else None
    return addon, addons, website


def test_plans_of_an_addon_are_the_plan_files_beside_it_that_name_it(tmp_path):
    addon = make_addon(tmp_path)
    assert [p.name for p in release.addon_plans(addon)] == ["Demo-acceptance.json", "Demo-two-acceptance.json"]


def test_released_files_are_the_toc_its_files_and_the_readme(tmp_path):
    addon = make_addon(tmp_path)
    assert release.release_files(addon) == ["Core.lua", "Demo.toc", "README.md"]


def test_a_license_file_is_released_with_the_addon(tmp_path):
    # FR-15.1: a GPL addon's license text travels with every released copy.
    addon = make_addon(tmp_path)
    (addon / "LICENSE").write_text("GPL-2.0-only", encoding="utf-8")
    assert release.release_files(addon) == ["Core.lua", "Demo.toc", "LICENSE", "README.md"]


def test_preview_changes_nothing_and_starts_no_client(tmp_path):
    addon, addons, website = setup(tmp_path)
    sessions = Sessions()
    before = git(addons, "branch", "-a"), git(website, "branch", "-a")
    result = release.release(cfg(tmp_path, addons, website), addon, session=sessions, sync=website_sync([]))
    assert result["status"] == "plan_only"
    assert result["version"] == "2.0.0"
    assert result["plans"] == ["Demo-acceptance.json", "Demo-two-acceptance.json"]
    assert result["files"] == ["Core.lua", "Demo.toc", "README.md"]
    assert result["branches"] == {"wow-addons": "release/Demo-2.0.0", "raid-website": "addons/Demo-2.0.0"}
    assert sessions.ran == []
    assert (git(addons, "branch", "-a"), git(website, "branch", "-a")) == before


def test_every_plan_passes_then_both_repositories_get_a_branch_and_a_commit(tmp_path):
    addon, addons, website = setup(tmp_path)
    sessions, calls = Sessions(), []
    result = release.release(cfg(tmp_path, addons, website), addon, approve=True, session=sessions,
                             sync=website_sync(calls))
    assert result["status"] == "released", result
    assert sessions.ran == ["Demo-acceptance.json", "Demo-two-acceptance.json"]
    assert [p["run_id"] for p in result["plan_results"]] == ["run1", "run2"]
    # wow-addons: the new version on its own branch, old files gone, no tests or runs.
    tree = git(addons, "ls-tree", "-r", "--name-only", "release/Demo-2.0.0").splitlines()
    assert sorted(t for t in tree if t.startswith("Demo/")) == ["Demo/Core.lua", "Demo/Demo.toc", "Demo/README.md"]
    assert "## Version: 2.0.0" in git(addons, "show", "release/Demo-2.0.0:Demo/Demo.toc")
    assert git(addons, "branch", "--show-current") == "main"            # the user's checkout is untouched
    assert git(addons, "worktree", "list").count("\n") == 0             # Forge's worktree is gone again
    assert "Demo 2.0.0" in git(addons, "log", "-1", "--format=%s", "release/Demo-2.0.0")
    assert "run1" in git(addons, "log", "-1", "--format=%b", "release/Demo-2.0.0")
    # raid-website: the website's own sync ran against the release tree, on its own branch.
    assert len(calls) == 1
    assert "Version: 2.0.0" in git(website, "show", "addons/Demo-2.0.0:internal/addons/bundle/Demo/Demo.toc")
    assert git(website, "branch", "--show-current") == "main"
    assert result["website_files_to_review"] == ["web/src/pages/Addons.tsx", "web/src/release.ts"]
    # Nothing was pushed.
    assert "release/Demo-2.0.0" not in git(addons, "ls-remote", "--heads", "origin")
    assert "addons/Demo-2.0.0" not in git(website, "ls-remote", "--heads", "origin")
    assert any("git -C" in step and "push" in step for step in result["next_steps"])


def test_a_failing_plan_stops_the_release_and_is_named(tmp_path):
    addon, addons, website = setup(tmp_path)
    sessions = Sessions({"Demo-two-acceptance.json": "failed"})
    result = release.release(cfg(tmp_path, addons, website), addon, approve=True, session=sessions,
                             sync=website_sync([]))
    assert result["status"] == "failed"
    assert result["failed_plans"] == ["Demo-two-acceptance.json"]
    failed = result["plan_results"][1]
    assert failed["run_id"] == "run2"
    assert failed["failed_checks"] == [{"type": "chat_contains", "value": "x", "passed": False}]
    assert "release/Demo-2.0.0" not in git(addons, "branch", "-a")
    assert "addons/Demo-2.0.0" not in git(website, "branch", "-a")


def test_an_infrastructure_error_counts_as_not_passed(tmp_path):
    addon, addons, _ = setup(tmp_path, with_website=False)
    result = release.release(cfg(tmp_path, addons), addon, approve=True,
                             session=Sessions({"Demo-acceptance.json": "infrastructure_error"}))
    assert result["status"] == "failed"
    assert result["failed_plans"] == ["Demo-acceptance.json"]


def test_a_file_changed_during_the_runs_stops_the_release(tmp_path):
    addon, addons, _ = setup(tmp_path, with_website=False)
    def edit(run):
        if run == 2:
            (addon / "Core.lua").write_text("-- changed after the first run\n", encoding="utf-8")
    result = release.release(cfg(tmp_path, addons), addon, approve=True, session=Sessions(change=edit))
    assert result["status"] == "refused"
    assert "changed" in result["error"]
    assert "release/Demo-2.0.0" not in git(addons, "branch", "-a")


def test_an_already_released_version_is_refused_before_any_run(tmp_path):
    addon, addons, _ = setup(tmp_path, with_website=False)
    (addon / "Demo.toc").write_text("## Interface: 30300\n## Version: 1.0.0\nCore.lua\n", encoding="utf-8")
    sessions = Sessions()
    result = release.release(cfg(tmp_path, addons), addon, approve=True, session=sessions)
    assert result["status"] == "refused"
    assert "1.0.0" in result["error"]
    assert sessions.ran == []


def test_old_result_files_are_never_a_pass(tmp_path):
    addon, addons, _ = setup(tmp_path, with_website=False)
    sessions = Sessions()
    release.release(cfg(tmp_path, addons), addon, approve=True, session=sessions)
    assert sessions.ran == ["Demo-acceptance.json", "Demo-two-acceptance.json"]   # .forge-runs/old.json ignored


def test_release_needs_the_addons_repository_and_a_valid_addon(tmp_path):
    addon, addons, _ = setup(tmp_path, with_website=False)
    with pytest.raises(ValueError, match="addons_repo"):
        release.release(cfg(tmp_path), addon, session=Sessions())
    (addon / "Core.lua").write_text("local x = = 1\n", encoding="utf-8")
    with pytest.raises(ValueError, match="forge check"):
        release.release(cfg(tmp_path, addons), addon, session=Sessions())


def test_an_existing_release_branch_is_refused(tmp_path):
    addon, addons, _ = setup(tmp_path, with_website=False)
    git(addons, "branch", "release/Demo-2.0.0")
    result = release.release(cfg(tmp_path, addons), addon, approve=True, session=Sessions())
    assert result["status"] == "refused"
    assert "release/Demo-2.0.0" in result["error"]


def test_config_reads_the_release_section(tmp_path):
    from addon_forge.config import load_config
    toml = tmp_path / "forge.local.toml"
    toml.write_text('[client]\nwow_dir = "W"\n[release]\naddons_repo = "A"\nwebsite_repo = "B"\n', encoding="utf-8")
    loaded = load_config(toml)
    assert loaded.release_addons_repo.name == "A"
    assert loaded.release_website_repo.name == "B"


def test_cli_previews_a_release(tmp_path, capsys):
    from addon_forge.cli import main
    addon, addons, _ = setup(tmp_path, with_website=False)
    toml = tmp_path / "forge.toml"
    toml.write_text(f'[client]\nwow_dir = "{(tmp_path / "WoW").as_posix()}"\n'
                    f'[release]\naddons_repo = "{addons.as_posix()}"\n', encoding="utf-8")
    assert main(["--config", str(toml), "release", str(addon)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["status"] == "plan_only"
    assert out["released_version"] == "1.0.0"


def test_the_website_sync_may_change_only_the_released_addon(tmp_path):
    addon, addons, website = setup(tmp_path)
    def sync(site, tree):
        other = site / "internal" / "addons" / "bundle" / "Other"
        other.mkdir(parents=True)
        (other / "Other.toc").write_text("## Version: 0.9.0\n", encoding="utf-8")   # an older copy
        return "synced"
    with pytest.raises(RuntimeError, match="Other"):
        release.release(cfg(tmp_path, addons, website), addon, approve=True, session=Sessions(), sync=sync)
    assert "release/Demo-2.0.0" not in git(addons, "branch", "-a")      # no half release
    assert "addons/Demo-2.0.0" not in git(website, "branch", "-a")


def stored(repo, rev_path):
    """The bytes Git stores for `rev:path`, without any line-ending conversion."""
    return subprocess.run(["git", "-C", str(repo), "cat-file", "-p", rev_path], check=True,
                          capture_output=True).stdout


def test_autocrlf_in_the_addons_checkout_does_not_change_another_bundle(tmp_path):
    # FR-15.1/FR-15.5: F:/wow-addons has core.autocrlf=true; the RaidWishlist 2.3.0 release
    # (2026-10-26) checked its worktree out with CRLF, and the sync made RaidLedger look changed.
    addon = make_addon(tmp_path / "examples")
    other = {"Other/Other.toc": "## Interface: 30300\n## Version: 1.4.0\nOther.lua\n", "Other/Other.lua": "-- other\n"}
    addons = make_repo(tmp_path, "wow-addons", {**OLD_ADDON, **other})
    website = make_repo(tmp_path, "raid-website", {
        "internal/addons/bundle/Demo/Demo.toc": "## Version: 1.0.0\n",
        **{f"internal/addons/bundle/{path}": text for path, text in other.items()}, "README.md": "# site\n"})
    git(addons, "config", "core.autocrlf", "true")
    git(website, "config", "core.autocrlf", "false")
    seen = {}
    def sync(site, tree):
        # Like cmd/sync-addons: every bundled addon is copied byte for byte from the release tree.
        for folder in ("Demo", "Other"):
            bundle = site / "internal" / "addons" / "bundle" / folder
            bundle.mkdir(parents=True, exist_ok=True)
            for source in (tree / folder).iterdir():
                seen[f"{folder}/{source.name}"] = source.read_bytes()
                if source.name != "README.md":
                    shutil.copy(source, bundle / source.name)
        return "synced"
    result = release.release(cfg(tmp_path, addons, website), addon, approve=True, session=Sessions(), sync=sync)
    assert result["status"] == "released", result
    assert [name for name, data in seen.items() if b"\r" in data] == []
    changed = git(website, "diff", "--name-only", "origin/main", "addons/Demo-2.0.0").split()
    assert changed == ["internal/addons/bundle/Demo/Core.lua", "internal/addons/bundle/Demo/Demo.toc"]


def test_released_files_carry_no_carriage_return(tmp_path):
    # FR-15.1: the addon's working copy may be CRLF (Windows checkout); the release stores LF.
    addon, addons, website = setup(tmp_path)
    git(addons, "config", "core.autocrlf", "false")
    for name in ("Demo.toc", "Core.lua", "README.md"):
        path = addon / name
        path.write_bytes(path.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
    seen = {}
    def sync(site, tree):
        seen.update({name: (tree / "Demo" / name).read_bytes() for name in ("Demo.toc", "Core.lua", "README.md")})
        return website_sync([])(site, tree)
    result = release.release(cfg(tmp_path, addons, website), addon, approve=True, session=Sessions(), sync=sync)
    assert result["status"] == "released", result
    for name in ("Demo.toc", "Core.lua", "README.md"):
        assert b"\r" not in stored(addons, f"release/Demo-2.0.0:Demo/{name}"), name
        assert b"\r" not in seen[name], name
    assert b"\r" not in stored(website, "addons/Demo-2.0.0:internal/addons/bundle/Demo/Core.lua")
