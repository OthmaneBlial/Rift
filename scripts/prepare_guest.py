#!/usr/bin/env python3
"""Prepare verified Alpine ARM64 boot files for local VM development."""

import argparse
import gzip
import hashlib
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import urllib.request


ISO_URL = "https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-virt-3.24.2-aarch64.iso"
ISO_SHA256 = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def download_iso(path: Path) -> None:
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".alpine-iso-", delete=False) as target:
        temporary = Path(target.name)
        try:
            with urllib.request.urlopen(ISO_URL, timeout=60) as source:
                while chunk := source.read(1024 * 1024):
                    target.write(chunk)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    if sha256_file(temporary) != ISO_SHA256:
        temporary.unlink()
        raise ValueError("downloaded Alpine ISO failed SHA-256 verification")
    temporary.replace(path)


def extract(iso: Path, member: str) -> bytes:
    return subprocess.run(
        ["/usr/bin/tar", "-xOf", str(iso), member],
        check=True,
        capture_output=True,
    ).stdout


def uncompress_kernel(zboot: bytes) -> bytes:
    if len(zboot) < 64 or zboot[:2] != b"MZ" or zboot[4:8] != b"zimg":
        raise ValueError("Alpine kernel is not an EFI zboot image")
    offset, size = struct.unpack_from("<II", zboot, 8)
    compression = zboot[24:56].split(b"\0", 1)[0]
    if compression != b"gzip" or offset < 64 or size == 0 or size > len(zboot) - offset:
        raise ValueError("Alpine kernel has an unsupported or invalid zboot payload")
    image = gzip.decompress(zboot[offset : offset + size])
    if len(image) < 64 or image[56:60] != b"ARMd" or int.from_bytes(image[16:24], "little") != len(image):
        raise ValueError("decompressed kernel is not a complete ARM64 Image")
    return image


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iso", type=Path, help="reuse a local copy of the pinned Alpine ISO")
    parser.add_argument("--out", type=Path, default=Path(".zig-cache/guest"))
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    iso = args.iso or args.out / "alpine-virt-3.24.2-aarch64.iso"
    if not iso.exists() and args.iso is None:
        download_iso(iso)
    if sha256_file(iso) != ISO_SHA256:
        raise ValueError("Alpine ISO failed SHA-256 verification")

    kernel = uncompress_kernel(extract(iso, "boot/vmlinuz-virt"))
    initramfs = extract(iso, "boot/initramfs-virt")
    if not initramfs.startswith(b"\x1f\x8b"):
        raise ValueError("Alpine initramfs is not gzip-compressed")
    (args.out / "Image").write_bytes(kernel)
    (args.out / "initramfs-virt").write_bytes(initramfs)
    print(f"Prepared Alpine 3.24.2 ARM64 guest in {args.out}")
    print(f"Image sha256: {hashlib.sha256(kernel).hexdigest()}")
    print(f"initramfs sha256: {hashlib.sha256(initramfs).hexdigest()}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"prepare_guest: {error}", file=sys.stderr)
        sys.exit(1)
