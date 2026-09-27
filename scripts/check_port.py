#!/usr/bin/env python3
"""Check localhost TCP forwarding through a short-lived Alpine guest."""

import socket
import subprocess
import sys
import time
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_port.py <rift>", file=sys.stderr)
        return 2
    runtime = Path.home() / "Library/Application Support/Rift/runtime"
    before = set(runtime.iterdir()) if runtime.exists() else set()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        host_port = reservation.getsockname()[1]

    command = (
        'printf "HTTP/1.1 200 OK\\r\\nContent-Length: 12\\r\\nConnection: close\\r\\n'
        '\\r\\nRIFT_PORT_OK" | busybox timeout 10 nc -l -p 8080; true'
    )
    process = subprocess.Popen(
        [sys.argv[1], "run", "-p", f"{host_port}:8080", "alpine", "/bin/sh", "-c", command],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        deadline = time.monotonic() + 45
        response = b""
        while time.monotonic() < deadline and process.poll() is None:
            try:
                with socket.create_connection(("127.0.0.1", host_port), timeout=1) as client:
                    client.settimeout(20)
                    client.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
                    while b"RIFT_PORT_OK" not in response:
                        chunk = client.recv(4096)
                        if not chunk:
                            break
                        response += chunk
                    break
            except (ConnectionRefusedError, TimeoutError, OSError):
                time.sleep(0.2)
        stdout, stderr = process.communicate(timeout=20)
        after = set(runtime.iterdir()) if runtime.exists() else set()
        if process.returncode != 0 or b"RIFT_PORT_OK" not in response or after != before:
            print(
                f"Rift port check failed: exit={process.returncode}, response={response!r}, "
                f"stdout={stdout!r}, stderr={stderr!r}, temporary_dirs={after - before}",
                file=sys.stderr,
            )
            return 1
        print("Rift port check passed: localhost TCP forwarding and cleanup")
        return 0
    finally:
        if process.poll() is None:
            process.terminate()
            process.communicate(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
