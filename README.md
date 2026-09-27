# Rift

**Ridiculously lightweight containers for macOS.**

**No Docker, daemon, or Docker Desktop. One binary is the distribution target.**

Rift is an early-stage Zig container runtime for Apple Silicon Macs. It pulls public OCI images and runs commands in Linux VMs, including detached servers with one localhost TCP port mapping. On the first `run`, the binary downloads a pinned Alpine ISO, verifies its SHA-256, and installs the guest boot files. Volumes and complete OCI process isolation remain unfinished.

## Current commands

```sh
rift --help
rift version
rift system info
rift system df
rift clean
rift clean --yes
rift pull alpine
rift images
rift run --rm alpine echo hello
rift run -w /tmp alpine pwd
rift pull nginx
rift run -d -p 8080:80 nginx
rift ps
rift logs <container-id>
rift stop <container-id>
rift rm <container-id>
```

Image pulls use anonymous registry access and save SHA-256-verified OCI blobs and reference metadata under `~/Library/Application Support/Rift`. `run` pulls an image automatically when it is not cached; `pull` remains available to fetch or refresh it explicitly. `system df` reports logical file bytes by category without modifying storage. `clean` previews abandoned runtime staging; `clean --yes` removes only staging whose Rift process lock has been released. Image cache, active VMs, and container logs are preserved. `run` uses the image's `Entrypoint`, `Cmd`, `Env`, `User`, and absolute `WorkingDir` defaults, or your command and `-w` override. A static guest executor applies the working directory and numeric or named UID/GID from the image, including images without `/bin/sh`. Each run gets a disposable writable overlay inside its own Linux VM, currently configured with 256 MiB of guest RAM. `-p` accepts one `HOST:GUEST` TCP mapping bound to `127.0.0.1`. `run -d` starts one background Rift process per VM and prints its container ID. `stop` currently forces the VM off; `--rm` is unavailable with `-d`. Private registry credentials are not implemented.

## Build

Requires Zig 0.16.0 or newer.

```sh
brew install zig
zig build
zig build test
zig build run -- pull alpine
zig build run-check
zig build run-network-check
zig build run-port-check
zig build run-detached-check
zig build run-auto-pull-check
zig build run-process-check
zig build run -- system info
```

GitHub Actions is disabled; run these checks locally. `zig-out/bin/rift` needs no Zig or Python at runtime. A fresh installation needs network access on the first `run` to fetch the verified Alpine guest boot files.

To install a locally built binary in `~/.local/bin`:

```sh
zig build -Doptimize=ReleaseSafe
mkdir -p "$HOME/.local/bin"
install -m 755 zig-out/bin/rift "$HOME/.local/bin/rift"
```

Add `~/.local/bin` to your shell's `PATH` if needed. The binary is signed locally with the Virtualization entitlement. This repository does not yet have a Developer ID signature or notarized public download; macOS Gatekeeper rejects the current ad-hoc signed archive. The source build is the supported installation path for now.

For reproducible local size, startup, and host worker RSS measurements, run `zig build -Doptimize=ReleaseSafe benchmark` after pulling and running Alpine once. On one Apple M2 run, the signed binary was 1,500,192 bytes and five subsequent cached Alpine launches had a 1,028.8 ms median. See [the benchmark method and limits](docs/BENCHMARKS.md).

To check the macOS VM bridge on Apple Silicon, prepare the pinned Alpine guest and run the local integration check:

```sh
python3 scripts/prepare_guest.py
zig build vm-check
zig build vm-share-check
zig build vm-network-check
zig build oci-vm-check
```

These checks boot Alpine, mount a read-only host directory, obtain a guest DHCP lease, and run `/bin/echo` from an Alpine root filesystem inside the VM. Run `rift pull alpine` before the direct `oci-vm-check` probe and `run-process-check` fixture. Other public CLI run checks pull Alpine automatically if absent; `run-auto-pull-check` uses an empty temporary HOME and requires network access for the registry and the pinned guest ISO. The DNS check also requires external DNS access.

To assemble a pulled Alpine root filesystem locally, use the manifest digest shown by `rift images`:

```sh
zig run src/rootfs_probe.zig -- "$HOME/Library/Application Support/Rift" sha256:REPLACE_WITH_DIGEST_FROM_RIFT_IMAGES
```

## Runtime plan

macOS uses a Linux VM to run Linux containers. Rift uses Apple's Virtualization.framework, an OCI image store, and a small embedded Linux process helper. See [the architecture](docs/ARCHITECTURE.md) for the boundaries, execution path, security constraints, and current status.

No Docker Engine, Docker CLI, Docker Desktop, or container daemon is part of the design. Each detached container has one background Rift process that owns its VM; there is no shared always-on manager.

## Status

- [x] Zig CLI build, help, version, and host information
- [x] Apache License 2.0, architecture notes, local formatting/build/test checks
- [x] OCI references, indexes, manifests, and `linux/arm64` selection with tests
- [x] Streaming content-addressed blob storage with SHA-256 and size verification
- [x] Public OCI pulls with Bearer token auth, platform selection, and verified blob downloads
- [x] Foreground and detached runs automatically pull uncached public images
- [x] Local image metadata and listing
- [x] Read-only disk usage report by storage category
- [x] Local Virtualization.framework bridge and Alpine guest boot check
- [x] First-run download and verification of pinned guest boot files from the binary
- [ ] Image removal
- [x] Initial safe extraction of tar, gzip, and zstd layers, including OCI whiteouts and regular-file hardlinks
- [x] Local root filesystem assembly from verified manifest and layer blobs
- [x] Local VM smoke that executes pulled Alpine BusyBox through a read-only share
- [ ] Complete OCI filesystem metadata and special files
- [x] Basic foreground OCI command execution through Rift's public CLI
- [x] Image entrypoint, command, and environment defaults
- [x] Absolute image `WorkingDir`, `-w` override, and numeric or named image `User` through a static guest executor
- [ ] Broader OCI process settings and isolation
- [x] Outbound NAT and DNS for foreground commands
- [x] One localhost TCP port mapping for foreground commands
- [x] Detached run, process listing, plain logs, stop, and remove
- [x] Preview and confirmed cleanup of abandoned runtime staging
- [ ] Structured logs, volumes, and image cache pruning

Foreground runs remove their temporary state on normal completion, including runs without `--rm`. Detached runs keep their logs and status until `rift rm`; the VM and temporary root filesystem are removed on stop or exit. Local checks have served the nginx welcome page over a forwarded localhost port, including with `run -d`. An interrupted foreground run can leave staging, which `rift clean` can preview and remove after the process exits. A local release archive is packaged and checked, but no public notarized release exists yet. Do not use Rift as a Docker replacement today.

## License

Apache-2.0. See [LICENSE](LICENSE).
