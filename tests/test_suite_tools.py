"""forge new, the MCP tool server, and the SDK bridge/API-dump transports."""
import io
import json
from pathlib import Path

import pytest

from addon_forge import mcp_server, wowapi, wowcontrol
from addon_forge.config import Config
from addon_forge.headless import run_specs
from addon_forge.scaffold import new_addon
from addon_forge.scenario_plan import load_plan
from addon_forge.validate import check_addon, is_valid


@pytest.fixture(autouse=True)
def no_client_dump(monkeypatch, tmp_path):
    monkeypatch.setattr(wowapi, "DUMP_PATH", tmp_path / "no-dump.txt")


def test_scaffold_passes_static_offline_and_plan_validation(tmp_path):
    made = new_addon("RaidTimer", root=tmp_path)
    addon = Path(made["addon"])
    assert is_valid(check_addon(addon)), check_addon(addon)
    result = run_specs(addon)
    assert result["status"] == "passed", result
    assert result["tests"] == 4
    plan = load_plan(Path(made["plan"]))
    assert {c["type"] for c in plan["checks"]} >= {"frame_visible", "global_equals", "no_lua_errors"}
    with pytest.raises(FileExistsError):
        new_addon("RaidTimer", root=tmp_path)
    with pytest.raises(ValueError):
        new_addon("../Escape", root=tmp_path)


def rpc_session(tmp_path, *messages, allow=False):
    out = io.StringIO()
    lines = "\n".join(json.dumps(m) for m in messages) + "\n"
    mcp_server.serve(tmp_path, tmp_path / "forge.toml", allow_fixtures=allow,
                     stdin=io.StringIO(lines), stdout=out)
    return [json.loads(line) for line in out.getvalue().splitlines()]


def call(i, tool, **arguments):
    return {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": tool, "arguments": arguments}}


def test_mcp_handshake_lists_tools_and_ignores_notifications(tmp_path):
    replies = rpc_session(tmp_path,
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "nope"})
    assert [r["id"] for r in replies] == [1, 2, 3]
    assert replies[0]["result"]["serverInfo"]["name"] == "addon-forge"
    names = {t["name"] for t in replies[1]["result"]["tools"]}
    assert {"forge_new", "forge_check", "forge_spec", "forge_api_lookup", "forge_run_plan"} <= names
    assert replies[2]["error"]["code"] == -32601


def test_mcp_tools_create_check_and_spec_inside_projects(tmp_path):
    replies = rpc_session(tmp_path,
        call(1, "forge_new", name="LootNotes"),
        call(2, "forge_check", addon="LootNotes"),
        call(3, "forge_spec", addon="LootNotes"),
        call(4, "forge_check", addon="../.."),
        call(5, "forge_api_lookup", names=["GetNumGroupMembers", "C_Timer"]))
    assert not replies[0]["result"]["isError"]
    assert json.loads(replies[1]["result"]["content"][0]["text"])["valid"] is True
    assert json.loads(replies[2]["result"]["content"][0]["text"])["status"] == "passed"
    assert replies[3]["result"]["isError"] and "inside projects" in replies[3]["result"]["content"][0]["text"]
    lookups = json.loads(replies[4]["result"]["content"][0]["text"])
    assert [x["exists"] for x in lookups] == [False, False]


def test_mcp_run_plan_requires_human_flag(tmp_path, monkeypatch):
    def never(*a, **k):
        pytest.fail("real-client run without --allow-fixtures")
    monkeypatch.setattr("addon_forge.agent_workflow.run_plan", never)
    reply = rpc_session(tmp_path, call(1, "forge_run_plan", plan="X-acceptance.json"))[0]
    assert json.loads(reply["result"]["content"][0]["text"])["status"] == "not_authorized"


def test_bridge_run_sends_constant_lua_with_validated_paths():
    sent = []
    def rpc(method, params=None, *, expected_pid):
        sent.append((method, params, expected_pid))
        return {"ok": True, "result": json.dumps({"completed": True, "runId": "abc"})}
    cfg = Config(wow_dir=Path("."), wine_prefix=Path("."))
    report = wowcontrol.bridge_run(cfg, "smoke", "abc", ("MyDB.count",), rpc=rpc, pid=7)
    assert report["runId"] == "abc"
    method, params, pid = sent[0]
    assert method == "lua.evaluate" and pid == 7
    assert 'ForgeTestBridge:RunJSON("smoke", "abc", {"MyDB.count"})' in params["code"]
    for bad in (("x'); os.exit() --",), ("A.b.c.d.e.f.g",), tuple(f"P{i}" for i in range(11))):
        with pytest.raises(ValueError):
            wowcontrol.bridge_run(cfg, "smoke", "abc", bad, rpc=rpc, pid=7)
    with pytest.raises(ValueError):
        wowcontrol.bridge_run(cfg, "smoke;", "abc", (), rpc=rpc, pid=7)


