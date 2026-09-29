# Rift v0.2.0 — Apple Silicon source preview

This release brings Rift's newer container, image-build, and resource controls to its Homebrew source-build install. Rift runs `linux/arm64` OCI images in disposable Linux VMs on Apple Silicon Macs without Docker or a permanent daemon.

## Install

```sh
brew install OthmaneBlial/rift/rift
```

If Rift is already installed, run `brew upgrade OthmaneBlial/rift/rift`. Homebrew uses Zig during the build; the installed Rift binary does not require Zig or Docker.

## Changes since v0.1.2

- Build local OCI images from a supported Dockerfile subset: multiple `FROM` stages, `COPY`, `RUN`, `ENV`, `USER`, `WORKDIR`, `ENTRYPOINT`, `CMD`, and `STOPSIGNAL`.
- Stream detached `exec` output and opt-in stdin, attach a resizable TTY with `exec -it`, emit binary-safe JSON Lines logs, and honor an image's stop signal.
- Configure VM CPU and memory, disable VM networking, and set optional cgroup CPU, memory, and process limits. Choose reduced or empty capabilities and adjust individual capabilities explicitly.
- Restore global PAX metadata, supported extended attributes, FIFOs, and character or block device nodes outside the guest-managed `/dev`. Reject replaced volume sources and bound ownership-index work.
- Reduce local boot-file storage through APFS sharing and shorten graceful VM shutdown. On one M2 Mac, three cached Alpine launches had a 1.13-second median. The idle Rift worker and VM service had a 154.7 MiB median process footprint. Methods and limits are in [benchmarks](https://github.com/OthmaneBlial/Rift/blob/v0.2.0/docs/BENCHMARKS.md).

## Verification and limits

The local Apple Silicon suite covers Zig formatting and tests, a ReleaseSafe build, real Alpine and Nginx VMs, OCI pulls, build stages, networking, volumes, lifecycle, resource controls, and a private-registry fixture. The full workflow is verified on Apple M2 with macOS 26.6; macOS 12 and other Macs are not verified.

This remains a source preview. Rift supports one forwarded TCP port and up to 16 explicit volumes per run. Dockerfile support is partial. No Developer ID-signed or notarized binary is attached, and the VM boundary has not had an independent security assessment.
