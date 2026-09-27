#!/usr/bin/env python3
"""Check the detached Rift process, logs, stop, and removal locally."""

import re
import subprocess
import sys
import time
from pathlib import Path


def call(rift: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([rift, *args], capture_output=True, text=True, timeout=15)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_detached.py <rift>", file=sys.stderr)
        return 2
    rift = sys.argv[1]
    runtime = Path.home() / "Library/Application Support/Rift/runtime"
    before = set(runtime.iterdir()) if runtime.exists() else set()
    started = call(rift, "run", "-d", "-e", "RIFT_CHECK=RIFT_DETACHED_OK", "alpine", "/bin/sh", "-c", 'echo "$RIFT_CHECK"; sleep 30')
    identifier = started.stdout.strip()
    if started.returncode != 0 or re.fullmatch(r"[0-9a-f]{32}", identifier) is None:
        print(f"Rift detached check failed to start: {started!r}", file=sys.stderr)
        return 1
    try:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            listed = call(rift, "ps")
            logged = call(rift, "logs", identifier)
            if listed.returncode == 0 and f"{identifier}  alpine  running" in listed.stdout and "RIFT_DETACHED_OK" in logged.stdout:
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("container never reached running state with readable logs")
        active = set(runtime.iterdir()) - before
        preview = call(rift, "clean")
        if preview.returncode != 0 or len(active) != 1 or next(iter(active)).name in preview.stdout:
            raise RuntimeError(f"clean offered to remove active staging: {preview!r}")
        stopped = call(rift, "stop", identifier)
        if stopped.returncode != 0 or f"Stopped {identifier}" not in stopped.stdout:
            raise RuntimeError(f"stop failed: {stopped!r}")
        listed = call(rift, "ps")
        if f"{identifier}  alpine  stopped" not in listed.stdout:
            raise RuntimeError(f"stopped container missing from ps: {listed!r}")
        removed = call(rift, "rm", identifier)
        if removed.returncode != 0 or f"Removed {identifier}" not in removed.stdout:
            raise RuntimeError(f"rm failed: {removed!r}")
        after = set(runtime.iterdir()) if runtime.exists() else set()
        if after != before:
            raise RuntimeError(f"temporary state remains: {after - before}")
        print("Rift detached check passed: process, logs, stop, removal, cleanup")
        return 0
    except Exception as error:
        print(f"Rift detached check failed: {error}", file=sys.stderr)
        return 1
    finally:
        state = Path.home() / "Library/Application Support/Rift/containers" / identifier
        if state.exists():
            call(rift, "stop", identifier)
            call(rift, "rm", identifier)


if __name__ == "__main__":
    raise SystemExit(main())
