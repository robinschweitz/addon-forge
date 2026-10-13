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
