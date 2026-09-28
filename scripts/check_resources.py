#!/usr/bin/env python3
"""Check guest cgroup quotas for foreground and detached exec workloads."""

import subprocess
import sys


def run(binary: str, *arguments: str, timeout: int = 60) -> subprocess.CompletedProcess[str]:
    return subprocess.run([binary, *arguments], capture_output=True, text=True, timeout=timeout)


def require_output(result: subprocess.CompletedProcess[str], expected: str) -> None:
    if result.returncode != 0 or expected not in result.stdout:
        raise RuntimeError(f"expected {expected!r}, got exit {result.returncode}: stdout={result.stdout!r} stderr={result.stderr!r}")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_resources.py <rift>", file=sys.stderr)
        return 2
    binary = sys.argv[1]
    limits = ("--network", "none", "--cpu-limit", "1.5", "--memory-limit", "64m", "--pids-limit", "64")
    require_output(run(binary, "run", *limits, "--rm", "alpine", "echo", "RIFT_RESOURCE_LIMITS_OK"), "RIFT_RESOURCE_LIMITS_OK")
    require_output(run(binary, "run", "--network", "none", "--cpu-limit", "0.001", "--rm", "alpine", "echo", "RIFT_MIN_CPU_LIMIT_OK"), "RIFT_MIN_CPU_LIMIT_OK")

    started = run(binary, "run", "-d", *limits, "alpine", "sleep", "30")
    if started.returncode != 0:
        raise RuntimeError(f"could not start quota-limited container: stdout={started.stdout!r} stderr={started.stderr!r}")
    container_id = started.stdout.strip()
    try:
        require_output(run(binary, "exec", container_id, "echo", "RIFT_EXEC_RESOURCE_LIMITS_OK"), "RIFT_EXEC_RESOURCE_LIMITS_OK")
    finally:
        run(binary, "stop", container_id)
        run(binary, "rm", container_id)

    print("Rift cgroup CPU, memory, task, minimum CPU, and detached exec checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
