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
        nested = context / "assets" / "deep dir"
        nested.mkdir(parents=True)
        (context / "Dockerfile").write_text(
            "FROM alpine\nCOPY message /tmp/rift-build-message\nCOPY message /opt/copied/\nCOPY assets/ /opt/rift-assets/\n"
        )
        (context / "message").write_text("RIFT_IMAGE_BUILD_OK\n")
        (nested / "message").write_text("RIFT_DIRECTORY_BUILD_OK\n")
        (context / "message").chmod(0o751)
        nested.chmod(0o750)
        nested_mtime = 1_700_000_000
        os.utime(nested, (nested_mtime, nested_mtime))

        built = call(binary, env, "build", "--tag", "rift-build-check:local", str(context))
        if built.returncode != 0 or "Built " not in built.stdout:
            raise RuntimeError(f"image build failed: {built!r}")
        repeated_build = call(binary, env, "build", "--tag", "rift-build-repeat:local", str(context))
        if repeated_build.returncode != 0 or "Built " not in repeated_build.stdout:
            raise RuntimeError(f"repeated image build failed: {repeated_build!r}")
        digest = built.stdout.split(" (")[0].rsplit(" ", 1)[-1]
        repeated_digest = repeated_build.stdout.split(" (")[0].rsplit(" ", 1)[-1]
        if digest != repeated_digest:
            raise RuntimeError(f"same Dockerfile produced different image digests: {digest} != {repeated_digest}")

        config_context = Path(home) / "config-context"
        config_context.mkdir()
        (config_context / "Dockerfile").write_text(
            r'''FROM alpine
ENV RIFT_BUILD_MESSAGE="hello world"
USER 65534
WORKDIR /tmp
WORKDIR /tmp/rift-build-work/
ENTRYPOINT ["/bin/sh", "-c"]
CMD ["printf '%s|%s|%s|%s\\n' \"$RIFT_BUILD_MESSAGE\" \"$(pwd)\" \"$(id -u)\" \"$(/bin/stat -c %a /tmp)\""]
'''
        )
        config_build = call(binary, env, "build", "-t", "rift-build-config:local", str(config_context))
        if config_build.returncode != 0 or "Built " not in config_build.stdout:
            raise RuntimeError(f"image config build failed: {config_build!r}")
        config_run = call(binary, env, "run", "--rm", "rift-build-config:local")
        if config_run.returncode != 0 or config_run.stdout != "hello world|/tmp/rift-build-work|65534|1777\n":
            raise RuntimeError(f"built image process configuration was not applied: {config_run!r}")

        listed = call(binary, env, "images")
        if (
            listed.returncode != 0
            or "rift-build-check:local" not in listed.stdout
            or "rift-build-repeat:local" not in listed.stdout
            or "rift-build-config:local" not in listed.stdout
        ):
            raise RuntimeError(f"built image was not recorded: {listed!r}")
        run = call(
            binary,
            env,
            "run",
            "--rm",
            "rift-build-check:local",
            "/bin/cat",
            "/tmp/rift-build-message",
            "/opt/copied/message",
            "/opt/rift-assets/deep dir/message",
        )
        if run.returncode != 0 or run.stdout != "RIFT_IMAGE_BUILD_OK\nRIFT_IMAGE_BUILD_OK\nRIFT_DIRECTORY_BUILD_OK\n":
            raise RuntimeError(f"built image did not run with copied files and directory contents: {run!r}")
        file_mode = call(binary, env, "run", "--rm", "rift-build-check:local", "/bin/stat", "-c", "%a", "/tmp/rift-build-message")
        directory_mode = call(binary, env, "run", "--rm", "rift-build-check:local", "/bin/stat", "-c", "%a", "/opt/rift-assets/deep dir")
        if file_mode.returncode != 0 or file_mode.stdout.strip() != "751":
            raise RuntimeError(f"file COPY did not preserve its mode: {file_mode!r}")
        if directory_mode.returncode != 0 or directory_mode.stdout.strip() != "750":
            raise RuntimeError(f"directory COPY did not preserve nested directory mode: {directory_mode!r}")
        directory_mtime = call(binary, env, "run", "--rm", "rift-build-check:local", "/bin/stat", "-c", "%Y", "/opt/rift-assets/deep dir")
        if directory_mtime.returncode != 0 or directory_mtime.stdout.strip() != str(nested_mtime):
            raise RuntimeError(f"directory COPY did not preserve nested directory mtime: {directory_mtime!r}")

        invalid_context = Path(home) / "invalid-context"
        invalid_context.mkdir()
        (invalid_context / "Dockerfile").write_text("FROM alpine\nRUN false\n")
        rejected = call(binary, env, "build", "-t", "rift-build-rejected:local", str(invalid_context))
        if rejected.returncode == 0 or "supported build instructions are one FROM" not in rejected.stderr:
            raise RuntimeError(f"unsupported Dockerfile instruction was not clearly rejected: {rejected!r}")

        ignore_context = Path(home) / "ignore-context"
        ignore_context.mkdir()
        (ignore_context / "Dockerfile").write_text("FROM alpine\nCOPY hidden /hidden\n")
        (ignore_context / ".dockerignore").write_text("hidden\n")
        ignore_rejected = call(binary, env, "build", "-t", "rift-build-ignore-rejected:local", str(ignore_context))
        if ignore_rejected.returncode == 0 or ".dockerignore files are not supported" not in ignore_rejected.stderr:
            raise RuntimeError(f".dockerignore was not clearly rejected: {ignore_rejected!r}")

        link_context = Path(home) / "link-context"
        link_context.mkdir()
        source_dir = link_context / "source"
        source_dir.mkdir()
        (source_dir / "inside").write_text("inside")
        outside = Path(home) / "outside"
        outside.write_text("outside")
        (source_dir / "link").symlink_to(outside)
        (link_context / "Dockerfile").write_text("FROM alpine\nCOPY source /unsafe\n")
        link_rejected = call(binary, env, "build", "-t", "rift-build-link-rejected:local", str(link_context))
        if link_rejected.returncode == 0 or "links and special files are unsupported" not in link_rejected.stderr:
            raise RuntimeError(f"symlink inside a directory copy was not rejected: {link_rejected!r}")

        listed = call(binary, env, "images")
        if (
            listed.returncode != 0
            or "rift-build-rejected:local" in listed.stdout
            or "rift-build-ignore-rejected:local" in listed.stdout
            or "rift-build-link-rejected:local" in listed.stdout
        ):
            raise RuntimeError(f"failed build published an image reference: {listed!r}")

        removed = call(binary, env, "rmi", "rift-build-check:local")
        if removed.returncode != 0:
            raise RuntimeError(f"built image cleanup failed: {removed!r}")
        removed_repeat = call(binary, env, "rmi", "rift-build-repeat:local")
        if removed_repeat.returncode != 0:
            raise RuntimeError(f"repeated image cleanup failed: {removed_repeat!r}")
        removed_config = call(binary, env, "rmi", "rift-build-config:local")
        if removed_config.returncode != 0:
            raise RuntimeError(f"configured image cleanup failed: {removed_config!r}")
        runtime = data / "runtime"
        if runtime.exists() and any(runtime.iterdir()):
            raise RuntimeError("image build or run left runtime staging behind")

    print("Rift build check passed: reproducible OCI layers, COPY and process config, VM execution, safe rejection, and cleanup")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
