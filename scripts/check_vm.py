#!/usr/bin/env python3
"""Local integration check for the signed Zig VM bridge."""

import errno
import os
from pathlib import Path
import pty
import select
import subprocess
import sys
import time


def main() -> int:
    if len(sys.argv) not in (4, 5, 6) or (len(sys.argv) == 6 and sys.argv[4] != "--oci"):
        print("usage: check_vm.py <probe> <ARM64 Image> <initramfs> [share | --oci <pulled reference>]", file=sys.stderr)
        return 2
    probe, kernel, initramfs = map(Path, sys.argv[1:4])
    share = Path(sys.argv[4]) if len(sys.argv) == 5 else None
    oci = len(sys.argv) == 6
    if not kernel.is_file() or not initramfs.is_file():
        print("VM assets missing; run python3 scripts/prepare_guest.py", file=sys.stderr)
        return 2

    master, slave = pty.openpty()
    process = subprocess.Popen(
        [str(probe), str(kernel), str(initramfs)]
        + ([str(share)] if share else [])
        + (["--oci", sys.argv[5]] if oci else []),
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    output = bytearray()
    sent = False
    deadline = time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.25)
            if readable:
                try:
                    chunk = os.read(master, 4096)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    chunk = b""
                if not chunk:
                    break
                output.extend(chunk)
                if not sent and b"~ #" in output:
                    command = b"echo RIFT_VM_SMOKE_OK; /usr/bin/busybox uname -m; "
                    if share or oci:
                        command += (
                            b"/usr/sbin/modprobe virtiofs; "
                            b"/usr/bin/busybox mkdir -p /mnt/rift; "
                            b"/usr/bin/busybox mount -t virtiofs -o ro rift-rootfs /mnt/rift; "
                        )
                        if share:
                            command += b"/usr/bin/busybox test -s /mnt/rift/Image && echo RIFT_SHARE_OK; "
                        else:
                            command += (
                                b"/usr/bin/busybox chroot /mnt/rift /bin/echo RIFT_OCI_RUN_OK; "
                                b"echo RIFT_OCI_EXIT:$?; "
                            )
                    os.write(master, command + b"/usr/bin/busybox poweroff -f\n")
                    sent = True
            if process.poll() is not None and not readable:
                break
        result = process.poll()
        if result is None:
            try:
                result = process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
    finally:
        os.close(master)
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    lines = output.decode("utf-8", errors="replace").replace("\r", "").splitlines()
    if result != 0 or "RIFT_VM_SMOKE_OK" not in lines or "aarch64" not in lines or (
        share and "RIFT_SHARE_OK" not in lines
    ) or (oci and ("RIFT_OCI_RUN_OK" not in lines or "RIFT_OCI_EXIT:0" not in lines)):
        print(f"VM smoke failed (exit={result}):\n" + "\n".join(lines)[-4000:], file=sys.stderr)
        return 1
    if oci:
        print("VM OCI smoke passed: pulled Alpine rootfs, read-only share, chroot command, shutdown")
    else:
        print("VM smoke passed: Alpine aarch64 boot, " + ("read-only share, " if share else "") + "command, shutdown")
    return 0


if __name__ == "__main__":
    sys.exit(main())
