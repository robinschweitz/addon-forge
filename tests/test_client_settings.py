from pathlib import Path
import pytest
from addon_forge.client_settings import configure_windowed


def game(tmp_path):
    wow = tmp_path / "test-WoW"
    wow.mkdir()
    (wow / "Wow.exe").touch()
    (wow / "WTF").mkdir()
    return wow


def test_windowed_config_backs_up_and_is_repeatable(tmp_path):
    wow = game(tmp_path)
    settings = wow / "WTF" / "Config.wtf"
    original = 'SET gxWindow "0"\nSET gxMaximize "1"\nSET accountName "NOT-CHANGED"\n'
    settings.write_text(original)
    path, backup = configure_windowed(wow)
    assert path == settings
    assert backup.read_text() == original
    content = path.read_text()
    assert 'SET gxWindow "1"' in content
    assert 'SET gxMaximize "0"' in content
    assert 'SET gxResolution "1280x720"' in content
    assert 'NOT-CHANGED' in content
    assert configure_windowed(wow)[0] == settings


def test_windowed_creates_new_settings_file(tmp_path):
    wow = game(tmp_path)
    path, backup = configure_windowed(wow, resolution="1024x768")
    assert backup is None
    assert 'SET gxResolution "1024x768"' in path.read_text()


def test_refuse_bad_resolution(tmp_path):
    wow = game(tmp_path)
    with pytest.raises(ValueError):
        configure_windowed(wow, resolution="100x100")


def test_refuse_existing_backup_on_change(tmp_path):
    wow = game(tmp_path)
    settings = wow / "WTF" / "Config.wtf"
    settings.write_text('SET gxWindow "0"\n')
    (wow / "WTF" / "Config.wtf.forge-backup").write_text("old backup")
    with pytest.raises(RuntimeError, match="backup"):
        configure_windowed(wow)
    assert settings.read_text() == 'SET gxWindow "0"\n'
