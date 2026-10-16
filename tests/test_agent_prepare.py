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
    slots = []
    monkeypatch.setattr(win_login, "_credentials", lambda path, slot="main": slots.append(slot) or ("FORGETEST", "TOPSECRET"))
    monkeypatch.setattr(windows_client, "_client_binary", lambda path: wow / "Wow.exe")
    from addon_forge import clients
    clients.clear()
    api = Mock()
    api.find_windows.side_effect = [[], [], [(91, 1422)]]
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
            return {"screen": "login" if len([x for x in observed if x[0] == method]) <= 2 else
                    "charselect" if len([x for x in observed if x[0] == method]) <= 4 else "world",
                    "inWorld": len([x for x in observed if x[0] == method]) > 4}
        if method == "client.login":
            return {"ok": True}
        if method == "client.getCharacters":
            return {"characters": [{"name": "Test"}]}
        if method == "client.enterWorld":
            return {"ok": True}
        if method == "lua.evaluate":
            return {"ok": True, "result": "" if "GetBindingAction" in params["code"] else "dismissed"}
        if method == "unit.get":
            return {"exists": True, "name": "Test"}
        raise AssertionError("Unexpected method")
    pressed = []
    assert wowcontrol.launch_and_enter(cfg, "Test", rpc=rpc, press_idle=lambda: pressed.append(1)) == 1422
    assert pressed == [1]
    assert slots == ["main"] and clients.pid_of("main") == 1422
    clients.clear()
    assert all(pid == 1422 for _, _, pid in observed)
    assert len(launched) == 1
    assert "TOPSECRET" not in repr(launched)
    methods = [method for method, _, _ in observed]
    # Lua is sent only after unit.get identity checks, and only the constant idle-reset code.
    first_lua = methods.index("lua.evaluate")
    assert "unit.get" in methods[:first_lua]
    assert [params["code"] for method, params, _ in observed if method == "lua.evaluate"] == \
        [wowcontrol.IDLE_KEY_FREE_CODE, wowcontrol.IDLE_POPUP_CODE]


def test_idle_reset_presses_only_an_unbound_key_and_cancels_camp():
    from addon_forge import wowcontrol
    pressed = []
    def call(method, params=None):
        if "GetBindingAction" in params["code"]:
            return {"ok": True, "result": ""}
        return {"ok": True, "result": "dismissed"}
    result = wowcontrol.reset_idle_timer(call, lambda: pressed.append(1), sleep=lambda s: None)
    assert pressed == [1] and result == {"idle_key": "CTRL-SHIFT-F11", "camp_cancelled": True}
    assert "StaticPopup_Visible('CAMP')" in wowcontrol.IDLE_POPUP_CODE  # locale-independent


def test_idle_reset_refuses_a_bound_key():
    from addon_forge import wowcontrol
    pressed = []
    with pytest.raises(RuntimeError, match="No key was pressed"):
        wowcontrol.reset_idle_timer(lambda m, p=None: {"ok": True, "result": "TOGGLEAUTORUN"},
                                    lambda: pressed.append(1), sleep=lambda s: None)
    assert not pressed
    with pytest.raises(RuntimeError, match="idle-reset key binding"):
        wowcontrol.reset_idle_timer(lambda m, p=None: {"ok": False}, lambda: pressed.append(1))
    assert not pressed


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


def test_sdk_screen_wait_allows_initial_unknown_and_requires_stable_login():
    from addon_forge.wowcontrol import wait_for_screen
    observed = iter(["", "", "login", "", "login", "login"])
    calls = []
    now = [0.0]
    def call(method):
        calls.append(method)
        return {"screen": next(observed), "loginState": 0, "inWorld": False}
    def advance(seconds):
        now[0] += seconds
    assert wait_for_screen(call, "login", timeout=10, interval=0.5,
                           clock=lambda: now[0], sleep=advance)["screen"] == "login"
    assert calls == ["client.getScreen"] * 6


def test_sdk_screen_wait_timeout_reports_nonsecret_diagnostics():
    from addon_forge.wowcontrol import wait_for_screen
    now = [0.0]
    def call(method):
        return {"screen": "", "loginState": 2, "inWorld": False}
    def advance(seconds):
        now[0] += seconds
    with pytest.raises(RuntimeError, match="last screen='', loginState=2") as err:
        wait_for_screen(call, "login", timeout=1.0, interval=0.5,
                        clock=lambda: now[0], sleep=advance)
    assert "No credentials are sent" in str(err.value)


