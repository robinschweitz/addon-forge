import pytest
from addon_forge.ai import safe_changes, apply_changes


def test_only_addon_files(tmp_path):
    changes = safe_changes({"changes": [{"path": "Core.lua", "content": "local a=1"}]})
    apply_changes(tmp_path, changes)
    assert (tmp_path / "Core.lua").read_text() == "local a=1"


@pytest.mark.parametrize("name", ["../tests/test.py", "/tmp/evil.lua", "tests/smoke.lua", "foo.sh", ".git/config", "nested/../../evil.lua"])
def test_reject_illegal_changes(name):
    with pytest.raises(ValueError):
        safe_changes({"changes": [{"path": name, "content": "x"}]})


def test_repair_restores_original_on_model_error(tmp_path, monkeypatch):
    from addon_forge import ai
    addon = tmp_path / "Broken"
    addon.mkdir()
    (addon / "Broken.toc").write_text("## Interface: 10000\nBroken.lua\n")
    (addon / "Broken.lua").write_text("local a=1\n")
    before = (addon / "Broken.lua").read_text()

    def bad_model(*args):
        # Valid candidate, but introduces an invalid TOC; the next call crashes.
        if not hasattr(bad_model, "done"):
            bad_model.done = True
            return {"changes": [{"path": "Broken.lua", "content": "local a=2"}]}
        raise ConnectionError("model unavailable")

    monkeypatch.setattr(ai, "ask_model", bad_model)
    with pytest.raises(ConnectionError):
        ai.repair_addon(addon, max_attempts=2)
    assert (addon / "Broken.lua").read_text() == before
