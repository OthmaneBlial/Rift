#!/usr/bin/env python3
"""Build and run a real OCI image without touching the user's Rift store."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

from benchmark import copy_cache


def call(binary: str, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=120)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_build.py <rift>", file=sys.stderr)
        return 2
    binary = str(Path(sys.argv[1]).resolve())
    source = Path.home() / "Library/Application Support/Rift"
    if not (source / "images").is_dir() or not (source / "blobs/sha256").is_dir() or not (source / "guest").is_dir():
        print("pull and run Alpine before build-check", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="rift-build-check-") as home:
        data = Path(home) / "Library/Application Support/Rift"
        copy_cache(source, data)
        env = dict(os.environ, HOME=home)
        context = Path(home) / "context"
        context.mkdir()
        (context / "Dockerfile").write_text("FROM alpine\nCOPY message /tmp/rift-build-message\n")
        (context / "message").write_text("RIFT_IMAGE_BUILD_OK\n")

        built = call(binary, env, "build", "--tag", "rift-build-check:local", str(context))
        if built.returncode != 0 or "Built " not in built.stdout:
            raise RuntimeError(f"image build failed: {built!r}")
        listed = call(binary, env, "images")
        if listed.returncode != 0 or "rift-build-check:local" not in listed.stdout:
            raise RuntimeError(f"built image was not recorded: {listed!r}")
        run = call(binary, env, "run", "--rm", "rift-build-check:local", "/bin/cat", "/tmp/rift-build-message")
        if run.returncode != 0 or run.stdout != "RIFT_IMAGE_BUILD_OK\n":
            raise RuntimeError(f"built image did not run with copied file contents: {run!r}")

        invalid_context = Path(home) / "invalid-context"
        invalid_context.mkdir()
        (invalid_context / "Dockerfile").write_text("FROM alpine\nRUN false\n")
        rejected = call(binary, env, "build", "-t", "rift-build-rejected:local", str(invalid_context))
        if rejected.returncode == 0 or "regular-file COPY instructions only" not in rejected.stderr:
            raise RuntimeError(f"unsupported Dockerfile instruction was not clearly rejected: {rejected!r}")
        listed = call(binary, env, "images")
        if listed.returncode != 0 or "rift-build-rejected:local" in listed.stdout:
            raise RuntimeError(f"failed build published an image reference: {listed!r}")

        removed = call(binary, env, "rmi", "rift-build-check:local")
        if removed.returncode != 0:
            raise RuntimeError(f"built image cleanup failed: {removed!r}")
        runtime = data / "runtime"
        if runtime.exists() and any(runtime.iterdir()):
            raise RuntimeError("image build or run left runtime staging behind")

    print("Rift build check passed: OCI image build, copied file execution, unsupported-instruction rejection, and cleanup")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
