#!/usr/bin/env python3
"""Check run and detached run from an empty HOME without Docker."""

import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


def call(binary: str, env: dict[str, str], *args: str, timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=timeout)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_auto_pull.py <rift>", file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix="rift-auto-pull-check-") as home:
        env = dict(os.environ, HOME=home)
        initial = call(binary, env, "run", "alpine", "/bin/echo", "RIFT_AUTO_PULL_OK", timeout=180)
        if initial.returncode != 0 or "RIFT_AUTO_PULL_OK" not in initial.stdout or "pulling alpine" not in initial.stderr:
            raise RuntimeError(f"fresh run failed: {initial!r}")

        data = Path(home) / "Library/Application Support/Rift"
        if not (data / "guest/Image").is_file() or not list((data / "images").glob("*.rift")):
            raise RuntimeError("fresh run did not install the guest and image metadata")
        for record in (data / "images").glob("*.rift"):
            record.unlink()

        started = call(binary, env, "run", "-d", "alpine", "/bin/sh", "-c", "echo RIFT_DETACHED_READY; sleep 60", timeout=120)
        identifier = started.stdout.strip()
        if started.returncode != 0 or re.fullmatch(r"[0-9a-f]{32}", identifier) is None or "pulling alpine" not in started.stderr:
            raise RuntimeError(f"fresh detached run failed: {started!r}")
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                logs = call(binary, env, "logs", identifier)
                if logs.returncode == 0 and "RIFT_DETACHED_READY" in logs.stdout:
                    break
                time.sleep(0.2)
            else:
                raise RuntimeError(f"detached run never became ready: {call(binary, env, 'ps')!r}")
        finally:
            stopped = call(binary, env, "stop", identifier)
            removed = call(binary, env, "rm", identifier)
            if stopped.returncode != 0 or removed.returncode != 0:
                raise RuntimeError(f"detached cleanup failed: {stopped!r} {removed!r}")

        if list((data / "runtime").iterdir()) or list((data / "containers").iterdir()):
            raise RuntimeError("run left runtime or container state behind")
    print("Rift auto-pull check passed: fresh foreground and detached runs, clean stdout, cleanup")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
