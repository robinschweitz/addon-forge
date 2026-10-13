from pathlib import Path
from addon_forge.deploy import deploy


def test_deploy_and_replace(tmp_path):
    wow = tmp_path / "wow"
    wow.mkdir()
    (wow / "Wow.exe").touch()
    addon = tmp_path / "Demo"
    addon.mkdir()
    (addon / "Demo.toc").write_text("## Interface: 30300\nDemo.lua\n")
    (addon / "Demo.lua").write_text("local x = 1\n")
    dest = deploy(addon, wow)
    assert (dest / "Demo.lua").read_text() == "local x = 1\n"
    (addon / "Demo.lua").write_text("local x = 2\n")
    dest = deploy(addon, wow)
    assert (dest / "Demo.lua").read_text() == "local x = 2\n"
    assert not (dest.parent / ".forge-backup-Demo").exists()

def test_example_smoke_assertion_tolerates_legacy_ui_rounding():
    # Regression: WoW 3.3.5a GetWidth can return a nearby fractional
    # value depending on window resolution and UI scale.
    from pathlib import Path
    script = Path(__file__).resolve().parents[1] / "examples" / "ForgeExample" / "ForgeExample.lua"
    code = script.read_text(encoding="utf-8")
    assert "math.abs(width - 200) <= 2" in code
    assert "tostring(width)" in code