def test_sdk_screen_wait_refuses_unverified_charselect_without_waiting():
    from addon_forge.wowcontrol import wait_for_screen
    with pytest.raises(RuntimeError, match="unverified account"):
        wait_for_screen(lambda method: {"screen": "charselect"}, "login",
                        timeout=0.1, sleep=lambda _: None)


def test_sdk_screen_wait_rejects_already_in_world():
    from addon_forge.wowcontrol import wait_for_screen
    with pytest.raises(RuntimeError, match="already in-world"):
        wait_for_screen(lambda method: {"screen": "world", "inWorld": True},
                        "login", timeout=0.1, sleep=lambda _: None)


def test_sdk_screen_wait_never_logs_unexpected_payload():
    from addon_forge.wowcontrol import wait_for_screen
    now = [0.0]
    def advance(seconds):
        now[0] += seconds
    with pytest.raises(RuntimeError) as exc:
        wait_for_screen(lambda method: {"screen": "SECRET", "loginState": "SECRET"},
                        "login", timeout=0.1, interval=0.2,
                        clock=lambda: now[0], sleep=advance)
    assert "SECRET" not in str(exc.value)


def test_sdk_client_status_read_only_and_pid_bound(tmp_path, monkeypatch):
    from addon_forge import wowcontrol, win_login, windows_client
    cfg = Config(wow_dir=tmp_path / "wow", wine_prefix=tmp_path / "wine",
                 automation_backend="wowcontrol")
    monkeypatch.setattr(win_login, "_test_copy", lambda path: path)
    monkeypatch.setattr(windows_client, "_client_binary", lambda path: path / "Wow.exe")
    api = Mock()
    api.find_window.return_value = 12
    api.window_pid.return_value = 30272
    monkeypatch.setattr(windows_client, "WindowsAPI", lambda: api)
    observed = []
    def rpc(method, *, expected_pid):
        observed.append((method, expected_pid))
        return {"screen": "", "inWorld": False, "loginState": 7}
    status = wowcontrol.client_status(cfg, rpc=rpc)
    assert status["status"] == "observed"
    assert status["screen"] == ""
    assert status["pid"] == 30272
    assert status["login_state"] == 7
    assert observed == [("client.getScreen", 30272)]


def test_sdk_status_never_displays_unexpected_screen_string(tmp_path, monkeypatch):
    from addon_forge import wowcontrol, win_login, windows_client
    cfg = Config(wow_dir=tmp_path / "wow", wine_prefix=tmp_path / "wine")
    monkeypatch.setattr(win_login, "_test_copy", lambda path: path)
    monkeypatch.setattr(windows_client, "_client_binary", lambda path: path / "Wow.exe")
    api = Mock()
    api.find_window.return_value = 12
    api.window_pid.return_value = 1
    monkeypatch.setattr(windows_client, "WindowsAPI", lambda: api)
    out = wowcontrol.client_status(cfg, rpc=lambda *args, **kwargs:
                                   {"screen": "SENSITIVE STRING", "loginState": "SENSITIVE"})
    assert out["screen"] == "<unknown>"
    assert out["login_state"] is None


def test_world_identity_requires_two_unit_matches_without_lua():
    from addon_forge.wowcontrol import wait_for_player_identity
    calls = []
    states = iter([{"exists": False}, {"exists": True, "name": "Test"},
                   {"exists": True, "name": "Test"}])
    def rpc(method, params=None):
        calls.append(method)
        if method == "client.getScreen":
            return {"screen": "world", "inWorld": True}
        assert method == "unit.get"
        return next(states)
    now = [0.0]
    result = wait_for_player_identity(rpc, "Test", timeout=10, interval=0.5,
        clock=lambda: now[0], sleep=lambda delta: now.__setitem__(0, now[0] + delta))
    assert result == {"status": "sdk_unit_matched", "character": "Test"}
    assert calls.count("unit.get") == 3
    assert "lua.evaluate" not in calls


def test_world_identity_rejects_wrong_unit_player_immediately():
    from addon_forge.wowcontrol import wait_for_player_identity
    calls = []
    def rpc(method, params=None):
        calls.append(method)
        if method == "client.getScreen":
            return {"screen": "world"}
        assert method == "unit.get"
        return {"exists": True, "name": "Wrong"}
    now = [0.0]
    with pytest.raises(RuntimeError, match="different player"):
        wait_for_player_identity(
            rpc, "Test", mismatch_grace=1, interval=0.5, timeout=5,
            clock=lambda: now[0], sleep=lambda dt: now.__setitem__(0, now[0] + dt))
    assert calls.count("client.getScreen") == 3
    assert calls.count("unit.get") == 3


