#!/usr/bin/env python3
"""Local end-to-end check for the signed Rift CLI."""

from pathlib import Path
import subprocess
import sys


def main() -> int:
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--network"):
        print("usage: check_run.py <rift> [--network]", file=sys.stderr)
        return 2
    rift = Path(sys.argv[1])
    network_only = len(sys.argv) == 3
    runtime = Path.home() / "Library/Application Support/Rift/runtime"
    before = set(runtime.iterdir()) if runtime.exists() else set()

    cases = [
        (["run", "alpine"], 0, ""),
        (["run", "--rm", "alpine", "/bin/echo", "RIFT_RUN_OK"], 0, "RIFT_RUN_OK"),
        (["run", "alpine", "/bin/sh", "-c", "exit 37"], 37, ""),
        (["run", "alpine", "/bin/sh", "-c", "printf '%s\\n' \"$PATH\""], 0,
         "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"),
        (["run", "alpine", "echo", "two words", "$(touch /tmp/rift-should-not-exist)"], 0,
         "two words $(touch /tmp/rift-should-not-exist)"),
    ]
    if network_only:
        cases = [(["run", "alpine", "nslookup", "example.com"], 0, "example.com")]
    for arguments, code, output in cases:
        result = subprocess.run([str(rift), *arguments], capture_output=True, text=True, timeout=45)
        matches_output = output in result.stdout if network_only else result.stdout.strip() == output
        if result.returncode != code or not matches_output:
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
    if network_only:
        print("Rift network check passed: container DNS lookup and cleanup")
    else:
        print("Rift run check passed: image defaults, environment, output, exit status, quoting, cleanup")
    return 0


if __name__ == "__main__":
    sys.exit(main())
