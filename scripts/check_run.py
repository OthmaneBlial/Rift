#!/usr/bin/env python3
"""Local end-to-end check for the signed Rift CLI."""

from pathlib import Path
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_run.py <rift>", file=sys.stderr)
        return 2
    rift = Path(sys.argv[1])
    runtime = Path.home() / "Library/Application Support/Rift/runtime"
    before = set(runtime.iterdir()) if runtime.exists() else set()

    cases = [
        (["run", "--rm", "alpine", "/bin/echo", "RIFT_RUN_OK"], 0, "RIFT_RUN_OK"),
        (["run", "alpine", "/bin/sh", "-c", "exit 37"], 37, ""),
        (["run", "alpine", "echo", "two words", "$(touch /tmp/rift-should-not-exist)"], 0,
         "two words $(touch /tmp/rift-should-not-exist)"),
    ]
    for arguments, code, output in cases:
        result = subprocess.run([str(rift), *arguments], capture_output=True, text=True, timeout=45)
        if result.returncode != code or result.stdout.strip() != output:
            print(
                f"Rift run check failed: {arguments}\n"
                f"exit={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}",
                file=sys.stderr,
            )
            return 1
    after = set(runtime.iterdir()) if runtime.exists() else set()
    if after != before or Path("/tmp/rift-should-not-exist").exists():
        print("Rift run check failed: temporary state or injected host file remains", file=sys.stderr)
        return 1
    print("Rift run check passed: output, exit status, quoting, cleanup")
    return 0


if __name__ == "__main__":
    sys.exit(main())
