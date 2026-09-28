#!/usr/bin/env python3
"""Check detached exec input/output, arguments, environment, filesystem, namespace, and exit behavior."""

import fcntl
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import tempfile
import time


def call(rift: str, *args: str, timeout: int = 90) -> subprocess.CompletedProcess[str]:
    return subprocess.run([rift, *args], capture_output=True, text=True, timeout=timeout)


def read_line(stream, timeout: float) -> bytes:
    deadline = time.monotonic() + timeout
    line = bytearray()
    while time.monotonic() < deadline:
        ready, _, _ = select.select([stream], [], [], min(0.1, deadline - time.monotonic()))
        if not ready:
            continue
        byte = os.read(stream.fileno(), 1)
        if not byte:
            break
        if byte == b"\n":
            return bytes(line).rstrip(b"\r")
        line.extend(byte)
    raise RuntimeError(f"timed out waiting for exec output line: {bytes(line)!r}")


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
    profile_identifier = ""
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

        interactive = subprocess.Popen(
            [
                rift,
                "exec",
                "-i",
                identifier,
                "/bin/sh",
                "-c",
                "IFS= read -r line; printf 'RIFT_EXEC_INPUT:%s\\n' \"$line\"; sleep 3",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            interactive.stdin.write(b"RIFT_EXEC_INPUT_LIVE\n")
            interactive.stdin.flush()
            ready, _, _ = select.select([interactive.stdout], [], [], 3)
            if not ready:
                raise RuntimeError("exec did not forward stdin before stdin reached EOF")
            early_output = os.read(interactive.stdout.fileno(), 128)
            if not early_output.startswith(b"RIFT_EXEC_INPUT:RIFT_EXEC_INPUT_LIVE\n") or interactive.poll() is not None:
                raise RuntimeError(f"exec did not stream stdin while the command was running: {early_output!r}")
            output, _ = interactive.communicate(timeout=15)
            if interactive.returncode != 0 or b"RIFT_EXEC_INPUT_LIVE" not in early_output + output:
                raise RuntimeError(f"interactive exec did not complete: {interactive.returncode}, {output!r}")
        finally:
            if interactive.poll() is None:
                interactive.terminate()
                interactive.communicate(timeout=5)

        piped = subprocess.run(
            [rift, "exec", "-i", identifier, "/bin/cat"],
            input="RIFT_EXEC_INPUT_EOF\n",
            capture_output=True,
            text=True,
            timeout=15,
        )
        if piped.returncode != 0 or piped.stdout != "RIFT_EXEC_INPUT_EOF\n":
            raise RuntimeError(f"exec did not forward stdin data and EOF: {piped!r}")

        terminal_master, terminal_slave = pty.openpty()
        fcntl.ioctl(terminal_slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        original_terminal = termios.tcgetattr(terminal_slave)
        terminal = subprocess.Popen(
            [
                rift,
                "exec",
                "-it",
                identifier,
                "/bin/sh",
                "-c",
                "test -t 0 && test -t 1 && test -t 2 || exit 90; trap 'printf RIFT_TTY_SIGNAL_INT\\n; exit 0' INT; printf 'RIFT_TTY_READY\\n'; stty size; IFS= read -r line; printf 'RIFT_TTY_INPUT:%s\\n' \"$line\"; stty size; while :; do sleep 1; done",
            ],
            stdin=terminal_slave,
            stdout=terminal_slave,
            stderr=terminal_slave,
        )
        terminal_output = bytearray()

        def read_terminal_until(marker: bytes, timeout: float) -> None:
            deadline = time.monotonic() + timeout
            while marker not in terminal_output and time.monotonic() < deadline:
                ready, _, _ = select.select([terminal_master], [], [], min(0.1, deadline - time.monotonic()))
                if ready:
                    terminal_output.extend(os.read(terminal_master, 4096))
            if marker not in terminal_output:
                raise RuntimeError(f"TTY exec did not print {marker!r}: {bytes(terminal_output)!r}")

        try:
            read_terminal_until(b"RIFT_TTY_READY", 30)
            read_terminal_until(b"40 120", 5)
            fcntl.ioctl(terminal_slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 140, 0, 0))
            os.kill(terminal.pid, signal.SIGWINCH)
            time.sleep(0.2)
            os.write(terminal_master, b"RIFT_TTY_INPUT_LIVE\n")
            read_terminal_until(b"RIFT_TTY_INPUT:RIFT_TTY_INPUT_LIVE", 10)
            read_terminal_until(b"50 140", 5)
            os.write(terminal_master, b"\x03")
            read_terminal_until(b"RIFT_TTY_SIGNAL_INT", 10)
            if terminal.wait(timeout=10) != 0:
                raise RuntimeError(f"TTY exec failed: {terminal.returncode}, {bytes(terminal_output)!r}")
            if termios.tcgetattr(terminal_slave) != original_terminal:
                raise RuntimeError(f"TTY exec did not restore the host terminal settings: {original_terminal!r} != {termios.tcgetattr(terminal_slave)!r}")
        finally:
            if terminal.poll() is None:
                terminal.terminate()
                terminal.wait(timeout=5)
            os.close(terminal_slave)
            os.close(terminal_master)

        signalled = subprocess.Popen(
            [
                rift,
                "exec",
                "-i",
                identifier,
                "/bin/sh",
                "-c",
                "trap 'printf RIFT_EXEC_SIGNAL_TERM\\n; exit 0' TERM; IFS= read -r line || printf 'RIFT_EXEC_EOF_READY\\n'; while :; do sleep 1; done",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            signalled.stdin.close()
            signalled.stdin = None
            if read_line(signalled.stdout, 30) != b"RIFT_EXEC_EOF_READY":
                raise RuntimeError("signal-test exec did not observe stdin EOF")
            os.kill(signalled.pid, signal.SIGTERM)
            remaining_output, remaining_error = signalled.communicate(timeout=15)
            if signalled.returncode != 128 + signal.SIGTERM or b"RIFT_EXEC_SIGNAL_TERM" not in remaining_output:
                raise RuntimeError(f"exec did not forward SIGTERM after stdin EOF: {signalled.returncode}, {remaining_output!r}, {remaining_error!r}")
        finally:
            if signalled.poll() is None:
                signalled.kill()
                signalled.communicate(timeout=5)

        escalated = subprocess.Popen(
            [
                rift,
                "exec",
                "-i",
                identifier,
                "/bin/sh",
                "-c",
                "trap 'printf \"RIFT_EXEC_TERM_SEEN\\n\"; trap \"\" TERM' TERM; IFS= read -r line || printf 'RIFT_EXEC_EOF_READY\\n'; while :; do :; done",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            escalated.stdin.close()
            escalated.stdin = None
            if read_line(escalated.stdout, 30) != b"RIFT_EXEC_EOF_READY":
                raise RuntimeError("signal-escalation exec did not observe stdin EOF")
            os.kill(escalated.pid, signal.SIGTERM)
            term_seen = read_line(escalated.stdout, 10)
            if term_seen != b"RIFT_EXEC_TERM_SEEN":
                raise RuntimeError(f"exec did not forward the first cancellation signal: {term_seen!r}, status={escalated.poll()}")
            os.kill(escalated.pid, signal.SIGTERM)
            escalated.communicate(timeout=15)
            if escalated.returncode != 137:
                raise RuntimeError(f"exec did not force-stop after a second cancellation signal: {escalated.returncode}")
        finally:
            if escalated.poll() is None:
                escalated.kill()
                escalated.communicate(timeout=5)

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
        restricted = call(
            rift,
            "run",
            "-d",
            "--cap-profile",
            "none",
            "alpine",
            "/bin/sh",
            "-c",
            "echo RIFT_CAP_PROFILE_READY; exec sleep 60",
        )
        profile_identifier = restricted.stdout.strip()
        if restricted.returncode != 0 or re.fullmatch(r"[0-9a-f]{32}", profile_identifier) is None:
            raise RuntimeError(f"none-profile container failed to start: {restricted!r}")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            logs = call(rift, "logs", profile_identifier)
            if logs.returncode == 0 and "RIFT_CAP_PROFILE_READY" in logs.stdout:
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("none-profile container did not become ready")
        profile_exec = call(
            rift,
            "exec",
            profile_identifier,
            "/bin/busybox",
            "grep",
            "-q",
            "^CapEff:[[:space:]]*0000000000000000$",
            "/proc/self/status",
        )
        if profile_exec.returncode != 0:
            raise RuntimeError(f"rift exec did not inherit the none capability profile: {profile_exec!r}")
        if call(rift, "stop", profile_identifier).returncode != 0 or call(rift, "rm", profile_identifier).returncode != 0:
            raise RuntimeError("could not clean up none-profile container")
        profile_identifier = ""
        print("Rift exec check passed: streaming input/output, TTY, resize, terminal restore, signal forwarding, arguments, environment, working directory, PID namespace, filesystem, capability profile, exit status, lifecycle")
        return 0
    except Exception as error:
        print(f"Rift exec check failed: {error}", file=sys.stderr)
        return 1
    finally:
        for cleanup_identifier in (profile_identifier, identifier):
            if not cleanup_identifier or re.fullmatch(r"[0-9a-f]{32}", cleanup_identifier) is None:
                continue
            state = call(rift, "inspect", cleanup_identifier)
            if state.returncode == 0 and "State: running" in state.stdout:
                call(rift, "stop", cleanup_identifier)
            state = call(rift, "inspect", cleanup_identifier)
            if state.returncode == 0 and "State: running" not in state.stdout:
                call(rift, "rm", cleanup_identifier)
        shutil.rmtree(volume_root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
