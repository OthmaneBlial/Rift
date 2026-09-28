#!/usr/bin/env python3
"""Build and run a real OCI image without touching the user's Rift store."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

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
RUN test "$RIFT_BUILD_MESSAGE" = "hello world"
RUN test "$(id -u)" = "65534"
RUN test "$PWD" = "/tmp"
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

        run_context = Path(home) / "run-context"
        run_context.mkdir()
        (run_context / "Dockerfile").write_text(
            "FROM alpine\nCOPY first /tmp/first\nRUN cat /tmp/first > /tmp/combined && rm /tmp/first\n"
            "COPY second /tmp/second\nRUN test ! -e /tmp/first && cat /tmp/second >> /tmp/combined\n"
        )
        (run_context / "first").write_text("RIFT_RUN_FIRST|")
        (run_context / "second").write_text("RIFT_RUN_SECOND\n")
        run_build = call(binary, env, "build", "-t", "rift-build-run:local", str(run_context))
        if run_build.returncode != 0 or "Built " not in run_build.stdout:
            raise RuntimeError(f"Dockerfile COPY/RUN sequence failed: {run_build!r}")
        run_output = call(binary, env, "run", "--rm", "rift-build-run:local", "/bin/cat", "/tmp/combined")
        if run_output.returncode != 0 or run_output.stdout != "RIFT_RUN_FIRST|RIFT_RUN_SECOND\n":
            raise RuntimeError(f"Dockerfile RUN output was not preserved in the image: {run_output!r}")
        owners = call(binary, env, "run", "--rm", "rift-build-run:local", "/bin/stat", "-c", "%u", "/bin/busybox", "/tmp/combined")
        if owners.returncode != 0 or owners.stdout != "0\n0\n":
            raise RuntimeError(f"RUN snapshot did not preserve root ownership: {owners!r}")

        stages_context = Path(home) / "stages-context"
        stages_context.mkdir()
        (stages_context / "Dockerfile").write_text(
            r'''FROM alpine AS Build
COPY payload /tmp/payload
RUN printf 'RUN_OK\n' >> /tmp/payload
ENV RIFT_BUILD_STAGE=builder
FROM alpine AS final
ENV RIFT_BUILD_STAGE=final
WORKDIR /tmp/final-stage
COPY --from=build /tmp/payload /opt/payload
COPY --from=0 /tmp/payload /opt/numeric-payload
FROM final AS output
STOPSIGNAL SIGUSR1
'''
        )
        (stages_context / "payload").write_text("RIFT_STAGE_COPY_OK|")
        stages_build = call(binary, env, "build", "-t", "rift-build-stages:local", str(stages_context))
        if stages_build.returncode != 0 or "Built " not in stages_build.stdout:
            raise RuntimeError(f"multi-stage Dockerfile build failed: {stages_build!r}")
        stages_run = call(
            binary,
            env,
            "run",
            "--rm",
            "rift-build-stages:local",
            "/bin/sh",
            "-c",
            "printf '%s|%s|' \"$RIFT_BUILD_STAGE\" \"$PWD\"; cat /opt/payload /opt/numeric-payload",
        )
        if stages_run.returncode != 0 or stages_run.stdout != (
            "final|/tmp/final-stage|RIFT_STAGE_COPY_OK|RUN_OK\nRIFT_STAGE_COPY_OK|RUN_OK\n"
        ):
            raise RuntimeError(f"multi-stage COPY, RUN, or inherited configuration failed: {stages_run!r}")

        custom_signal = call(
            binary,
            env,
            "run",
            "-d",
            "rift-build-stages:local",
            "/bin/sh",
            "-c",
            "trap 'echo RIFT_CUSTOM_STOP_SIGNAL; exit 0' USR1; echo RIFT_STOP_READY; while :; do sleep 1; done",
        )
        signal_id = custom_signal.stdout.strip()
        try:
            if custom_signal.returncode != 0 or len(signal_id) != 32:
                raise RuntimeError(f"image with STOPSIGNAL did not start: {custom_signal!r}")
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                signal_logs = call(binary, env, "logs", signal_id)
                if "RIFT_STOP_READY" in signal_logs.stdout:
                    break
                time.sleep(0.2)
            else:
                raise RuntimeError("STOPSIGNAL container did not reach running state")
            stopped = call(binary, env, "stop", signal_id)
            signal_logs = call(binary, env, "logs", signal_id)
            if stopped.returncode != 0 or "RIFT_CUSTOM_STOP_SIGNAL" not in signal_logs.stdout:
                raise RuntimeError(f"image STOPSIGNAL was not delivered: {stopped!r} {signal_logs!r}")
        finally:
            if signal_id:
                call(binary, env, "kill", signal_id)
                call(binary, env, "rm", signal_id)

        unknown_stage_context = Path(home) / "unknown-stage-context"
        unknown_stage_context.mkdir()
        (unknown_stage_context / "Dockerfile").write_text("FROM alpine\nCOPY --from=missing /file /file\n")
        unknown_stage = call(binary, env, "build", "-t", "rift-build-unknown-stage:local", str(unknown_stage_context))
        if unknown_stage.returncode == 0 or "earlier stage" not in unknown_stage.stderr:
            raise RuntimeError(f"unknown COPY --from stage was not rejected: {unknown_stage!r}")

        link_stage_context = Path(home) / "link-stage-context"
        link_stage_context.mkdir()
        (link_stage_context / "Dockerfile").write_text(
            "FROM alpine AS source\nRUN ln -s /etc/passwd /tmp/linked\nFROM alpine\n"
            "COPY --from=source /tmp/linked /tmp/linked\n"
        )
        link_stage = call(binary, env, "build", "-t", "rift-build-link-stage:local", str(link_stage_context))
        if link_stage.returncode == 0 or "symlink or special file" not in link_stage.stderr:
            raise RuntimeError(f"inter-stage COPY followed a symlink: {link_stage!r}")

        failing_context = Path(home) / "failing-context"
        failing_context.mkdir()
        (failing_context / "Dockerfile").write_text("FROM alpine\nRUN false\n")
        failed_run = call(binary, env, "build", "-t", "rift-build-failed-run:local", str(failing_context))
        if failed_run.returncode == 0 or "Dockerfile RUN command failed" not in failed_run.stderr:
            raise RuntimeError(f"failed RUN command did not fail the build: {failed_run!r}")

        listed = call(binary, env, "images")
        if (
            listed.returncode != 0
            or "rift-build-check:local" not in listed.stdout
            or "rift-build-repeat:local" not in listed.stdout
            or "rift-build-config:local" not in listed.stdout
            or "rift-build-run:local" not in listed.stdout
            or "rift-build-stages:local" not in listed.stdout
        ):
            raise RuntimeError(f"built image was not recorded: {listed!r}")
        if "rift-build-failed-run:local" in listed.stdout:
            raise RuntimeError("failed RUN command published an image reference")
        if "rift-build-unknown-stage:local" in listed.stdout:
            raise RuntimeError("unknown stage published an image reference")
        if "rift-build-link-stage:local" in listed.stdout:
            raise RuntimeError("symlink stage published an image reference")
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
        if link_rejected.returncode == 0 or "symlink or special file" not in link_rejected.stderr:
            raise RuntimeError(f"symlink inside a directory copy was not rejected: {link_rejected!r}")

        listed = call(binary, env, "images")
        if (
            listed.returncode != 0
            or "rift-build-failed-run:local" in listed.stdout
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
        removed_run = call(binary, env, "rmi", "rift-build-run:local")
        if removed_run.returncode != 0:
            raise RuntimeError(f"RUN image cleanup failed: {removed_run!r}")
        removed_stages = call(binary, env, "rmi", "rift-build-stages:local")
        if removed_stages.returncode != 0:
            raise RuntimeError(f"multi-stage image cleanup failed: {removed_stages!r}")
        runtime = data / "runtime"
        if runtime.exists() and any(runtime.iterdir()):
            raise RuntimeError("image build or run left runtime staging behind")

    print("Rift build check passed: reproducible COPY layers, ordered RUN execution, multi-stage builds, process config, failure handling, VM execution, and cleanup")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
