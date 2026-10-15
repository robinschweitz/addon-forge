"""Loot fixture handshakes fail closed and never claim an unverified capture."""
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from addon_forge import loot_scenario


class Proc:
    def __init__(self, exited=None, hang=False):
        self.exited, self.hang, self.killed = exited, hang, False

    def poll(self):
        return self.exited

    def wait(self, timeout=None):
        if self.hang and not self.killed:
            raise subprocess.TimeoutExpired("go", timeout)
        return 0

    def kill(self):
        self.killed = True


def fake_clock():
    now = [0.0]
    return (lambda: now[0]), (lambda s: now.__setitem__(0, now[0] + s))


def test_invalid_character_is_rejected_before_any_client_access(tmp_path):
    with pytest.raises(ValueError):
        with loot_scenario.master_loot_fixture(SimpleNamespace(), character="Bad Name", output=tmp_path):
            pytest.fail("fixture must not start")
    assert not any(tmp_path.iterdir())


def test_missing_realm_fails_before_client_access(tmp_path):
    with pytest.raises(RuntimeError, match="realm"):
        with loot_scenario.master_loot_fixture(SimpleNamespace(realm_dir=None), character="Test", output=tmp_path):
            pytest.fail("fixture must not start")


def test_partial_or_missing_state_reads_as_not_ready(tmp_path):
    path = tmp_path / "ready.json"
    assert loot_scenario._read_state(path) is None
    path.write_text('{"status": "inv', encoding="utf-8")
    assert loot_scenario._read_state(path) is None
    path.write_text('{"status": "invite_sent"}', encoding="utf-8")
    assert loot_scenario._read_state(path) == {"status": "invite_sent"}


def test_wait_reports_timeout_with_last_status(tmp_path):
    path = tmp_path / "ready.json"
    path.write_text('{"status": "invite_sent"}', encoding="utf-8")
    clock, sleep = fake_clock()
    with pytest.raises(RuntimeError, match="master_loot_ready.*last status='invite_sent'"):
        loot_scenario._wait_for_status(path, "master_loot_ready", Proc(), timeout=1,
                                       clock=clock, sleep=sleep)


def test_wait_fails_fast_when_fixture_exits(tmp_path):
    clock, sleep = fake_clock()
    with pytest.raises(RuntimeError, match="exited"):
        loot_scenario._wait_for_status(tmp_path / "ready.json", "invite_sent", Proc(exited=1),
                                       timeout=60, clock=clock, sleep=sleep)


def test_stop_kills_a_hung_fixture(tmp_path):
    proc = Proc(hang=True)
    loot_scenario._stop(proc, tmp_path / "release")
    assert proc.killed
    assert (tmp_path / "release").exists()


def test_corpse_names_are_validated_and_localized_first():
    assert loot_scenario._corpse_names({"names": ["Purpurroter Templer", "Crimson Templar"]}) == \
        ["Purpurroter Templer", "Crimson Templar"]
    assert loot_scenario._corpse_names({"names": ['x") os.exit() --', "a\\b", 3]}) == ["Crimson Templar"]
    assert loot_scenario._corpse_names({}) == ["Crimson Templar"]
    assert 'TargetUnit("Purpurroter Templer")' in loot_scenario._target_code("Purpurroter Templer")
    code = loot_scenario._target_code("Kriegshymnenschläger")
    assert 'TargetUnit("Kriegshymnenschläger")' in code  # raw UTF-8: Lua 5.1 has no escapes for it


def fake_rpc(target_ok_for=None, loot_items=0):
    calls = []
    def rpc(method, params=None, *, expected_pid):
        code = params["code"]
        calls.append(code)
        if code.startswith("TargetUnit("):
            return {"ok": True, "result": 1 if target_ok_for and target_ok_for in code else 0}
        if code.startswith("InteractUnit"):
            return {"ok": True, "result": True}
        return {"ok": True, "result": loot_items}
    return rpc, calls


def test_open_corpse_reports_which_step_failed(monkeypatch):
    monkeypatch.setattr(loot_scenario.time, "sleep", lambda s: None)
    rpc, calls = fake_rpc()
    with pytest.raises(RuntimeError, match="Could not target"):
        loot_scenario._open_corpse(["Purpurroter Templer", "Crimson Templar"], 7, rpc=rpc, loot_timeout=0)
    assert not any(c.startswith("InteractUnit") for c in calls)
    rpc, _ = fake_rpc(target_ok_for="Crimson Templar", loot_items=0)
    with pytest.raises(RuntimeError, match="Targeted corpse 'Crimson Templar', but InteractUnit"):
        loot_scenario._open_corpse(["Purpurroter Templer", "Crimson Templar"], 7, rpc=rpc, loot_timeout=0)
    rpc, _ = fake_rpc(target_ok_for="Purpurroter", loot_items=2)
    assert loot_scenario._open_corpse(["Purpurroter Templer"], 7, rpc=rpc) == ("Purpurroter Templer", 2)


