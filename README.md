# Rift

**Ridiculously lightweight containers for macOS.**

**No Docker. No daemon. No Docker Desktop. Just one binary.**

Rift is an early-stage Zig project for running Linux containers on macOS. Those lines describe the intended product. The current release is only a host CLI: it does not pull images, start a Linux VM, or run containers yet.

## Current commands

```sh
rift --help
rift version
rift system info
```

These commands are implemented. Container commands will appear here only after they work.

## Build

Requires Zig 0.16.0 or newer.

```sh
brew install zig
zig build
zig build test
zig build run -- system info
```

## Runtime plan

macOS uses a Linux VM to run Linux containers. Rift is being designed around Apple's Virtualization.framework, an OCI image store, and a small Linux guest agent. See [the architecture](docs/ARCHITECTURE.md) for the proposed boundaries, execution path, security constraints, and current status.

No Docker Engine, Docker CLI, Docker Desktop, or container daemon is part of the design. A detached container will need a process to own its VM; the plan is one process per VM, without a shared always-on manager.

## Status

- [x] Zig CLI build, help, version, and host information
- [x] Apache License 2.0, architecture notes, local formatting/build/test checks
- [x] OCI references, indexes, manifests, and `linux/arm64` selection with tests
- [ ] OCI registry access, image verification, and local image storage
- [ ] Safe layer extraction
- [ ] Linux VM boot and guest command execution
- [ ] Container lifecycle, logs, networking, and cleanup

There is no usable container workflow or release artifact yet. Do not use Rift as a Docker replacement today.

## License

Apache-2.0. See [LICENSE](LICENSE).
