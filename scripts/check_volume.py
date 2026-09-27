#!/usr/bin/env python3
"""Check explicit file and directory volumes in the Linux guest."""

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
        nested_output = Path(temporary) / "nested-output"
        nested_output.mkdir()
        (source / "nested").mkdir()
        (source / "message").write_text("FROM_HOST\n")
        file_source = Path(temporary) / "config with space"
        file_source.write_text("FILE_FROM_HOST\n")

        read = run(binary, "-v", f"{source}:/input", "alpine", "cat", "/input/message")
        if read.returncode != 0 or read.stdout.strip() != "FROM_HOST":
            raise RuntimeError(f"read-only volume was not readable: {read!r}")
        denied = run(binary, "-v", f"{source}:/input", "alpine", "sh", "-c", "echo changed > /input/message")
        if denied.returncode == 0 or (source / "message").read_text() != "FROM_HOST\n":
            raise RuntimeError(f"read-only volume was writable: {denied!r}")
        file_read = run(binary, "-v", f"{file_source}:/run/rift-config", "alpine", "cat", "/run/rift-config")
        if file_read.returncode != 0 or file_read.stdout.strip() != "FILE_FROM_HOST":
            raise RuntimeError(f"read-only file volume was not readable: {file_read!r}")
        file_denied = run(binary, "-v", f"{file_source}:/run/rift-config", "alpine", "sh", "-c", "echo changed > /run/rift-config")
        if file_denied.returncode == 0 or file_source.read_text() != "FILE_FROM_HOST\n":
            raise RuntimeError(f"read-only file volume was writable: {file_denied!r}")
        file_written = run(binary, "-v", f"{file_source}:/run/rift-config:rw", "alpine", "sh", "-c", "echo FILE_CHANGED > /run/rift-config")
        if file_written.returncode != 0 or file_source.read_text() != "FILE_CHANGED\n":
            raise RuntimeError(f"writable file volume did not update the host file: {file_written!r}")
        nested_file_target = run(binary, "-v", f"{file_source}:/data", "-v", f"{output}:/data/child", "alpine", "/bin/true")
        if nested_file_target.returncode != 2 or "file volume target cannot contain another volume target" not in nested_file_target.stderr:
            raise RuntimeError(f"file volume parent target was accepted: {nested_file_target!r}")
        copied = run(binary, "-v", f"{output}:/data:rw", "-v", f"{source}:/data/input:ro", "alpine", "sh", "-c", "cat /data/input/message > /data/copy")
        if copied.returncode != 0 or (output / "copy").read_text() != "FROM_HOST\n":
            raise RuntimeError(f"nested writable volume failed: {copied!r}")
        readonly_parent = run(binary, "-v", f"{source}:/data:ro", "-v", f"{nested_output}:/data/nested:rw", "alpine", "sh", "-c", "echo CHILD_CHANGED > /data/nested/child; echo PARENT_CHANGED > /data/message")
        if readonly_parent.returncode == 0 or (nested_output / "child").read_text() != "CHILD_CHANGED\n" or (source / "message").read_text() != "FROM_HOST\n":
            raise RuntimeError(f"nested writable volume escaped its read-only parent: {readonly_parent!r}")
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
        unsafe_parent_target = run(binary, "-v", f"{source}:/var/run/rift-volume", "alpine", "/bin/true")
        if unsafe_parent_target.returncode != 125 or "rift-exec: open volume target:" not in unsafe_parent_target.stdout:
            raise RuntimeError(f"directory volume traversed a symlinked target parent: {unsafe_parent_target!r}")
        unsafe_file_parent_target = run(binary, "-v", f"{file_source}:/var/run/rift-volume", "alpine", "/bin/true")
        if unsafe_file_parent_target.returncode != 125 or "rift-exec: open volume target:" not in unsafe_file_parent_target.stdout:
            raise RuntimeError(f"file volume traversed a symlinked target parent: {unsafe_file_parent_target!r}")
        source_link = Path(temporary) / "link"
        source_link.symlink_to(source, target_is_directory=True)
        unsafe_source = run(binary, "-v", f"{source_link}:/input", "alpine", "/bin/true")
        if unsafe_source.returncode != 2 or "volume source must be an existing directory or regular file" not in unsafe_source.stderr:
            raise RuntimeError(f"symlink volume source was accepted: {unsafe_source!r}")
        file_link = Path(temporary) / "file-link"
        file_link.symlink_to(file_source)
        unsafe_file_source = run(binary, "-v", f"{file_link}:/input", "alpine", "/bin/true")
        if unsafe_file_source.returncode != 2 or "volume source must be an existing directory or regular file" not in unsafe_file_source.stderr:
            raise RuntimeError(f"symlink file volume source was accepted: {unsafe_file_source!r}")
        unsafe_file_target = run(binary, "-v", f"{file_source}:/bin/sh", "alpine", "/bin/true")
        if unsafe_file_target.returncode != 125 or "file volume target must be a regular file" not in unsafe_file_target.stdout:
            raise RuntimeError(f"symlink file volume target was accepted: {unsafe_file_target!r}")
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
    print("Rift volume check passed: read-only and writable file/directory shares, nested mounts, detached, 16 shares, and symlink-target rejection")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
