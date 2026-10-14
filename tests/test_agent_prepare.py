"""Preparation never injects credentials or deploys over a live WoW session."""
from pathlib import Path
from unittest.mock import Mock
import pytest

from addon_forge.config import Config
from addon_forge import agent_prepare


def config(tmp_path):
    return Config(wow_dir=tmp_path / "WoW", wine_prefix=tmp_path / "wine")


def test_login_requires_explicit_client_start(tmp_path):
    with pytest.raises(ValueError, match="start-client"):
        agent_prepare.prepare_environment(config(tmp_path), login=True)


def test_prepare_refuses_unmarked_client_on_windows(tmp_path, monkeypatch):
    monkeypatch.setattr(agent_prepare.sys, "platform", "win32")
    with pytest.raises(RuntimeError, match="marked"):
        agent_prepare.prepare_environment(config(tmp_path))


def test_prepare_does_not_deploy_while_game_open(tmp_path, monkeypatch):
    from addon_forge import windows_client
    from addon_forge import win_login
    monkeypatch.setattr(agent_prepare.sys, "platform", "win32")
    monkeypatch.setattr(win_login, "_test_copy", lambda p: p)
    monkeypatch.setattr(windows_client, "_client_binary", lambda p: p / "Wow.exe")
    api = Mock()
    api.find_window.return_value = 42
    monkeypatch.setattr(windows_client, "WindowsAPI", lambda: api)
    def forbid(*args, **kwargs):
        pytest.fail("Live WoW must not be overwritten or restarted")
    monkeypatch.setattr(agent_prepare, "deploy", forbid)
    result = agent_prepare.prepare_environment(config(tmp_path), start_client=True)
    assert result["status"] == "client_running"
    assert result["bridge_deployed"] is False


def test_session_import_and_preview_callable():
    from addon_forge.agent_session import run_session
    assert callable(run_session)


def test_session_preview_no_client_or_credentials(tmp_path):
    import json
    from addon_forge.agent_session import run_session
    path = tmp_path / "scenario.json"
    addon = tmp_path / "Demo"
    addon.mkdir()
    path.write_text(json.dumps({"version": 1, "addon": "Demo", "character": "Test", "peers": 0, "checks": [{"type": "player_in_world", "value": True}]}))
    assert run_session(config(tmp_path), path)["status"] == "plan_only"

def test_sdk_backend_skips_pixel_calibration(tmp_path, monkeypatch):
    from addon_forge import agent_session
    cfg = Config(wow_dir=tmp_path / "WoW", wine_prefix=tmp_path / "wine",
                 automation_backend="wowcontrol")
    assert cfg.automation_backend == "wowcontrol"

def test_sdk_pipe_rejects_unknown_process():
    from addon_forge.wowcontrol_pipe import verify_server_pid
    with pytest.raises(RuntimeError, match="process ID"):
        verify_server_pid(0, 0)

def test_sdk_request_rejects_unlisted_methods():
    from addon_forge.wowcontrol import request
    with pytest.raises(ValueError, match="Unapproved"):
        request("client.quit", expected_pid=123)

def test_sdk_pid_binding_mismatch_fails():
    import ctypes
    from addon_forge.wowcontrol_pipe import verify_server_pid
    class Kernel:
        def __init__(self):
            self.GetNamedPipeServerProcessId = self.check
        def check(self, handle, output):
            ctypes.cast(output, ctypes.POINTER(ctypes.c_ulong))[0] = 999
            return True
    with pytest.raises(RuntimeError, match="does not match"):
        verify_server_pid(42, 123, kernel=Kernel())

def test_sdk_bridge_never_accepts_non_forge_code():
    from addon_forge.windows_client import validate_chat_command
    for bad in ("/run print('oops')", "/script ReloadUI()", "/logout"):
        with pytest.raises(ValueError):
            validate_chat_command(bad)

