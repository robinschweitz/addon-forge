"""Linux/Wine typed transport: plan steps as /run chat lines (no SDK)."""
from pathlib import Path
from types import SimpleNamespace

import pytest

from addon_forge.client import LinuxClientController, CHAT_LIMIT
from addon_forge.config import Config
from addon_forge.plan_steps import (_code, lua_literal, run_steps, typed_lines, typed_lua,
                                    typed_step_checks)


def test_lua_literal_escapes_for_lua_51():
    assert lua_literal('a"b\\c\nd\te') == '"a\\"b\\\\c\\nd\\009e"'
    assert lua_literal("Jäger") == '"Jäger"'


def test_short_step_is_one_line_and_long_step_is_chunked_within_the_chat_limit():
    short = typed_lines(1, "return 'ok'")
    assert short == ["/run ForgeStepResults=ForgeStepResults or {} ForgeStepResults[1]=(function() return 'ok' end)()"]
    code = _code({"type": "paste", "value": ["RaidLedgerInviteText", "RS2;INV;43;Live\n" + "x" * 300]})
    lines = typed_lines(2, code)
    assert len(lines) > 3 and all(len(line) <= CHAT_LIMIT and "\n" not in line for line in lines)
    assert lines[0] == "/run ForgeStepBuffer=nil" and "loadstring" in lines[-1]
    # Reassembling the literal pieces gives back the exact statement.
    import ast
    pieces = [line.split("..", 1)[1] for line in lines[1:-1]]
    joined = "".join(ast.literal_eval(p.replace("\\009", "\\t")) for p in pieces)
    assert joined.endswith("end)()") and "ForgeStepResults[2]" in joined and "x" * 300 in joined


def test_typed_run_steps_numbers_steps_and_turns_hardware_click_into_a_click():
    sent = []
    steps = [{"type": "slash", "value": "/ledger setup"}, {"type": "wait", "value": 0},
             {"type": "hardware_click", "value": "RaidLedgerCalendar"}]
    log = run_steps(steps, 0, typed=typed_lua(sent.append), sleep=lambda s: None)
    assert [entry["result"] for entry in log] == ["ok", "ok", "ok"]
    assert any("ForgeStepResults[1]" in line for line in sent)
    assert any("ForgeStepResults[2]" in line for line in sent)
    joined = "".join(sent)
    assert "RaidLedgerCalendar" in joined and "SetBindingClick" not in joined
    assert typed_step_checks(steps) == [
        {"type": "global_equals", "path": "ForgeStepResults.1", "value": "ok"},
        {"type": "global_equals", "path": "ForgeStepResults.2", "value": "ok"}]


def _controller(tmp_path, calls):
    cfg = Config(wow_dir=tmp_path, wine_prefix=tmp_path / "prefix", display=":79")
    def run(argv, **kwargs):
        calls.append((argv, kwargs.get("input"), kwargs.get("env", {}).get("DISPLAY")))
        return SimpleNamespace(returncode=0, stdout="4242\n")
    return LinuxClientController(cfg, run=run, sleep=lambda s: calls.append(("sleep", s, None)))


def test_chat_lines_go_to_the_headless_display_through_stdin(tmp_path, monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: "/bin/" + name)
    calls = []
    client = _controller(tmp_path, calls)
    client.run_lua("/run print(1)")
    typed = [c for c in calls if c[0] != "sleep" and c[0][1] == "type"]
    assert typed[0][1] == "/run print(1)" and "/run print(1)" not in typed[0][0]
    assert all(c[2] == ":79" for c in calls if c[0] != "sleep")
    assert ("sleep", 0.7, None) in calls  # the chat box opens a moment after Return
    with pytest.raises(ValueError):
        client.run_lua("/say hi")
    with pytest.raises(ValueError):
        client.command("/run print(1)")
    with pytest.raises(ValueError):
        client.run_lua("/run " + "x" * 300)


def test_login_types_the_vault_password_through_stdin_only(tmp_path, monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: "/bin/" + name)
    import addon_forge.win_login as win_login
    monkeypatch.setattr(win_login, "_test_copy", lambda wow: wow)
    monkeypatch.setattr(win_login, "_credentials", lambda wow, slot: ("FORGETEST", "s3cretPw"))
    calls = []
    _controller(tmp_path, calls).login("main", wait=0)
    assert any(c[1] == "s3cretPw" for c in calls)
    assert not any("s3cretPw" in " ".join(map(str, c[0])) for c in calls if c[0] != "sleep")
