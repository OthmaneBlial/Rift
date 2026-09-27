#!/usr/bin/env python3
"""Exercise an image WorkingDir using real Alpine layers and a local config fixture."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def store_blob(directory: Path, value: object) -> tuple[str, int]:
    body = json.dumps(value, separators=(",", ":")).encode()
    digest = hashlib.sha256(body).hexdigest()
    (directory / digest).write_bytes(body)
    return f"sha256:{digest}", len(body)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_workdir.py <rift>", file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())
    source = Path.home() / "Library/Application Support/Rift"
    reference = "registry-1.docker.io/library/alpine:latest"
    record_name = hashlib.sha256(reference.encode()).hexdigest() + ".rift"
    if not (source / "images" / record_name).is_file():
        print("pull Alpine before run-workdir-check", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="rift-workdir-check-") as home:
        data = Path(home) / "Library/Application Support/Rift"
        for section in ("images", "blobs", "guest"):
            shutil.copytree(source / section, data / section, symlinks=True)
        record = data / "images" / record_name
        fields = record.read_text().split("\n")
        if len(fields) != 5 or fields[0] != "v1" or fields[1] != reference:
            raise RuntimeError("unexpected Alpine image record")
        blobs = data / "blobs/sha256"
        manifest = json.loads((blobs / fields[2][7:]).read_bytes())
        image_config = json.loads((blobs / manifest["config"]["digest"][7:]).read_bytes())
        image_config.setdefault("config", {})["WorkingDir"] = "/tmp"
        config_digest, config_size = store_blob(blobs, image_config)
        manifest["config"]["digest"] = config_digest
        manifest["config"]["size"] = config_size
        manifest_digest, _ = store_blob(blobs, manifest)
        record.write_text(f"v1\n{reference}\n{manifest_digest}\nlinux/arm64\n{len(manifest['layers'])}")

        env = dict(os.environ, HOME=home)
        for arguments, expected in ((["run", "alpine", "/bin/pwd"], "/tmp"), (["run", "-w", "/", "alpine", "/bin/pwd"], "/")):
            result = subprocess.run([binary, *arguments], env=env, capture_output=True, text=True, timeout=60)
            if result.returncode != 0 or result.stdout.strip() != expected:
                raise RuntimeError(f"WorkingDir check failed: {arguments}: {result!r}")
        if list((data / "runtime").iterdir()):
            raise RuntimeError("WorkingDir run left runtime staging behind")
    print("Rift WorkingDir check passed: image default and -w override")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
