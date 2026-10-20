from types import SimpleNamespace

import pytest

from addon_forge.config import Config
from addon_forge import xvfb_display


def test_xvfb_from_nix_uses_matching_mesa_drivers(tmp_path, monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: "/bin/" + name)
    built = {"nixpkgs#xorg.xorgserver": "/nix/store/x-xorg-server", "nixpkgs#mesa": "/nix/store/m-mesa"}
    run = lambda argv, **kw: SimpleNamespace(returncode=0, stdout=built[argv[-1]] + "\n")
    cfg = Config(wow_dir=tmp_path, wine_prefix=tmp_path, display=":79", xvfb="nix")
    argv, env = xvfb_display.xvfb_command(cfg, run=run)
    assert argv[:2] == ["/nix/store/x-xorg-server/bin/Xvfb", ":79"]
    assert "-nolisten" in argv and "tcp" in argv and "GLX" in argv
    assert env["LIBGL_DRIVERS_PATH"] == "/nix/store/m-mesa/lib/dri"


def test_headless_display_must_be_configured(tmp_path):
    with pytest.raises(ValueError, match="display"):
        xvfb_display.xvfb_command(Config(wow_dir=tmp_path, wine_prefix=tmp_path))
