#!/usr/bin/env python3
"""Check guest cgroup quotas for foreground and detached exec workloads."""

import re
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

    cpu_command = "read before _ < /proc/$$/schedstat; read up < /proc/uptime; end=$((${up%%.*} + 4)); " \
        "while :; do read up < /proc/uptime; [ \"${up%%.*}\" -ge \"$end\" ] && break; done; " \
        "read after _ < /proc/$$/schedstat; echo RIFT_CPU_RUNTIME_NS=$((after - before))"
    cpu = run(binary, "run", "--network", "none", "--cpu-limit", "0.1", "--rm", "alpine", "sh", "-c", cpu_command)
    match = re.search(r"RIFT_CPU_RUNTIME_NS=(\d+)", cpu.stdout)
    if cpu.returncode != 0 or match is None or not 0 < int(match.group(1)) < 1_500_000_000:
        raise RuntimeError(f"0.1 CPU quota did not constrain a four-second workload: stdout={cpu.stdout!r} stderr={cpu.stderr!r}")

    memory = run(binary, "run", "--network", "none", "--memory-limit", "64m", "--rm", "alpine", "sh", "-c",
        "set -e; dd if=/dev/zero of=/tmp/rift-memory-pressure bs=1M count=160 >/dev/null 2>&1; echo RIFT_MEMORY_LIMIT_NOT_ENFORCED")
    if memory.returncode != 137 or "RIFT_MEMORY_LIMIT_NOT_ENFORCED" in memory.stdout:
        raise RuntimeError(f"64 MiB memory limit did not OOM-kill a 160 MiB write: stdout={memory.stdout!r} stderr={memory.stderr!r} exit={memory.returncode}")

    started = run(binary, "run", "-d", *limits, "alpine", "sleep", "30")
    if started.returncode != 0:
        raise RuntimeError(f"could not start quota-limited container: stdout={started.stdout!r} stderr={started.stderr!r}")
    container_id = started.stdout.strip()
    try:
        require_output(run(binary, "exec", container_id, "echo", "RIFT_EXEC_RESOURCE_LIMITS_OK"), "RIFT_EXEC_RESOURCE_LIMITS_OK")
    finally:
        run(binary, "stop", container_id)
        run(binary, "rm", container_id)

    print("Rift cgroup CPU and memory enforcement, task limit, minimum CPU, and detached exec checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
