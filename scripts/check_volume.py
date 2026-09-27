#!/usr/bin/env python3
"""Check explicit read-only and writable directory volumes in the Linux guest."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


def run(binary: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([binary, "run", *args], capture_output=True, text=True, timeout=60)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_volume.py <rift>", file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())
    runtime = Path.home() / "Library/Application Support/Rift/runtime"
    before = set(runtime.iterdir()) if runtime.exists() else set()
    with tempfile.TemporaryDirectory(prefix="rift-volume-check-") as temporary:
        source = Path(temporary) / "input with space"
        output = Path(temporary) / "output"
        source.mkdir()
        output.mkdir()
        (source / "message").write_text("FROM_HOST\n")

        read = run(binary, "-v", f"{source}:/input", "alpine", "cat", "/input/message")
        if read.returncode != 0 or read.stdout.strip() != "FROM_HOST":
            raise RuntimeError(f"read-only volume was not readable: {read!r}")
        denied = run(binary, "-v", f"{source}:/input", "alpine", "sh", "-c", "echo changed > /input/message")
        if denied.returncode == 0 or (source / "message").read_text() != "FROM_HOST\n":
            raise RuntimeError(f"read-only volume was writable: {denied!r}")
        copied = run(binary, "-v", f"{output}:/data:rw", "-v", f"{source}:/data/input:ro", "alpine", "sh", "-c", "cat /data/input/message > /data/copy")
        if copied.returncode != 0 or (output / "copy").read_text() != "FROM_HOST\n":
            raise RuntimeError(f"nested writable volume failed: {copied!r}")
        many = [item for index in range(16) for item in ("-v", f"{source}:/volume/{index}")]
        maximum = run(binary, *many, "alpine", "cat", "/volume/15/message")
        if maximum.returncode != 0 or maximum.stdout.strip() != "FROM_HOST":
            raise RuntimeError(f"maximum volume count failed: {maximum!r}")

        shell_link = run(binary, "alpine", "readlink", "/bin/sh")
        if shell_link.returncode != 0 or not shell_link.stdout.strip():
            raise RuntimeError(f"Alpine shell was not a symlink for safety check: {shell_link!r}")
        unsafe_target = run(binary, "-v", f"{source}:/bin/sh", "alpine", "/bin/true")
        if unsafe_target.returncode != 125 or "rift-exec: open volume target:" not in unsafe_target.stdout:
            raise RuntimeError(f"symlink volume target was accepted: {unsafe_target!r}")
        source_link = Path(temporary) / "link"
        source_link.symlink_to(source, target_is_directory=True)
        unsafe_source = run(binary, "-v", f"{source_link}:/input", "alpine", "/bin/true")
        if unsafe_source.returncode != 2 or "volume source must be an existing directory" not in unsafe_source.stderr:
            raise RuntimeError(f"symlink volume source was accepted: {unsafe_source!r}")
        unsafe_path = run(binary, "-v", f"{source}:/../escape", "alpine", "/bin/true")
        if unsafe_path.returncode != 2 or "volume must use absolute" not in unsafe_path.stderr:
            raise RuntimeError(f"unsafe volume path was accepted: {unsafe_path!r}")
        for target in ("/dev", "/dev/pts", "/proc", "/proc/1"):
            reserved = run(binary, "-v", f"{source}:{target}", "alpine", "/bin/true")
            if reserved.returncode != 2 or "volume target cannot be /dev or /proc" not in reserved.stderr:
                raise RuntimeError(f"reserved volume target was accepted: {reserved!r}")

        started = run(binary, "-d", "-v", f"{output}:/out:rw", "alpine", "sh", "-c", "echo DETACHED > /out/worker; sleep 30")
        identifier = started.stdout.strip()
        if started.returncode != 0 or re.fullmatch(r"[0-9a-f]{32}", identifier) is None:
            raise RuntimeError(f"detached volume did not start: {started!r}")
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not (output / "worker").exists():
                time.sleep(0.2)
            if not (output / "worker").exists() or (output / "worker").read_text() != "DETACHED\n":
                raise RuntimeError("detached volume write did not reach the host")
            stopped = subprocess.run([binary, "stop", identifier], capture_output=True, text=True, timeout=15)
            if stopped.returncode != 0:
                raise RuntimeError(f"detached volume did not stop: {stopped!r}")
            removed = subprocess.run([binary, "rm", identifier], capture_output=True, text=True, timeout=15)
            if removed.returncode != 0:
                raise RuntimeError(f"detached volume state was not removed: {removed!r}")
        finally:
            subprocess.run([binary, "stop", identifier], capture_output=True, timeout=15)
            subprocess.run([binary, "rm", identifier], capture_output=True, timeout=15)

    after = set(runtime.iterdir()) if runtime.exists() else set()
    if after != before:
        raise RuntimeError(f"volume runs left runtime staging behind: {after - before}")
    print("Rift volume check passed: read-only, writable, nested, detached, 16 shares, and unsafe-target rejection")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
