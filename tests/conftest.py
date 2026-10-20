"""Keep tests independent of a developer's local client dump, Codex data and decompilation."""
import pytest

from addon_forge import wowapi


@pytest.fixture(autouse=True)
def isolate_client_dump(monkeypatch, tmp_path_factory):
    monkeypatch.setattr(wowapi, "DUMP_PATH", tmp_path_factory.mktemp("api") / "globals-30300.txt")
    monkeypatch.setattr(wowapi, "CODEX_DIR", tmp_path_factory.mktemp("codex"))
    monkeypatch.setattr(wowapi, "DECOMP_DIR", tmp_path_factory.mktemp("decomp") / "absent")
