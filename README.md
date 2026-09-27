# Rift

**Ridiculously lightweight containers for macOS.**

**No Docker, daemon, or Docker Desktop. One binary is the distribution target.**

Rift is an early-stage Zig container runtime for Apple Silicon Macs. It can pull public OCI images and run a command in a short-lived Linux VM. The current build needs separately installed, verified guest boot files. Outbound networking and one localhost TCP port mapping work; volumes and detached containers remain unfinished.

## Current commands

```sh
rift --help
rift version
rift system info
rift pull alpine
rift images
rift run --rm alpine echo hello
rift pull nginx
rift run -p 8080:80 nginx
```

Image pulls use anonymous registry access and save SHA-256-verified OCI blobs and reference metadata under `~/Library/Application Support/Rift`. `run` requires an image pulled earlier, including `nginx` in the example above. It uses the image's `Entrypoint`, `Cmd`, and `Env` defaults, or your command arguments. Each run gets a disposable writable overlay inside its own Linux VM. `-p` accepts one `HOST:GUEST` TCP mapping bound to `127.0.0.1`. Images requesting a non-root user or working directory other than `/` are rejected for now. Private registry credentials are not implemented.

## Build

Requires Zig 0.16.0 or newer.

```sh
brew install zig
python3 scripts/prepare_guest.py --install
zig build
zig build test
zig build run -- pull alpine
zig build run-check
zig build run-network-check
zig build run-port-check
zig build run -- system info
```

GitHub Actions is disabled; run these checks locally.

To check the macOS VM bridge on Apple Silicon, prepare the pinned Alpine guest and run the local integration check:

```sh
python3 scripts/prepare_guest.py
zig build vm-check
zig build vm-share-check
zig build vm-network-check
zig build oci-vm-check
```

These checks boot Alpine, mount a read-only host directory, obtain a guest DHCP lease, and run `/bin/echo` from a pulled Alpine root filesystem inside the VM. Run `rift pull alpine` before `oci-vm-check`, `run-check`, `run-network-check`, or `run-port-check`. The DNS check requires external DNS access.

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
- [x] Initial safe extraction of tar, gzip, and zstd layers, including OCI whiteouts and regular-file hardlinks
- [x] Local root filesystem assembly from verified manifest and layer blobs
- [x] Local VM smoke that executes pulled Alpine BusyBox through a read-only share
- [ ] Complete OCI filesystem metadata and special files
- [x] Basic foreground OCI command execution through Rift's public CLI
- [x] Image entrypoint, command, and environment defaults
- [ ] Non-root user and non-root working directory support
- [x] Outbound NAT and DNS for foreground commands
- [x] One localhost TCP port mapping for foreground commands
- [ ] Detached lifecycle, structured logs, volumes, and broader cleanup

Each `run` is temporary on normal completion, including runs without `--rm`. The CLI relays console output and returns the guest command's exit status. Local checks have served the nginx welcome page over a forwarded localhost port. Interrupting a run can leave temporary staging until cleanup is implemented. There is no release artifact yet. Do not use Rift as a Docker replacement today.

## License

Apache-2.0. See [LICENSE](LICENSE).
