#!/usr/bin/env python3
"""Check detached exec argument, environment, filesystem, namespace, and exit behavior."""

import os
import re
import select
import shutil
import subprocess
import sys
import tempfile
import time


def call(rift: str, *args: str, timeout: int = 90) -> subprocess.CompletedProcess[str]:
    return subprocess.run([rift, *args], capture_output=True, text=True, timeout=timeout)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_exec.py <rift>", file=sys.stderr)
        return 2
    rift = sys.argv[1]
    volume_root = tempfile.mkdtemp(prefix="rift-exec-volume-")
    shell = (
        'readlink /proc/self/ns/pid > /tmp/rift-main-ns; '
        'echo RIFT_EXEC_READY; '
        'trap "echo RIFT_EXEC_TERM; exit 0" TERM; '
        'while :; do sleep 1; done'
    )
    identifier = ""
    try:
        started = call(
            rift,
            "run",
            "-d",
            "-e",
            "RIFT_EXEC_ENV=from-run",
            "-w",
            "/tmp",
            "-v",
            f"{volume_root}:/host-data:rw",
            "alpine",
            "/bin/sh",
            "-c",
            shell,
        )
        identifier = started.stdout.strip()
        if started.returncode != 0 or re.fullmatch(r"[0-9a-f]{32}", identifier) is None:
            raise RuntimeError(f"container failed to start: {started!r}")
        early = call(rift, "exec", identifier, "/bin/echo", "RIFT_EXEC_EARLY")
        if early.returncode != 0 or early.stdout != "RIFT_EXEC_EARLY\n":
            raise RuntimeError(f"exec failed immediately after detached start: {early!r}")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            listed = call(rift, "ps")
            logs = call(rift, "logs", identifier)
            if f"{identifier}  alpine  running" in listed.stdout and "RIFT_EXEC_READY" in logs.stdout:
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("container did not become ready for exec")

        script = (
            'printf "%s|%s\\n" "$RIFT_EXEC_ENV" "$PWD"; '
            'readlink /proc/self/ns/pid; '
            'printf "<%s>\\n" "$@"; '
            'printf persistent > /tmp/rift-exec-file; '
            'printf volume > /host-data/rift-exec-file'
        )
        executed = call(rift, "exec", identifier, "/bin/sh", "-c", script, "rift-exec", "a b", "", "a'b")
        if executed.returncode != 0:
            raise RuntimeError(f"exec command failed: {executed!r}")
        lines = executed.stdout.splitlines()
        if len(lines) < 5 or lines[0] != "from-run|/tmp":
            raise RuntimeError(f"exec did not inherit the container environment and working directory: {executed!r}")
        if re.fullmatch(r"pid:\[\d+\]", lines[1]) is None:
            raise RuntimeError(f"exec did not report a PID namespace: {executed!r}")
        namespace = call(rift, "exec", identifier, "/bin/cat", "/tmp/rift-main-ns")
        if namespace.returncode != 0 or namespace.stdout.strip() != lines[1]:
            raise RuntimeError(f"exec did not share the container PID namespace: {namespace!r}")
        if lines[2:5] != ["<a b>", "<>", "<a'b>"]:
            raise RuntimeError(f"exec changed command argument boundaries: {executed!r}")

        streamed = subprocess.Popen(
            [
                rift,
                "exec",
                identifier,
                "/bin/sh",
                "-c",
                "printf 'RIFT_EXEC_STREAM_EARLY\\n' >&2; sleep 4; printf 'RIFT_EXEC_STREAM_LATE\\n'",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            ready, _, _ = select.select([streamed.stdout], [], [], 3)
            if not ready:
                raise RuntimeError("exec output was not forwarded before the command exited")
            early_output = os.read(streamed.stdout.fileno(), 128)
            if not early_output.startswith(b"RIFT_EXEC_STREAM_EARLY\n") or streamed.poll() is not None:
                raise RuntimeError(f"exec did not stream live output: {early_output!r}")
            late_output, _ = streamed.communicate(timeout=15)
            if streamed.returncode != 0 or b"RIFT_EXEC_STREAM_LATE\n" not in late_output:
                raise RuntimeError(f"streamed exec did not finish cleanly: {streamed.returncode}, {late_output!r}")
        finally:
            if streamed.poll() is None:
                streamed.terminate()
                streamed.communicate(timeout=5)

        persisted = call(rift, "exec", identifier, "/bin/cat", "/tmp/rift-exec-file")
        if persisted.returncode != 0 or persisted.stdout != "persistent":
            raise RuntimeError(f"exec did not share the container filesystem: {persisted!r}")
        with open(f"{volume_root}/rift-exec-file", encoding="utf-8") as file:
            if file.read() != "volume":
                raise RuntimeError("exec did not retain access to the mounted host directory")
        nonzero = call(rift, "exec", identifier, "/bin/sh", "-c", "exit 37")
        if nonzero.returncode != 37:
            raise RuntimeError(f"exec did not return the command exit status: {nonzero!r}")
        still_running = call(rift, "ps")
        if f"{identifier}  alpine  running" not in still_running.stdout:
            raise RuntimeError("a completed exec command stopped the container")

        stopped = call(rift, "stop", identifier)
        if stopped.returncode != 0:
            raise RuntimeError(f"container stop failed after exec: {stopped!r}")
        if "RIFT_EXEC_TERM" not in call(rift, "logs", identifier).stdout:
            raise RuntimeError("container stop did not reach the main workload")
        removed = call(rift, "rm", identifier)
        if removed.returncode != 0:
            raise RuntimeError(f"container removal failed after exec: {removed!r}")
        print("Rift exec check passed: streaming output, arguments, environment, working directory, PID namespace, filesystem, exit status, lifecycle")
        return 0
    except Exception as error:
        print(f"Rift exec check failed: {error}", file=sys.stderr)
        return 1
    finally:
        if identifier and re.fullmatch(r"[0-9a-f]{32}", identifier):
            state = call(rift, "inspect", identifier)
            if state.returncode == 0 and "State: running" in state.stdout:
                call(rift, "stop", identifier)
            state = call(rift, "inspect", identifier)
            if state.returncode == 0 and "State: running" not in state.stdout:
                call(rift, "rm", identifier)
        shutil.rmtree(volume_root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
