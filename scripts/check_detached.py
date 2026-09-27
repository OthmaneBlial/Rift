#!/usr/bin/env python3
"""Check the detached Rift process, logs, stop, and removal locally."""

import re
import subprocess
import sys
import time
from pathlib import Path


def call(rift: str, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([rift, *args], capture_output=True, text=True, timeout=30)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_detached.py <rift>", file=sys.stderr)
        return 2
    rift = sys.argv[1]
    runtime = Path.home() / "Library/Application Support/Rift/runtime"
    before = set(runtime.iterdir()) if runtime.exists() else set()
    started = call(
        rift,
        "run",
        "-d",
        "-e",
        "RIFT_CHECK=RIFT_DETACHED_OK",
        "alpine",
        "/bin/sh",
        "-c",
        'trap "echo RIFT_TERM_RECEIVED; exit 0" TERM; echo "$RIFT_CHECK"; while :; do sleep 1; done',
    )
    identifier = started.stdout.strip()
    if started.returncode != 0 or re.fullmatch(r"[0-9a-f]{32}", identifier) is None:
        print(f"Rift detached check failed to start: {started!r}", file=sys.stderr)
        return 1
    forced_id = ""
    killed_id = ""
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
        logged = call(rift, "logs", identifier)
        if "RIFT_TERM_RECEIVED" not in logged.stdout:
            raise RuntimeError(f"stop did not deliver SIGTERM to the container process: {logged!r}")
        listed = call(rift, "ps")
        if f"{identifier}  alpine  stopped" not in listed.stdout:
            raise RuntimeError(f"stopped container missing from ps: {listed!r}")
        removed = call(rift, "rm", identifier)
        if removed.returncode != 0 or f"Removed {identifier}" not in removed.stdout:
            raise RuntimeError(f"rm failed: {removed!r}")

        unresponsive = call(rift, "run", "-d", "alpine", "/bin/sh", "-c", 'trap "" TERM; echo RIFT_FORCE_STOP_READY; sleep 60')
        forced_id = unresponsive.stdout.strip()
        if unresponsive.returncode != 0 or re.fullmatch(r"[0-9a-f]{32}", forced_id) is None:
            raise RuntimeError(f"unresponsive container did not start: {unresponsive!r}")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            logged = call(rift, "logs", forced_id)
            if "RIFT_FORCE_STOP_READY" in logged.stdout:
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("unresponsive container never reached running state")
        force_started = time.monotonic()
        forced = call(rift, "stop", forced_id)
        if forced.returncode != 0 or f"Stopped {forced_id}" not in forced.stdout or time.monotonic() - force_started < 8:
            raise RuntimeError(f"stop did not force shutdown after its grace period: {forced!r}")
        forced_listed = call(rift, "ps")
        if f"{forced_id}  alpine  stopped" not in forced_listed.stdout:
            raise RuntimeError(f"forced container missing from ps: {forced_listed!r}")
        forced_removed = call(rift, "rm", forced_id)
        if forced_removed.returncode != 0:
            raise RuntimeError(f"forced container state was not removed: {forced_removed!r}")

        unresponsive = call(rift, "run", "-d", "alpine", "/bin/sh", "-c", 'trap "" TERM; echo RIFT_KILL_READY; sleep 60')
        killed_id = unresponsive.stdout.strip()
        if unresponsive.returncode != 0 or re.fullmatch(r"[0-9a-f]{32}", killed_id) is None:
            raise RuntimeError(f"kill target did not start: {unresponsive!r}")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            logged = call(rift, "logs", killed_id)
            if "RIFT_KILL_READY" in logged.stdout:
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("kill target never reached running state")
        kill_started = time.monotonic()
        killed = call(rift, "kill", killed_id)
        if killed.returncode != 0 or f"Killed {killed_id}" not in killed.stdout or time.monotonic() - kill_started >= 8:
            raise RuntimeError(f"kill did not stop the VM immediately: {killed!r}")
        killed_listed = call(rift, "ps")
        if f"{killed_id}  alpine  killed" not in killed_listed.stdout:
            raise RuntimeError(f"killed container missing from ps: {killed_listed!r}")
        killed_removed = call(rift, "rm", killed_id)
        if killed_removed.returncode != 0:
            raise RuntimeError(f"killed container state was not removed: {killed_removed!r}")
        after = set(runtime.iterdir()) if runtime.exists() else set()
        if after != before:
            raise RuntimeError(f"temporary state remains: {after - before}")
        print("Rift detached check passed: process, logs, graceful stop, forced stop, kill, removal, cleanup")
        return 0
    except Exception as error:
        print(f"Rift detached check failed: {error}", file=sys.stderr)
        return 1
    finally:
        state = Path.home() / "Library/Application Support/Rift/containers" / identifier
        if state.exists():
            call(rift, "stop", identifier)
            call(rift, "rm", identifier)
        if forced_id:
            forced_state = Path.home() / "Library/Application Support/Rift/containers" / forced_id
            if forced_state.exists():
                call(rift, "stop", forced_id)
                call(rift, "rm", forced_id)
        if killed_id:
            killed_state = Path.home() / "Library/Application Support/Rift/containers" / killed_id
            if killed_state.exists():
                call(rift, "kill", killed_id)
                call(rift, "rm", killed_id)


if __name__ == "__main__":
    raise SystemExit(main())
