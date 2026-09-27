#!/usr/bin/env python3
"""Package and verify the locally signed Apple Silicon Rift binary."""

import hashlib
import os
from pathlib import Path
import platform
import stat
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "zig-out/bin/rift"


def main() -> None:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Release packaging requires an Apple Silicon Mac")
    version_output = subprocess.run([BINARY, "version"], capture_output=True, text=True, check=True).stdout.strip()
    if not version_output.startswith("Rift "):
        raise SystemExit(f"Unexpected version output: {version_output!r}")
    version = version_output.removeprefix("Rift ")
    name = f"rift-{version}-macos-arm64"
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    archive = dist / f"{name}.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for source, mode in ((BINARY, 0o755), (ROOT / "LICENSE", 0o644), (ROOT / "README.md", 0o644)):
            entry = zipfile.ZipInfo(f"{name}/{source.name}", date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | mode) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            output.writestr(entry, source.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    hasher = hashlib.sha256()
    with archive.open("rb") as packaged:
        for chunk in iter(lambda: packaged.read(1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    (dist / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")

    with tempfile.TemporaryDirectory(prefix="rift-release-check-") as directory:
        subprocess.run(["/usr/bin/ditto", "-x", "-k", archive, directory], check=True)
        extracted = Path(directory) / name / "rift"
        if not os.access(extracted, os.X_OK):
            raise RuntimeError("Unpacked Rift binary is not executable")
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", extracted], check=True)
        result = subprocess.run([extracted, "version"], capture_output=True, text=True, check=True)
        if result.stdout.strip() != version_output:
            raise RuntimeError("Unpacked Rift binary reports a different version")
    print(f"{archive}\n{dist / 'SHA256SUMS'}\nSHA-256: {digest}")


if __name__ == "__main__":
    main()
