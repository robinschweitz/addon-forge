from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

from addon_forge import agent_realm


def test_go_version_uses_module_and_auto_toolchain(tmp_path, monkeypatch):
    (tmp_path / "go.mod").write_text("module example\ngo 1.26.0\n")
    monkeypatch.setattr(agent_realm.shutil, "which", lambda command: "/go/bin/go")
    invoked = []
    def run(argv, **kwargs):
        invoked.append((argv, kwargs))
        return SimpleNamespace(returncode=0, stdout="go version go1.26.1 windows/amd64")
    monkeypatch.setattr(agent_realm.subprocess, "run", run)
    agent_realm._go_version(tmp_path)
    assert invoked[0][1]["cwd"] == tmp_path
    assert invoked[0][1]["env"]["GOTOOLCHAIN"] == "auto"
    assert invoked[0][1]["env"]["GOWORK"] == "off"


def test_go_environment_does_not_modify_parent_env(monkeypatch):
    monkeypatch.setenv("GOTOOLCHAIN", "local")
    result = agent_realm._go_environment()
    assert result["GOTOOLCHAIN"] == "auto"
    assert result["GOWORK"] == "off"