def test_world_identity_transient_mismatch_then_matching_player():
    from addon_forge.wowcontrol import wait_for_player_identity
    now = [0.0]
    names = iter(["Previous", "Test", "Test"])
    calls = []
    def rpc(method, params=None):
        calls.append(method)
        if method == "client.getScreen":
            return {"screen": "world", "inWorld": True}
        return {"exists": True, "name": next(names)}
    result = wait_for_player_identity(
        rpc, "Test", timeout=10, interval=0.5,
        clock=lambda: now[0], sleep=lambda dt: now.__setitem__(0, now[0] + dt))
    assert result["status"] == "sdk_unit_matched"
    assert calls.count("unit.get") == 3
    assert "lua.evaluate" not in calls


def test_world_identity_persistent_mismatch_fails_after_grace():
    from addon_forge.wowcontrol import wait_for_player_identity
    now = [0.0]
    def rpc(method, params=None):
        if method == "client.getScreen":
            return {"screen": "world", "inWorld": True}
        return {"exists": True, "name": "Wrong"}
    with pytest.raises(RuntimeError, match="persistently reports a different player"):
        wait_for_player_identity(
            rpc, "Test", timeout=20, interval=0.5, mismatch_grace=2,
            clock=lambda: now[0], sleep=lambda dt: now.__setitem__(0, now[0] + dt))
    assert 2 <= now[0] < 20


def test_world_identity_timeout_has_safe_diagnostics():
    from addon_forge.wowcontrol import wait_for_player_identity
    now = [0.0]
    def rpc(method, params=None):
        if method == "client.getScreen":
            return {"inWorld": True}
        assert method == "unit.get"
        return {"exists": False, "name": "SECRET"}
    with pytest.raises(RuntimeError, match="unit=not_ready") as exc:
        wait_for_player_identity(rpc, "Test", timeout=1, interval=0.5,
            clock=lambda: now[0], sleep=lambda delta: now.__setitem__(0, now[0] + delta))
    assert "SECRET" not in str(exc.value)


def test_world_identity_waits_until_actual_world_flag():
    from addon_forge.wowcontrol import wait_for_player_identity
    now = [0.0]
    states = iter([{"screen": "charselect", "inWorld": False},
                   {"screen": "world", "inWorld": True},
                   {"screen": "world", "inWorld": True}])
    def rpc(method, params=None):
        if method == "client.getScreen":
            return next(states)
        assert method == "unit.get"
        return {"exists": True, "name": "Test"}
    result = wait_for_player_identity(rpc, "Test", timeout=3, interval=0.5,
        clock=lambda: now[0], sleep=lambda delta: now.__setitem__(0, now[0] + delta))
    assert result["status"] == "sdk_unit_matched"


def test_sdk_player_status_avoids_crashing_lua_query(tmp_path, monkeypatch):
    from addon_forge import wowcontrol, win_login, windows_client
    cfg = Config(wow_dir=tmp_path / "wow", wine_prefix=tmp_path / "wine",
                 automation_backend="wowcontrol")
    monkeypatch.setattr(win_login, "_test_copy", lambda path: path)
    monkeypatch.setattr(windows_client, "_client_binary", lambda path: path / "Wow.exe")
    api = Mock()
    api.find_window.return_value = 12
    api.window_pid.return_value = 28732
    monkeypatch.setattr(windows_client, "WindowsAPI", lambda: api)
    observed = []
    def rpc(method, params=None, *, expected_pid):
        observed.append((method, params, expected_pid))
        if method == "client.getScreen":
            return {"screen": "world", "inWorld": True, "loginState": 8}
        assert method == "unit.get"
        return {"exists": True, "name": "Test"}
    out = wowcontrol.client_status(cfg, inspect_player=True, rpc=rpc)
    assert out["player"] == {
        "unit_exists": True, "unit_name": "Test",
        "verification": "sdk_only; fresh ForgeTestBridge v2 report required",
    }
    assert observed == [
        ("client.getScreen", None, 28732),
        ("unit.get", {"token": "player"}, 28732),
    ]



def test_sdk_player_status_disallows_displaying_unknown_names(tmp_path, monkeypatch):
    from addon_forge import wowcontrol, win_login, windows_client
    cfg = Config(wow_dir=tmp_path / "wow", wine_prefix=tmp_path / "wine")
    monkeypatch.setattr(win_login, "_test_copy", lambda path: path)
    monkeypatch.setattr(windows_client, "_client_binary", lambda path: path / "Wow.exe")
    api = Mock()
    api.find_window.return_value = 12
    api.window_pid.return_value = 28732
    monkeypatch.setattr(windows_client, "WindowsAPI", lambda: api)
    def rpc(method, params=None, *, expected_pid):
        if method == "client.getScreen":
            return {"screen": "world", "inWorld": True}
        assert method == "unit.get"
        return {"exists": True, "name": "SECRET\nAND MORE"}
    out = wowcontrol.client_status(cfg, inspect_player=True, rpc=rpc)
    assert out["player"] == {"unit_exists": True, "unit_name": None,
                              "verification": "sdk_only; fresh ForgeTestBridge v2 report required"}