def test_sdk_unknown_backend_configuration(tmp_path):
    from addon_forge.config import load_config
    cfg = tmp_path / "forge.toml"
    cfg.write_text("[client]\nwow_dir = 'C:/test'\nautomation_backend = 'anything'\n")
    with pytest.raises(ValueError, match="backend"):
        load_config(cfg)

def test_sdk_login_pins_rpc_to_test_pid_and_never_uses_secret_in_argv(tmp_path, monkeypatch):
    from addon_forge import wowcontrol, win_login, windows_client
    from pathlib import Path
    monkeypatch.setattr(wowcontrol.sys, "platform", "win32")
    wow = tmp_path / "test-wow"
    wow.mkdir()
    injector = tmp_path / "WowInjector.exe"
    dll = tmp_path / "WoWControlSDK.dll"
    for file in (injector, dll):
        file.touch()
    cfg = Config(wow_dir=wow, wine_prefix=tmp_path / "wine",
                 automation_backend="wowcontrol", wowcontrol_injector=injector,
                 wowcontrol_dll=dll, wowcontrol_realm="Local Realm")
    monkeypatch.setattr(win_login, "_test_copy", lambda path: wow)
    monkeypatch.setattr(win_login, "_credentials", lambda path: ("FORGETEST", "TOPSECRET"))
    monkeypatch.setattr(windows_client, "_client_binary", lambda path: wow / "Wow.exe")
    api = Mock()
    api.find_window.side_effect = [RuntimeError("found 0."), 91]
    api.window_pid.return_value = 1422
    monkeypatch.setattr(windows_client, "WindowsAPI", lambda: api)
    launched = []
    monkeypatch.setattr(wowcontrol.subprocess, "run",
                        lambda argv, **kw: launched.append(argv))
    observed = []
    def rpc(method, params=None, *, expected_pid):
        observed.append((method, params, expected_pid))
        if method == "client.ping":
            return {"status": "ok"}
        if method == "client.getScreen":
            return {"screen": "login" if len([x for x in observed if x[0] == method]) == 1 else "charselect"}
        if method == "client.login":
            return {"ok": True}
        if method == "client.getCharacters":
            return {"characters": [{"name": "Test"}]}
        if method == "client.enterWorld":
            return {"ok": True}
        if method == "lua.evaluate":
            return {"ok": True, "result": "Test"}
        raise AssertionError("Unexpected method")
    assert wowcontrol.launch_and_enter(cfg, "Test", rpc=rpc) == 1422
    assert all(pid == 1422 for _, _, pid in observed)
    assert len(launched) == 1
    assert "TOPSECRET" not in repr(launched)
    assert observed[-1][0] == "lua.evaluate"

def test_missing_pywin32_is_a_friendly_preflight_error(monkeypatch):
    import builtins
    from addon_forge import wowcontrol
    monkeypatch.setattr(wowcontrol.sys, "platform", "win32")
    original_import = builtins.__import__

    def no_win32file(name, *args, **kwargs):
        if name == "win32file":
            raise ModuleNotFoundError("No module named win32file")
        return original_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", no_win32file)
    with pytest.raises(RuntimeError, match="pip install -e"):
        wowcontrol.require_windows_transport()


def test_injector_does_not_launch_without_pywin32(tmp_path, monkeypatch):
    from addon_forge import wowcontrol, win_login
    cfg = Config(wow_dir=tmp_path / "wow", wine_prefix=tmp_path / "wine",
                 automation_backend="wowcontrol")
    monkeypatch.setattr(wowcontrol.sys, "platform", "win32")
    monkeypatch.setattr(win_login, "_test_copy",
                        lambda *_: pytest.fail("preflight happened too late"))
    monkeypatch.setattr(wowcontrol, "require_windows_transport",
                        lambda: (_ for _ in ()).throw(RuntimeError("pywin32 missing")))
    monkeypatch.setattr(wowcontrol.subprocess, "run",
                        lambda *args, **kwargs: pytest.fail("Injector launched"))
    with pytest.raises(RuntimeError, match="pywin32"):
        wowcontrol.launch_and_enter(cfg, "Test")
