from pathlib import Path
from addon_forge.validate import check_addon, is_valid


def test_valid_example():
    root = Path(__file__).resolve().parents[1]
    errors = check_addon(root / "examples" / "ForgeExample")
    assert is_valid(errors), errors


def test_bad_interface_and_missing_file(tmp_path):
    (tmp_path / "Broken.toc").write_text("## Interface: 100000\nNotHere.lua\n")
    errors = check_addon(tmp_path)
    assert any("30300" in d.message for d in errors)
    assert any("Missing TOC" in d.message for d in errors)


def test_reject_toc_traversal(tmp_path):
    (tmp_path / "Bad.toc").write_text("## Interface: 30300\n../../secrets.lua\n")
    errors = check_addon(tmp_path)
    assert not is_valid(errors)