def test_pipe_connection_prefers_the_per_process_pipe_and_falls_back_for_old_sdks():
    from addon_forge import wowcontrol_pipe
    from addon_forge.wowcontrol_pipe import open_verified_pipe, pipe_name
    wowcontrol_pipe._named.clear()
    closed = []
    class Transport:
        def CloseHandle(self, handle):
            closed.append(handle)
    def verify(handle, expected):
        if handle != expected:
            raise RuntimeError("SDK pipe owner does not match the marked WoW window PID")
    # Forge SDK build: the per-process pipe answers directly.
    names = []
    def per_process(transport, name=wowcontrol_pipe.PIPE, timeout=5.0):
        names.append(name)
        return 222
    assert open_verified_pipe(Transport(), 222, connect=per_process, verify=verify) == 222
    assert names == [pipe_name(222)] and pipe_name(222).endswith("WowGameCommand-222")
    # Old SDK build: no per-process pipe; the shared name is retried until the right owner answers.
    owners = iter([111, 333, 111, 333])
    def shared(transport, name=wowcontrol_pipe.PIPE, timeout=5.0):
        if name != wowcontrol_pipe.PIPE:
            raise RuntimeError("did not become available")
        return next(owners)
    assert open_verified_pipe(Transport(), 333, connect=shared, sleep=lambda s: None, verify=verify) == 333
    assert closed == [111] and wowcontrol_pipe._named[333] is False
    owners = iter([111] * 3)
    with pytest.raises(RuntimeError, match="does not match"):
        open_verified_pipe(Transport(), 333, attempts=3, connect=shared, sleep=lambda s: None, verify=verify)
    wowcontrol_pipe._named.clear()


def test_member_client_starts_next_to_main_with_member_credentials(tmp_path, monkeypatch):
    from addon_forge import wowcontrol, win_login, windows_client, clients
    monkeypatch.setattr(wowcontrol.sys, "platform", "win32")
    wow = tmp_path / "test-wow"
    wow.mkdir()
    injector, dll = tmp_path / "WowInjector.exe", tmp_path / "WoWControlSDK.dll"
    for file in (injector, dll):
        file.touch()
    cfg = Config(wow_dir=wow, wine_prefix=tmp_path / "wine", automation_backend="wowcontrol",
                 wowcontrol_injector=injector, wowcontrol_dll=dll, wowcontrol_realm="Local Realm")
    monkeypatch.setattr(win_login, "_test_copy", lambda path: wow)
    slots = []
    monkeypatch.setattr(win_login, "_credentials", lambda path, slot="main": slots.append(slot) or ("M", "P"))
    monkeypatch.setattr(windows_client, "_client_binary", lambda path: wow / "Wow.exe")
    monkeypatch.setattr(wowcontrol.subprocess, "run", lambda argv, **kw: None)
    api = Mock()
    monkeypatch.setattr(windows_client, "WindowsAPI", lambda: api)
    clients.clear()
    api.find_windows.return_value = [(91, 1422)]
    with pytest.raises(RuntimeError, match="Start the main test client"):
        wowcontrol.launch_and_enter(cfg, "Raidmember", rpc=None, role="member")
    clients.register("main", 1422)
    api.find_windows.side_effect = [[(91, 1422)], [(91, 1422)], [(91, 1422), (92, 2000)]]
    pings = []
    def rpc(method, params=None, *, expected_pid):
        assert expected_pid == 2000
        if method == "client.ping":
            pings.append(1)
            if len(pings) == 1:
                raise RuntimeError("SDK pipe owner does not match the marked WoW window PID")
            return {"status": "ok"}
        if method == "client.getScreen":
            return {"screen": "world", "inWorld": True}
        raise RuntimeError("stop after the ping")
    monkeypatch.setattr(wowcontrol.time, "sleep", lambda s: None)
    with pytest.raises(RuntimeError):
        wowcontrol.launch_and_enter(cfg, "Raidmember", rpc=rpc, role="member")
    assert clients.pid_of("member") == 2000 and slots == ["member"] and len(pings) == 2
    clients.clear()
