"""Security and extraction checks for guest-side client fetching (offline)."""
import hashlib
import importlib.util
import io
from pathlib import Path
import sys
import tarfile
import zipfile

import pytest

module = Path(__file__).resolve().parents[1] / "scripts/client_fetch.py"
spec = importlib.util.spec_from_file_location("client_fetch", module)
fetch = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = fetch
spec.loader.exec_module(fetch)

def test_safe_archive_paths(tmp_path):
    for name in ("../bad", "/absolute/file", "C:/windows/file", r"one\..\bad"):
        with pytest.raises(ValueError):
            fetch.safe_path(tmp_path, name)
    assert fetch.safe_path(tmp_path, "Data/enUS/data.MPQ") == tmp_path / "Data/enUS/data.MPQ"

def test_zip_extraction(tmp_path):
    archive = tmp_path / "game.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("Client/Wow.exe", b"MZ")
        z.writestr("Client/Data/enUS/file", b"data")
    dest = tmp_path / "out"
    dest.mkdir()
    fetch.extract_archive(archive, dest)
    assert fetch.get_client_root(dest) == dest / "Client"

def test_zip_traversal_rejected(tmp_path):
    archive = tmp_path / "evil.zip"
    with zipfile.ZipFile(archive, "w") as z:
        z.writestr("../escape", "bad")
    dest = tmp_path / "out"
    dest.mkdir()
    with pytest.raises(ValueError, match="Unsafe"):
        fetch.extract_archive(archive, dest)

def test_zip_symlink_rejected(tmp_path):
    archive = tmp_path / "link.zip"
    with zipfile.ZipFile(archive, "w") as z:
        item = zipfile.ZipInfo("link")
        item.create_system = 3
        item.external_attr = (0o120777 << 16)
        z.writestr(item, "target")
    dest = tmp_path / "out"
    dest.mkdir()
    with pytest.raises(ValueError, match="link/special"):
        fetch.extract_archive(archive, dest)

def test_tar_symlink_rejected(tmp_path):
    archive = tmp_path / "link.tar"
    with tarfile.open(archive, "w") as tf:
        item = tarfile.TarInfo("link")
        item.type = tarfile.SYMTYPE
        item.linkname = "../outside"
        tf.addfile(item)
    dest = tmp_path / "out"
    dest.mkdir()
    with pytest.raises(ValueError, match="link/special"):
        fetch.extract_archive(archive, dest)

def test_unverified_download_rejected(tmp_path):
    with pytest.raises(ValueError, match="HTTPS"):
        fetch.download("http://example.com/client.zip", "0" * 64, tmp_path / "download")
    with pytest.raises(ValueError, match="SHA-256"):
        fetch.download("https://example.com/client.zip", "invalid", tmp_path / "download")

def test_checksum_correct_and_incorrect(tmp_path, monkeypatch):
    payload = b"fake-test-archive-bytes"
    class Reply:
        def __enter__(self):
            return self
        def __exit__(self, *_):
            return False
        def geturl(self):
            return "https://example.com/game.zip"
        def read(self, size):
            nonlocal_payload = self.payload
            self.payload = b""
            return nonlocal_payload
        def __init__(self):
            self.payload = payload
    monkeypatch.setattr(fetch.urllib.request, "urlopen", lambda *a, **k: Reply())
    fetch.download("https://example.com/game.zip", hashlib.sha256(payload).hexdigest(), tmp_path / "good")
    assert (tmp_path / "good").read_bytes() == payload
    with pytest.raises(ValueError, match="SHA-256 mismatch"):
        fetch.download("https://example.com/game.zip", "f"*64, tmp_path / "bad")

def test_install_refuses_overwrite(tmp_path):
    destination = tmp_path / "game"
    destination.mkdir()
    with pytest.raises(FileExistsError):
        fetch.install("https://example.com/x", "0" * 64, destination)


def test_rising_gods_infohash_and_magnet():
    assert fetch.RISING_GODS_INFOHASH == "f59269930d5d91dc4d65782d71399082cc355ce4"
    assert fetch.RISING_GODS_MAGNET == "magnet:?xt=urn:btih:" + fetch.RISING_GODS_INFOHASH


def test_torrent_existing_destination_is_untouched(tmp_path):
    target = tmp_path / "WoW-3.3.5a"
    target.mkdir()
    with pytest.raises(FileExistsError):
        fetch.install_rising_gods(target)


def test_torrent_command_uses_known_infohash_and_integrity(monkeypatch, tmp_path):
    import subprocess
    calls = []

    def fake_run(argv, **kwargs):
        calls.append((argv, kwargs))
        stage = tmp_path / ".addon-forge-downloads/rising-gods/game"
        stage.mkdir(parents=True)
        (stage / "Wow.exe").write_bytes(b"MZ")
        (stage / "Data").mkdir()
        return subprocess.CompletedProcess(argv, 0)

    monkeypatch.setattr(fetch.subprocess, "run", fake_run)
    target = tmp_path / "WoW-3.3.5a"
    fetch.install_rising_gods(target)
    assert target.joinpath("Wow.exe").is_file()
    assert calls[0][0][-1] == fetch.RISING_GODS_MAGNET
    assert "--check-integrity=true" in calls[0][0]
    assert "--continue=true" in calls[0][0]
    assert "--seed-time=0" in calls[0][0]


def test_source_cli_does_not_require_archive_sha(monkeypatch, tmp_path):
    called = []
    monkeypatch.setattr(fetch, "install_rising_gods", lambda dest: called.append(dest))
    assert fetch.main(["--source", "rising-gods", "--destination", str(tmp_path / "WoW")]) == 0
    assert called == [tmp_path / "WoW"]
