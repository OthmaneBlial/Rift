# Rift

**Ridiculously lightweight containers for macOS.**

**No Docker. No daemon. No Docker Desktop. Just one binary.**

Rift is an early-stage Zig project for running Linux containers on macOS. Those lines describe the intended product. The CLI can pull public OCI images for the Mac's architecture. It cannot start a Linux VM or run containers yet.

## Current commands

```sh
rift --help
rift version
rift system info
rift pull alpine
rift images
```

Image pulls use anonymous registry access and save SHA-256-verified OCI blobs and reference metadata under `~/Library/Application Support/Rift`. Private registry credentials and container execution are not implemented.

## Build

Requires Zig 0.16.0 or newer.

```sh
brew install zig
zig build
zig build test
zig build run -- system info
```

GitHub Actions is disabled; run these checks locally.

To check the macOS VM bridge on Apple Silicon, prepare the pinned Alpine guest and run the local integration check:

```sh
python3 scripts/prepare_guest.py
zig build vm-check
```

This boots Alpine, runs a command in its initramfs shell, and shuts down. OCI container execution is still in development.

To assemble a pulled Alpine root filesystem locally, use the manifest digest shown by `rift images`:

```sh
zig run src/rootfs_probe.zig -- "$HOME/Library/Application Support/Rift" sha256:REPLACE_WITH_DIGEST_FROM_RIFT_IMAGES
```

## Runtime plan

macOS uses a Linux VM to run Linux containers. Rift is being designed around Apple's Virtualization.framework, an OCI image store, and a small Linux guest agent. See [the architecture](docs/ARCHITECTURE.md) for the proposed boundaries, execution path, security constraints, and current status.

No Docker Engine, Docker CLI, Docker Desktop, or container daemon is part of the design. A detached container will need a process to own its VM; the plan is one process per VM, without a shared always-on manager.

## Status

- [x] Zig CLI build, help, version, and host information
- [x] Apache License 2.0, architecture notes, local formatting/build/test checks
- [x] OCI references, indexes, manifests, and `linux/arm64` selection with tests
- [x] Streaming content-addressed blob storage with SHA-256 and size verification
- [x] Public OCI pulls with Bearer token auth, platform selection, and verified blob downloads
- [x] Local image metadata and listing
- [x] Local Virtualization.framework bridge and Alpine guest boot check
- [ ] Image removal
- [x] Initial safe extraction of tar, gzip, and zstd layers, including OCI whiteouts
- [x] Local root filesystem assembly from verified manifest and layer blobs
- [ ] Hardlinks and complete OCI filesystem metadata
- [ ] OCI command execution through Rift's public CLI
- [ ] Container lifecycle, logs, networking, and cleanup

There is no container execution workflow or release artifact yet. Do not use Rift as a Docker replacement today.

## License

Apache-2.0. See [LICENSE](LICENSE).
