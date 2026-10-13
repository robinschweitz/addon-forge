#!/usr/bin/env python3
"""Download an authorized WoW client archive straight into the guest's mutable disk.

The playable client is proprietary: no source URL or client data is bundled.
This tool only accepts a user-supplied HTTPS URL and an expected SHA-256 digest.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import shutil
import stat
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile

CHUNK_SIZE = 4 * 1024 * 1024
MAX_ARCHIVE_BYTES = 32 * 1024**3
MAX_EXTRACTED_BYTES = 80 * 1024**3
MAX_MEMBERS = 200_000
CLIENT_EXE = ("Wow.exe", "WoW.exe", "wow.exe")
# Rising Gods public torrent identifier, as published on their download-help page.
# Do not bundle the third-party game data or automatically download by default.
RISING_GODS_INFOHASH = "f59269930d5d91dc4d65782d71399082cc355ce4"
RISING_GODS_MAGNET = "magnet:?xt=urn:btih:" + RISING_GODS_INFOHASH


def safe_path(root: Path, name: str) -> Path:
    """Reject path traversal, drive letters and backslash-based ambiguity."""
    path = PurePosixPath(name)
    if (not name or name.startswith("/") or "\\" in name or
            re.match(r"^[A-Za-z]:", name) or ".." in path.parts):
        raise ValueError(f"Unsafe archive path: {name!r}")
    parts = [part for part in path.parts if part not in (".", "")]
    if not parts:
        return root
    return root.joinpath(*parts)


def stream_copy(source, target, *, remaining: int) -> int:
    """Copy archive member with a hard output byte bound."""
    transferred = 0
    while True:
        data = source.read(min(CHUNK_SIZE, remaining - transferred + 1))
        if not data:
            return transferred
        transferred += len(data)
        if transferred > remaining:
            raise ValueError("Archive extraction exceeds safety limit")
        target.write(data)


def extract_archive(archive: Path, destination: Path) -> None:
    """Extract regular files/directories only. Never follow archive symlinks."""
    total = 0
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as zf:
            entries = zf.infolist()
            if len(entries) > MAX_MEMBERS:
                raise ValueError("Archive has too many entries")
            for item in entries:
                mode = (item.external_attr >> 16) & 0o170000
                if mode not in (0, stat.S_IFREG, stat.S_IFDIR):
                    raise ValueError(f"Archive contains a link/special file: {item.filename}")
                path = safe_path(destination, item.filename)
                if item.is_dir():
                    path.mkdir(parents=True, exist_ok=True)
                    continue
                if path == destination:
                    raise ValueError("Archive contains a root file")
                total += item.file_size
                if total > MAX_EXTRACTED_BYTES:
                    raise ValueError("Archive extraction exceeds safety limit")
                path.parent.mkdir(parents=True, exist_ok=True)
                # Exclusive open rejects duplicate paths; avoid following symlinks.
                with zf.open(item) as source, path.open("xb") as target:
                    count = stream_copy(source, target, remaining=item.file_size)
                    if count != item.file_size:
                        raise ValueError(f"Incorrect extracted size: {item.filename}")
        return

    if tarfile.is_tarfile(archive):
        with tarfile.open(archive, mode="r:*") as tf:
            entries = tf.getmembers()
            if len(entries) > MAX_MEMBERS:
                raise ValueError("Archive has too many entries")
            for item in entries:
                path = safe_path(destination, item.name)
                if item.isdir():
                    path.mkdir(parents=True, exist_ok=True)
                    continue
                if not item.isfile() or path == destination:
                    raise ValueError(f"Archive contains a link/special file: {item.name}")
                total += item.size
                if total > MAX_EXTRACTED_BYTES:
                    raise ValueError("Archive extraction exceeds safety limit")
                path.parent.mkdir(parents=True, exist_ok=True)
                source = tf.extractfile(item)
                if source is None:
                    raise ValueError(f"Unreadable archive entry: {item.name}")
                with source, path.open("xb") as target:
                    count = stream_copy(source, target, remaining=item.size)
                    if count != item.size:
                        raise ValueError(f"Incorrect extracted size: {item.name}")
        return
    raise ValueError("Unsupported archive format; use ZIP, .tar.gz, .tar.xz or .tar")


def get_client_root(unpacked: Path) -> Path:
    candidates = [p.parent for p in unpacked.rglob("*")
                  if p.is_file() and p.name in CLIENT_EXE]
    if len(candidates) != 1:
        raise ValueError("Archive must contain exactly one WoW client (Wow.exe)")
    root = candidates[0]
    if not (root / "Data").is_dir():
        raise ValueError("Client archive must include its Data directory")
    return root


def download(url: str, expected_digest: str, output: Path) -> None:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("A public HTTPS download URL without embedded credentials is required")
    if not re.fullmatch(r"[a-fA-F0-9]{64}", expected_digest):
        raise ValueError("Expected SHA-256 must contain exactly 64 hex characters")
    request = urllib.request.Request(url, headers={"User-Agent": "AddonForge-ClientImporter/0.1"})
    digest = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(request, timeout=60) as response:
        if urllib.parse.urlsplit(response.geturl()).scheme != "https":
            raise ValueError("Download redirected away from HTTPS")
        with output.open("xb") as target:
            while True:
                chunk = response.read(CHUNK_SIZE)
                if not chunk:
                    break
                size += len(chunk)
                if size > MAX_ARCHIVE_BYTES:
                    raise ValueError("Client archive exceeds 32 GiB download limit")
                digest.update(chunk)
                target.write(chunk)
    if digest.hexdigest() != expected_digest.lower():
        raise ValueError("SHA-256 mismatch: archive is not the expected file")


def install(url: str, digest: str, destination: Path) -> None:
    destination = destination.expanduser().absolute()
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"Destination exists; refusing to overwrite: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".forge-client-", dir=destination.parent) as scratch:
        work = Path(scratch)
        archive = work / "download"
        print("Downloading client archive directly to VM storage...", flush=True)
        download(url, digest, archive)
        unpacked = work / "unpacked"
        unpacked.mkdir()
        print("Checksum verified; extracting client...", flush=True)
        extract_archive(archive, unpacked)
        client_root = get_client_root(unpacked)
        os.replace(client_root, destination)
    print(f"Client installed at {destination}")
    print("Next: set Data/<locale>/realmlist.wtf to 127.0.0.1, then run forge doctor.")



def install_rising_gods(destination: Path, *, executable: str = "aria2c") -> None:
    """Explicit opt-in download of third-party 3.3.5a client via magnet link.

    BitTorrent verifies downloaded pieces against the metadata identified by the
    published infohash. This is not a Blizzard-supplied or legally vetted copy.
    An interrupted download can resume in the same staging directory.
    """
    destination = destination.expanduser().absolute()
    if destination.exists() or destination.is_symlink():
        raise FileExistsError(f"Destination exists; refusing to overwrite: {destination}")
    stage = destination.parent / ".addon-forge-downloads" / "rising-gods"
    stage.mkdir(parents=True, exist_ok=True)
    cmd = [
        executable, "--dir", str(stage), "--continue=true",
        "--check-integrity=true", "--seed-time=0",
        "--auto-file-renaming=false", "--allow-overwrite=false",
        "--bt-save-metadata=true",
        RISING_GODS_MAGNET,
    ]
    print("Downloading Rising Gods 3.3.5a client to VM storage via BitTorrent.", flush=True)
    print("Your IP address is visible to torrent peers; check your rights to use this distribution.", flush=True)
    try:
        subprocess.run(cmd, check=True)
    except FileNotFoundError as exc:
        raise RuntimeError("aria2c is required for BitTorrent downloads") from exc
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(f"BitTorrent download failed; rerun to resume (exit {exc.returncode})") from exc
    # Do not trust filenames merely because the selected torrent matched.
    for entry in stage.rglob("*"):
        if entry.is_symlink():
            raise ValueError(f"Downloaded client contains a symlink: {entry}")
    root = get_client_root(stage)
    if not root.resolve().is_relative_to(stage.resolve()):
        raise ValueError("Client directory escapes download storage")
    # Moving instead of copying avoids a second ~17 GB disk allocation.
    os.replace(root, destination)
    print(f"Rising Gods client installed at {destination}")
    print("The download may target Rising Gods by default; change the realmlist for your local AzerothCore realm.")
    print("Next: set Data/<locale>/realmlist.wtf to 'set realmlist 127.0.0.1' and run forge doctor.")

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="forge-fetch-client",
        description="Download your authorized 3.3.5a client archive directly into this VM.")
    source = p.add_mutually_exclusive_group(required=True)
    source.add_argument("--url", help="Trusted direct HTTPS URL for ZIP or tar archive")
    source.add_argument("--source", choices=["rising-gods"],
                        help="Opt in to a specific external 3.3.5a BitTorrent source")
    p.add_argument("--sha256", help="Expected archive SHA-256 (required with --url)")
    p.add_argument("--destination", type=Path,
                   default=Path.home() / "Games" / "WoW-3.3.5a")
    args = p.parse_args(argv)
    if args.url and not args.sha256:
        p.error("--sha256 is required with --url")
    if args.source and args.sha256:
        p.error("--sha256 is only applicable to --url downloads")
    try:
        if args.source == "rising-gods":
            install_rising_gods(args.destination)
        else:
            install(args.url, args.sha256, args.destination)
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile,
            tarfile.TarError) as exc:
        print(f"forge-fetch-client: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
