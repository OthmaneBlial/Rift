#!/usr/bin/env python3
"""Check image blob cleanup against a copied real cache, never the user's store."""

import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from benchmark import copy_cache


def call(binary: str, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=90)


def add_blob(directory: Path, contents: bytes) -> Path:
    path = directory / hashlib.sha256(contents).hexdigest()
    path.write_bytes(contents)
    return path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_cache_prune.py <rift>", file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())
    source = Path.home() / "Library/Application Support/Rift"
    if not (source / "images").is_dir() or not (source / "blobs/sha256").is_dir() or not (source / "guest").is_dir():
        print("pull and run Alpine before cache-prune-check", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="rift-cache-prune-check-") as home:
        data = Path(home) / "Library/Application Support/Rift"
        copy_cache(source, data)
        env = dict(os.environ, HOME=home)
        blobs = data / "blobs/sha256"
        orphan = add_blob(blobs, b"rift orphan cache check")
        unknown = blobs / "notes.txt"
        unknown.write_text("keep unknown files")

        preview = call(binary, env, "clean")
        if preview.returncode != 0 or orphan.name not in preview.stdout or "Would remove" not in preview.stdout or not orphan.is_file():
            raise RuntimeError(f"cache preview failed or deleted data: {preview!r}")
        removed = call(binary, env, "clean", "--yes")
        if removed.returncode != 0 or orphan.exists() or not unknown.is_file() or "Removed" not in removed.stdout:
            raise RuntimeError(f"confirmed cache pruning failed: {removed!r}")
        preserved = call(binary, env, "run", "alpine", "/bin/echo", "CACHE_PRESERVED")
        if preserved.returncode != 0 or preserved.stdout.strip() != "CACHE_PRESERVED":
            raise RuntimeError(f"referenced Alpine was damaged by pruning: {preserved!r}")

        protected = add_blob(blobs, b"must survive invalid metadata")
        bad_record = data / "images/bad.rift"
        bad_record.write_text("invalid")
        rejected = call(binary, env, "clean", "--yes")
        if rejected.returncode == 0 or not protected.is_file() or "metadata is corrupt" not in rejected.stderr:
            raise RuntimeError(f"corrupt image metadata did not stop cache pruning: {rejected!r}")
        bad_record.unlink()
        missing = call(binary, env, "rmi", "rift-does-not-exist")
        if missing.returncode == 0 or "image reference was not found" not in missing.stderr:
            raise RuntimeError(f"missing local image removal did not fail: {missing!r}")
        removed_image = call(binary, env, "rmi", "alpine")
        images = call(binary, env, "images")
        if removed_image.returncode != 0 or images.returncode != 0 or "library/alpine:latest" in images.stdout:
            raise RuntimeError(f"local image removal failed: {removed_image!r} {images!r}")
        reclaim = call(binary, env, "clean", "--yes")
        if reclaim.returncode != 0:
            raise RuntimeError(f"removed image blobs could not be reclaimed: {reclaim!r}")
        if list((data / "runtime").iterdir()):
            raise RuntimeError("cache check left runtime staging behind")
    print("Rift cache prune check passed: preview, cleanup, preserved image, corrupt-record safety, local image removal")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
