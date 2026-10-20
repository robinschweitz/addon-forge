"""Keep tests independent of a developer's local 3.3.5a client dump and Codex data."""
import pytest

from addon_forge import wowapi


@pytest.fixture(autouse=True)
def isolate_client_dump(monkeypatch, tmp_path_factory):
    monkeypatch.setattr(wowapi, "DUMP_PATH", tmp_path_factory.mktemp("api") / "globals-30300.txt")
    monkeypatch.setattr(wowapi, "CODEX_DIR", tmp_path_factory.mktemp("codex"))