def test_bridge_run_reports_missing_bridge():
    cfg = Config(wow_dir=Path("."), wine_prefix=Path("."))
    with pytest.raises(RuntimeError, match="not loaded"):
        wowcontrol.bridge_run(cfg, "smoke", "abc", rpc=lambda *a, **k: {"ok": True, "result": "bridge_missing"}, pid=1)


def test_api_dump_reassembles_chunks_and_fits_the_pipe(tmp_path):
    names = [f"Global{i}" for i in range(1500)] + ["Button:SetText", "Frame:SetWidth", "ForgeApiDump"]
    def rpc(method, params=None, *, expected_pid):
        if method == "client.getScreen":
            return {"screen": "world", "inWorld": True}
        code = params["code"]
        assert len(json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})) <= 2048
        start = int(code.split("local i, out, size = ")[1].split(",")[0])
        chunk = names[start - 1:start + 499]
        return {"ok": True, "result": f"{len(names)}|{start - 1 + len(chunk)}|{','.join(chunk)}"}
    cfg = Config(wow_dir=Path("."), wine_prefix=Path("."))
    result = wowcontrol.dump_api(cfg, rpc=rpc, pid=3)
    assert result["globals"] == 1500 and result["methods"] == 2
    assert wowapi.known_globals() and "Global42" in wowapi.known_globals()
    assert "SetText" in wowapi.known_methods()["Button"]
    assert wowapi.lookup("Button:SetTextColor")["exists"] is False


def test_api_dump_refuses_outside_world():
    cfg = Config(wow_dir=Path("."), wine_prefix=Path("."))
    with pytest.raises(RuntimeError, match="world"):
        wowcontrol.dump_api(cfg, rpc=lambda *a, **k: {"screen": "charselect", "inWorld": False}, pid=3)


class MessagePipe:
    """Fake pywin32 transport returning a large message in ERROR_MORE_DATA pieces."""
    def __init__(self, payload: bytes, piece: int):
        self.payload, self.piece = payload, piece
    def WriteFile(self, handle, data):
        pass
    def ReadFile(self, handle, size):
        chunk, self.payload = self.payload[:self.piece], self.payload[self.piece:]
        return (wowcontrol.ERROR_MORE_DATA if self.payload else 0), chunk
    def CloseHandle(self, handle):
        pass


def test_request_reassembles_large_message_mode_replies(monkeypatch):
    from addon_forge import wowcontrol_pipe
    monkeypatch.setattr(wowcontrol_pipe, "open_verified_pipe", lambda transport, pid: 1)
    big = "x" * 200_000
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"ok": True, "result": big}}).encode()
    reply = wowcontrol.request("lua.evaluate", {"code": "return 1"}, expected_pid=5,
                               transport=MessagePipe(payload, 65536))
    assert reply["result"] == big
    truncated = MessagePipe(payload[:100], 65536)
    with pytest.raises(RuntimeError, match="truncated or malformed"):
        wowcontrol.request("lua.evaluate", {"code": "return 1"}, expected_pid=5, transport=truncated)


class FlakyPipe:
    """CreateFile fails like the SDK's single-threaded pipe between instances."""
    GENERIC_READ, GENERIC_WRITE, OPEN_EXISTING = 1, 2, 3
    def __init__(self, failures, code=2):
        self.failures, self.code, self.calls = failures, code, 0
    def CreateFile(self, *args):
        self.calls += 1
        if self.calls <= self.failures:
            raise OSError(self.code, "CreateFile", "Das System kann die angegebene Datei nicht finden.")
        return 42


def test_pipe_connect_retries_while_sdk_is_between_instances():
    from addon_forge.wowcontrol_pipe import _connect
    pipe = FlakyPipe(failures=3)
    assert _connect(pipe, sleep=lambda s: None) == 42 and pipe.calls == 4
    busy = FlakyPipe(failures=2, code=231)
    assert _connect(busy, sleep=lambda s: None) == 42


def test_pipe_connect_gives_up_with_a_clear_error_and_never_retries_other_errors():
    from addon_forge.wowcontrol_pipe import _connect
    now = [0.0]
    def sleep(s):
        now[0] += s
    with pytest.raises(RuntimeError, match="did not become available"):
        _connect(FlakyPipe(failures=10**6), clock=lambda: now[0], sleep=sleep, timeout=1)
    denied = FlakyPipe(failures=1, code=5)  # access denied: not a transient gap
    with pytest.raises(OSError):
        _connect(denied, sleep=lambda s: None)
    assert denied.calls == 1
