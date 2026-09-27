#!/usr/bin/env python3
"""Verify cache readers and pulls coordinate through the cross-process store lock."""

import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def blocked_until_unlock(binary: str, env: dict[str, str], lock: object, args: list[str]) -> subprocess.CompletedProcess[str]:
    process = subprocess.Popen([binary, *args], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(0.3)
        if process.poll() is not None:
            raise RuntimeError(f"command did not wait for cache lock: {args}")
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
    try:
        stdout, stderr = process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_cache_lock.py <rift>", file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="rift-cache-lock-check-") as home:
        env = dict(os.environ, HOME=home)
        initial = subprocess.run([binary, "images"], env=env, capture_output=True, text=True, timeout=10)
        if initial.returncode != 0:
            raise RuntimeError(f"could not initialize image store: {initial!r}")
        lock_path = Path(home) / "Library/Application Support/Rift/cache.lock"
        with lock_path.open("r+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            reader = blocked_until_unlock(binary, env, lock, ["images"])
            if reader.returncode != 0 or "No images pulled yet." not in reader.stdout:
                raise RuntimeError(f"cache reader failed after exclusive lock release: {reader!r}")
            fcntl.flock(lock, fcntl.LOCK_SH)
            concurrent_reader = subprocess.run([binary, "images"], env=env, capture_output=True, text=True, timeout=10)
            if concurrent_reader.returncode != 0:
                raise RuntimeError(f"shared cache reader was blocked: {concurrent_reader!r}")
            writer = blocked_until_unlock(binary, env, lock, ["pull", "@@"])
            if writer.returncode == 0 or "invalid OCI image reference" not in writer.stderr:
                raise RuntimeError(f"cache writer did not resume after shared lock release: {writer!r}")
    print("Rift cache lock check passed: shared readers, exclusive pull, cross-process waiting")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