def test_leave_party_is_best_effort():
    def broken(*a, **k):
        raise RuntimeError("pipe closed")
    loot_scenario._leave_party(7, rpc=broken)


def binding_rpc(loot_after_key=2, previous=""):
    state = {"pressed": False, "codes": []}
    def rpc(method, params=None, *, expected_pid):
        code = params["code"]
        state["codes"].append(code)
        if code.startswith("TargetUnit("):
            return {"ok": True, "result": 1}
        if code.startswith("local prev"):
            return {"ok": True, "result": previous}
        if code.startswith("SetBinding") or code.startswith("InteractUnit"):
            return {"ok": True, "result": True}
        return {"ok": True, "result": loot_after_key if state["pressed"] else 0}
    def press():
        state["pressed"] = True
    return rpc, press, state


def test_interact_key_fallback_opens_loot_and_restores_binding(monkeypatch):
    monkeypatch.setattr(loot_scenario.time, "sleep", lambda s: None)
    rpc, press, state = binding_rpc(previous="TOGGLEAUTORUN")
    assert loot_scenario._open_corpse(["Purpurroter Templer"], 7, rpc=rpc, press_key=press,
                                      loot_timeout=0) == ("Purpurroter Templer", 2)
    assert state["pressed"]
    assert state["codes"][-1] == "SetBinding('CTRL-SHIFT-F12', \"TOGGLEAUTORUN\") return true"


def test_interact_key_binding_is_restored_even_when_loot_stays_closed(monkeypatch):
    monkeypatch.setattr(loot_scenario.time, "sleep", lambda s: None)
    rpc, press, state = binding_rpc(loot_after_key=0)
    with pytest.raises(RuntimeError, match="neither InteractUnit nor the CTRL-SHIFT-F12"):
        loot_scenario._open_corpse(["X"], 7, rpc=rpc, press_key=press, loot_timeout=0)
    assert state["codes"][-1] == "SetBinding('CTRL-SHIFT-F12') return true"


def test_unexpected_previous_binding_never_presses_a_key(monkeypatch):
    monkeypatch.setattr(loot_scenario.time, "sleep", lambda s: None)
    rpc, press, state = binding_rpc(previous="x') os.exit() --")
    with pytest.raises(RuntimeError, match="nothing was pressed"):
        loot_scenario._open_corpse(["X"], 7, rpc=rpc, press_key=press, loot_timeout=0)
    assert not state["pressed"]


def test_sdk_float_numbers_count_as_open_loot(monkeypatch):
    monkeypatch.setattr(loot_scenario.time, "sleep", lambda s: None)
    def rpc(method, params=None, *, expected_pid):
        code = params["code"]
        if code.startswith("TargetUnit("):
            return {"ok": True, "result": 1.0}
        if code.startswith("InteractUnit"):
            return {"ok": True, "result": True}
        return {"ok": True, "result": 1.0}
    assert loot_scenario._open_corpse(["Purpurroter Templer"], 7, rpc=rpc, loot_timeout=0) == ("Purpurroter Templer", 1)


def test_invite_is_found_in_any_popup_slot(monkeypatch):
    monkeypatch.setattr(loot_scenario.time, "sleep", lambda s: None)
    codes = []
    def rpc(method, params=None, *, expected_pid):
        codes.append(params["code"])
        if params["code"] == loot_scenario.FIND_INVITE_CODE:
            return {"ok": True, "result": "StaticPopup2"}
        return {"ok": True, "result": True}
    loot_scenario._accept_invite(7, rpc=rpc, timeout=0)
    assert "_G['StaticPopup2Button1']" in codes[-1]


def test_missing_invite_reports_visible_popups(monkeypatch):
    monkeypatch.setattr(loot_scenario.time, "sleep", lambda s: None)
    def rpc(method, params=None, *, expected_pid):
        if params["code"] == loot_scenario.FIND_INVITE_CODE:
            return {"ok": True, "result": ""}
        return {"ok": True, "result": "CAMP"}
    with pytest.raises(RuntimeError, match="visible popups: CAMP"):
        loot_scenario._accept_invite(7, rpc=rpc, timeout=0)


def test_unexpected_popup_name_is_never_used_in_lua(monkeypatch):
    monkeypatch.setattr(loot_scenario.time, "sleep", lambda s: None)
    codes = []
    def rpc(method, params=None, *, expected_pid):
        codes.append(params["code"])
        if params["code"] == loot_scenario.FIND_INVITE_CODE:
            return {"ok": True, "result": "x'] os.exit() --"}
        return {"ok": True, "result": ""}
    with pytest.raises(RuntimeError):
        loot_scenario._accept_invite(7, rpc=rpc, timeout=0)
    assert not any("os.exit" in c for c in codes)
