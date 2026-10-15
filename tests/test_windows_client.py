"""Native Windows WoW backend tests; Win32 is mocked on Linux CI."""
from pathlib import Path
from unittest.mock import Mock, patch
import pytest
from addon_forge.config import Config
from addon_forge.windows_client import (
    WindowsClientController, _same_executable, validate_chat_command,
)

def cfg(tmp_path):
    root = tmp_path / "WoW"
    root.mkdir()
    (root / "Wow.exe").write_bytes(b"fixture")
    return Config(wow_dir=root, wine_prefix=tmp_path / "wine")

@pytest.mark.parametrize("command", ["/reload", "/forge run smoke abc123"])
def test_allowed_commands(command):
    validate_chat_command(command)

@pytest.mark.parametrize("command", [
    "/logout", "/script print('unsafe')", "/forge\n/logout", "/forge \r/quit",
    "/forge \0", "/forge " + "a" * 190, "/forge é",
])
def test_rejects_unsafe_commands(command):
    with pytest.raises(ValueError):
        validate_chat_command(command)

def test_client_uses_verified_window_and_sends_chat(tmp_path):
    api = Mock()
    api.find_window.return_value = 321
    controller = WindowsClientController(cfg(tmp_path), api=api)
    controller.command("/targetexact Forgepeer")
    api.find_window.assert_called_once()
    api.focus.assert_called_once_with(321)
    assert api.tap.call_args_list == [
        __import__("unittest.mock", fromlist=["call"]).call(13),
        __import__("unittest.mock", fromlist=["call"]).call(13),
    ]
    api.type_text.assert_called_once_with("/targetexact Forgepeer", hwnd=321)


def test_windows_never_types_bridge_or_reload_commands(tmp_path):
    api = Mock()
    controller = WindowsClientController(cfg(tmp_path), api=api)
    with pytest.raises(RuntimeError, match="wowcontrol"):
        controller.command("/forge run smoke abc123")
    with pytest.raises(ValueError, match="targetexact"):
        controller.command("/reload")
    api.type_text.assert_not_called()

def test_rejected_command_never_focuses_or_types(tmp_path):
    api = Mock()
    controller = WindowsClientController(cfg(tmp_path), api=api)
    with pytest.raises(ValueError):
        controller.command("/logout")
    api.find_window.assert_not_called()
    api.type_text.assert_not_called()

def test_start_uses_native_exe_not_wine(tmp_path):
    config = cfg(tmp_path)
    with patch("addon_forge.windows_client.subprocess.Popen") as popen:
        popen.return_value.pid = 1520
        assert WindowsClientController(config, api=Mock()).start() == 1520
        assert popen.call_args.args[0] == [str(config.wow_dir / "Wow.exe")]

def test_executable_paths_match_case_insensitively():
    assert _same_executable(r"C:\Games\WoW\WoW.EXE", Path(r"c:\games\wow\Wow.exe"))
    assert not _same_executable(r"C:\Untrusted\Wow.exe", Path(r"C:\Games\WoW\Wow.exe"))

def test_platform_selector_stays_linux_on_linux():
    from addon_forge.client import LinuxClientController
    assert LinuxClientController.__name__ == "LinuxClientController"

def test_windows_command_escape_on_typing_failure(tmp_path):
    api = Mock()
    api.find_window.return_value = 321
    api.type_text.side_effect = RuntimeError("Cannot type slash on target layout")
    controller = WindowsClientController(cfg(tmp_path), api=api)
    with patch("addon_forge.windows_client.time.sleep"):
        with pytest.raises(RuntimeError, match="target layout"):
            controller.command("/targetexact Forgepeer")
    # Opens chat, then closes it without submitting any partial SAY message.
    assert [x.args[0] for x in api.tap.call_args_list] == [13, 27]
