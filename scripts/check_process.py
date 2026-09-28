#!/usr/bin/env python3
"""Exercise image WorkingDir and User using real Alpine layers and a local config fixture."""

import base64
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

        def append_layer(body: bytes) -> None:
            digest = hashlib.sha256(body).hexdigest()
            (blobs / digest).write_bytes(body)
            manifest["layers"].append({"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": f"sha256:{digest}", "size": len(body)})
            image_config["rootfs"]["diff_ids"].append(f"sha256:{digest}")

        env = dict(os.environ, HOME=home)
        select_user("0:0")
        probe_source = Path(home) / "xattr_probe.c"
        probe = Path(home) / "rift-xattr-probe"
        probe_source.write_text(r'''#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/xattr.h>

static int matches(const char *path, const char *name, const unsigned char *expected, size_t size) {
    unsigned char actual[256];
    ssize_t length = getxattr(path, name, actual, sizeof(actual));
    return length == (ssize_t)size && memcmp(actual, expected, size) == 0;
}

int main(void) {
    static const unsigned char binary[] = { 'A', 0, 0xff };
    static const unsigned char capability[] = { 1, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    static const unsigned char empty[] = "";
    if (!matches("/opt/rift-xattrs/payload", "user.rift.inherited", (const unsigned char *)"global", 6)) return 11;
    if (!matches("/opt/rift-xattrs/payload", "user.rift.override", (const unsigned char *)"local", 5)) return 12;
    if (!matches("/opt/rift-xattrs/payload", "user.rift.binary", binary, sizeof(binary))) return 13;
    if (!matches("/opt/rift-xattrs/payload", "user.rift:encoded", (const unsigned char *)"decoded", 7)) return 14;
    if (!matches("/opt/rift-xattrs/payload", "user.rift.empty", empty, 0)) return 15;
    if (!matches("/opt/rift-xattrs/payload", "security.capability", capability, sizeof(capability))) return 16;
    if (!matches("/opt/rift-xattrs", "user.rift.directory", (const unsigned char *)"dir-value", 9)) return 17;
    if (!matches("/opt/rift-xattrs/payload", "user.rift.literal%25", (const unsigned char *)"percent", 7)) return 18;
    puts("RIFT_XATTR_OK");
    return 0;
}
''')
        subprocess.run(["zig", "cc", "-target", "aarch64-linux-musl", "-static", "-Os", str(probe_source), "-o", str(probe)], check=True)
        global_xattrs = {
            "SCHILY.xattr.user.rift.inherited": "global",
            "SCHILY.xattr.user.rift.override": "global",
        }
        payload_xattrs = {
            "SCHILY.xattr.user.rift.override": "local",
            "SCHILY.xattr.user.rift.binary": b"A\x00\xff".decode("utf-8", "surrogateescape"),
            "SCHILY.xattr.user.rift.literal%25": "percent",
            "LIBARCHIVE.xattr.user.rift%3Aencoded": base64.b64encode(b"decoded").decode("ascii"),
            "SCHILY.xattr.user.rift.empty": "",
            "security.capability": (bytes([1, 0, 0, 2]) + bytes(16)).decode("latin-1"),
        }
        xattr_archive = io.BytesIO()
        with tarfile.open(fileobj=xattr_archive, mode="w", format=tarfile.PAX_FORMAT, pax_headers=global_xattrs, encoding="latin-1") as layer:
            directory = tarfile.TarInfo("opt/rift-xattrs")
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o755
            directory.pax_headers = {"SCHILY.xattr.user.rift.directory": "dir-value"}
            layer.addfile(directory)
            payload = tarfile.TarInfo("opt/rift-xattrs/payload")
            payload.mode = 0o644
            payload.size = len(b"xattrs\n")
            payload.pax_headers = payload_xattrs
            layer.addfile(payload, io.BytesIO(b"xattrs\n"))
            executable = tarfile.TarInfo("usr/bin/rift-xattr-probe")
            executable.mode = 0o755
            executable.size = probe.stat().st_size
            with probe.open("rb") as executable_body:
                layer.addfile(executable, executable_body)
        append_layer(xattr_archive.getvalue())
        select_user("0:0")
        xattr_check = subprocess.run(
            [binary, "run", "alpine", "/usr/bin/rift-xattr-probe"],
            env=env, capture_output=True, text=True, timeout=60,
        )
        if xattr_check.returncode != 0 or xattr_check.stdout.strip() != "RIFT_XATTR_OK":
            raise RuntimeError(f"OCI file and directory xattr check failed: {xattr_check!r}")
        no_new_privs = subprocess.run(
            [binary, "run", "alpine", "/bin/busybox", "grep", "-q", "^NoNewPrivs:[[:space:]]*1$", "/proc/self/status"],
            env=env, capture_output=True, text=True, timeout=60,
        )
        if no_new_privs.returncode != 0:
            raise RuntimeError(f"container root did not inherit no_new_privs: {no_new_privs!r}")
        mount_attempt = subprocess.run(
            [binary, "run", "alpine", "/bin/busybox", "sh", "-c", "mkdir -p /tmp/rift-mount-check && /bin/busybox mount -t tmpfs tmpfs /tmp/rift-mount-check"],
            env=env, capture_output=True, text=True, timeout=60,
        )
        mount_output = (mount_attempt.stdout + mount_attempt.stderr).lower()
        if mount_attempt.returncode == 0 or not ("permission denied" in mount_output or "operation not permitted" in mount_output):
            raise RuntimeError(f"container root was not denied a new filesystem mount: {mount_attempt!r}")

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
        select_user("65534")
        numeric_user = subprocess.run([binary, "run", "alpine", "/bin/busybox", "id", "-g"], env=env, capture_output=True, text=True, timeout=60)
        if numeric_user.returncode != 0 or numeric_user.stdout.strip() != "65534":
            raise RuntimeError(f"numeric image user did not inherit its passwd primary group: {numeric_user!r}")
        group_body = b"root:x:0:root\nnobody:x:65534:nobody\nrift-extra:x:1001:nobody\n"
        group_archive = io.BytesIO()
        with tarfile.open(fileobj=group_archive, mode="w") as layer:
            entry = tarfile.TarInfo("etc/group")
            entry.mode = 0o644
            entry.size = len(group_body)
            layer.addfile(entry, io.BytesIO(group_body))
        append_layer(group_archive.getvalue())
        select_user("nobody:root")
        explicit_group = subprocess.run([binary, "run", "alpine", "/bin/busybox", "id", "-g"], env=env, capture_output=True, text=True, timeout=60)
        if explicit_group.returncode != 0 or explicit_group.stdout.strip() != "0":
            raise RuntimeError(f"explicit image group did not override the passwd primary group: {explicit_group!r}")
        select_user("nobody:nobody")
        supplementary = subprocess.run([binary, "run", "alpine", "/bin/busybox", "id", "-G"], env=env, capture_output=True, text=True, timeout=60)
        if supplementary.returncode != 0 or "1001" not in supplementary.stdout.split():
            raise RuntimeError(f"named image user's supplementary group was not applied: {supplementary!r}")
        ownership_archive = io.BytesIO()
        with tarfile.open(fileobj=ownership_archive, mode="w") as layer:
            root = tarfile.TarInfo(".")
            root.type = tarfile.DIRTYPE
            root.mode = 0o755
            root.uid = 1000
            root.gid = 1000
            layer.addfile(root)
            directory = tarfile.TarInfo("opt/rift-owned")
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o700
            directory.uid = 1000
            directory.gid = 1000
            layer.addfile(directory)
            owned_file = tarfile.TarInfo("opt/rift-owned/probe")
            owned_file.mode = 0o600
            owned_file.uid = 1000
            owned_file.gid = 1000
            owned_file.size = len(b"before\n")
            layer.addfile(owned_file, io.BytesIO(b"before\n"))
            named_pipe = tarfile.TarInfo("opt/rift-owned/pipe")
            named_pipe.type = tarfile.FIFOTYPE
            named_pipe.mode = 0o600
            named_pipe.uid = 1000
            named_pipe.gid = 1000
            layer.addfile(named_pipe)
        append_layer(ownership_archive.getvalue())
        select_user("1000:1000")
        owner_check = subprocess.run(
            [binary, "run", "alpine", "/bin/busybox", "sh", "-c",
             "test \"$(stat -c '%u:%g' /)\" = '1000:1000' && "
             "test \"$(stat -c '%u:%g %a' /opt/rift-owned/probe)\" = '1000:1000 600' && "
             "test -p /opt/rift-owned/pipe && "
             "test \"$(stat -c '%u:%g %a' /opt/rift-owned/pipe)\" = '1000:1000 600' && "
             "printf 'after\\n' >> /opt/rift-owned/probe && "
             "grep -q '^after$' /opt/rift-owned/probe && echo RIFT_OWNER_OK"],
            env=env, capture_output=True, text=True, timeout=60,
        )
        if owner_check.returncode != 0 or owner_check.stdout.strip() != "RIFT_OWNER_OK":
            raise RuntimeError(f"OCI file and directory ownership check failed: {owner_check!r}")
        writable_tmp = subprocess.run(
            [binary, "run", "alpine", "/bin/busybox", "sh", "-c", "touch /tmp/rift-user-write && test -f /tmp/rift-user-write && echo RIFT_TMP_WRITABLE"],
            env=env, capture_output=True, text=True, timeout=60,
        )
        if writable_tmp.returncode != 0 or writable_tmp.stdout.strip() != "RIFT_TMP_WRITABLE":
            raise RuntimeError(f"non-root /tmp write check failed: {writable_tmp!r}")
        for invalid in ("missing-user", "4294967295"):
            select_user(invalid)
            rejected = subprocess.run([binary, "run", "alpine", "/bin/busybox", "id", "-u"], env=env, capture_output=True, text=True, timeout=60)
            if rejected.returncode != 125 or "user or group was not found" not in rejected.stdout:
                raise RuntimeError(f"invalid image user was not rejected: {invalid}: {rejected!r}")
        archive = io.BytesIO()
        with tarfile.open(fileobj=archive, mode="w") as layer:
            layer.addfile(tarfile.TarInfo("bin/.wh.sh"))
        append_layer(archive.getvalue())
        select_user("1000:1000")
        shell_free = subprocess.run([binary, "run", "alpine", "/bin/pwd"], env=env, capture_output=True, text=True, timeout=60)
        if shell_free.returncode != 0 or shell_free.stdout.strip() != "/tmp":
            raise RuntimeError(f"shell-free working directory check failed: {shell_free!r}")
        removed_shell = subprocess.run([binary, "run", "alpine", "/bin/sh", "-c", "true"], env=env, capture_output=True, text=True, timeout=60)
        if removed_shell.returncode != 125 or "rift-exec: exec:" not in removed_shell.stdout:
            raise RuntimeError(f"fixture still contains a working shell: {removed_shell!r}")
        if list((data / "runtime").iterdir()):
            raise RuntimeError("process settings run left runtime staging behind")
    print("Rift process and ownership check passed: no_new_privs, root mount denial, users, groups, OCI ownership, xattrs and capabilities, FIFOs, writable /tmp, shell-free image")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
