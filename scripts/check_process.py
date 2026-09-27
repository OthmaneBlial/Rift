#!/usr/bin/env python3
"""Exercise image WorkingDir and User using real Alpine layers and a local config fixture."""

import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile


def store_blob(directory: Path, value: object) -> tuple[str, int]:
    body = json.dumps(value, separators=(",", ":")).encode()
    digest = hashlib.sha256(body).hexdigest()
    (directory / digest).write_bytes(body)
    return f"sha256:{digest}", len(body)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_process.py <rift>", file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())
    source = Path.home() / "Library/Application Support/Rift"
    reference = "registry-1.docker.io/library/alpine:latest"
    record_name = hashlib.sha256(reference.encode()).hexdigest() + ".rift"
    if not (source / "images" / record_name).is_file():
        print("pull Alpine before run-process-check", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="rift-process-check-") as home:
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

        def select_user(user: str) -> None:
            image_config.setdefault("config", {})["WorkingDir"] = "/tmp"
            image_config["config"]["User"] = user
            config_digest, config_size = store_blob(blobs, image_config)
            manifest["config"]["digest"] = config_digest
            manifest["config"]["size"] = config_size
            manifest_digest, _ = store_blob(blobs, manifest)
            record.write_text(f"v1\n{reference}\n{manifest_digest}\nlinux/arm64\n{len(manifest['layers'])}")

        env = dict(os.environ, HOME=home)
        select_user("1000:1000")
        cases = (
            (["run", "alpine", "/bin/pwd"], "/tmp"),
            (["run", "-w", "/", "alpine", "/bin/pwd"], "/"),
            (["run", "alpine", "/bin/busybox", "id", "-u"], "1000"),
            (["run", "alpine", "/bin/busybox", "id", "-g"], "1000"),
        )
        for arguments, expected in cases:
            result = subprocess.run([binary, *arguments], env=env, capture_output=True, text=True, timeout=60)
            if result.returncode != 0 or result.stdout.strip() != expected:
                raise RuntimeError(f"process setting check failed: {arguments}: {result!r}")
        select_user("nobody:nobody")
        named = subprocess.run([binary, "run", "alpine", "/bin/busybox", "id", "-u"], env=env, capture_output=True, text=True, timeout=60)
        if named.returncode != 0 or named.stdout.strip() != "65534":
            raise RuntimeError(f"named image user check failed: {named!r}")
        for invalid in ("missing-user", "4294967295"):
            select_user(invalid)
            rejected = subprocess.run([binary, "run", "alpine", "/bin/busybox", "id", "-u"], env=env, capture_output=True, text=True, timeout=60)
            if rejected.returncode != 125 or "user or group was not found" not in rejected.stdout:
                raise RuntimeError(f"invalid image user was not rejected: {invalid}: {rejected!r}")
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w") as layer:
            layer.addfile(tarfile.TarInfo("bin/.wh.sh"))
        body = archive.getvalue()
        digest = hashlib.sha256(body).hexdigest()
        (blobs / digest).write_bytes(body)
        manifest["layers"].append({"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": f"sha256:{digest}", "size": len(body)})
        image_config["rootfs"]["diff_ids"].append(f"sha256:{digest}")
        select_user("1000:1000")
        shell_free = subprocess.run([binary, "run", "alpine", "/bin/pwd"], env=env, capture_output=True, text=True, timeout=60)
        if shell_free.returncode != 0 or shell_free.stdout.strip() != "/tmp":
            raise RuntimeError(f"shell-free working directory check failed: {shell_free!r}")
        removed_shell = subprocess.run([binary, "run", "alpine", "/bin/sh", "-c", "true"], env=env, capture_output=True, text=True, timeout=60)
        if removed_shell.returncode != 125 or "rift-exec: exec:" not in removed_shell.stdout:
            raise RuntimeError(f"fixture still contains a working shell: {removed_shell!r}")
        if list((data / "runtime").iterdir()):
            raise RuntimeError("process settings run left runtime staging behind")
    print("Rift process settings check passed: working directory, numeric and named users, shell-free image")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
