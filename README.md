# Rift

**Ridiculously lightweight containers for macOS.**

**No Docker, daemon, or Docker Desktop. One binary is the distribution target.**

Project site: [othmaneblial.github.io/Rift](https://othmaneblial.github.io/Rift/)

Rift is an early-stage Zig container runtime for Apple Silicon Macs. It pulls OCI images and runs commands in Linux VMs, including detached servers with one localhost TCP port mapping and explicit file and directory volumes. File-volume sources must share a filesystem with Rift's runtime storage. On the first `run`, the binary downloads a pinned Alpine ISO, verifies its SHA-256, and installs the guest boot files. Each command now gets private Linux PID and mount namespaces, minimal `/dev` and `/proc` mounts, and reduced capabilities. Complete OCI process settings remain unfinished.

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
rift run -e MESSAGE=hello alpine sh -c 'echo "$MESSAGE"'
rift run -v "$PWD:/workspace" alpine ls /workspace
rift pull nginx
rift run -d -p 8080:80 nginx
rift ps
rift logs <container-id>
rift stop <container-id>
rift rm <container-id>
rift rmi alpine
rift clean
```

Image pulls support public registries and optional credentials for private Bearer-token challenges. Set both `RIFT_REGISTRY_USERNAME` and `RIFT_REGISTRY_PASSWORD` in the environment before pulling a private image. Rift sends them as HTTP Basic credentials only to an HTTPS token realm, or to a loopback HTTP realm for local registries. Plain HTTP registry URLs are limited to `localhost` and `127.0.0.1`; authorization headers are stripped on redirects. Rift does not persist credentials; use these variables only with a registry you trust. A local registry fixture verifies the full Basic-to-Bearer pull flow; third-party private registry providers remain untested. Pulls save SHA-256-verified OCI blobs and reference metadata under `~/Library/Application Support/Rift`. `run` pulls an uncached image automatically; `pull` fetches or refreshes it explicitly. `rmi <image>` removes a local image reference; `clean` previews its now unused blobs, and `clean --yes` reclaims them. `system df` reports logical file bytes. `clean` also previews abandoned runtime staging. Referenced images, active VMs, guest boot files, and container logs are preserved. If image metadata is corrupt, cache pruning stops without deleting blobs.

`run` uses the image's `Entrypoint`, `Cmd`, `Env`, `User`, and absolute `WorkingDir` defaults, with command, `-e KEY=VALUE`, and `-w` overrides. Environment overrides must include a value; Rift does not copy host variables implicitly. A static guest executor applies the working directory and numeric or named UID/GID from the image, resolves a numeric user's primary GID from `/etc/passwd`, and applies supplementary groups from `/etc/group` when a passwd user is available. It also works with images without `/bin/sh`.

Each run gets a disposable writable overlay inside its own Linux VM, currently configured with 256 MiB of guest RAM. `-v HOST:TARGET[:ro|rw]` shares an existing host directory or regular file with the guest. Shares are read-only by default; `:rw` allows the container to change host files. Paths must be absolute, the host source cannot be a symlink, and the guest target cannot traverse image symlinks. File-volume sources must share a filesystem with Rift's runtime storage. `/dev` and `/proc` are reserved for the guest. Up to 16 shares can be mounted. `-p` accepts one `HOST:GUEST` TCP mapping bound to `127.0.0.1`. `run -d` starts one background Rift process per VM and prints its container ID. `stop` sends SIGTERM to the workload and forces the VM off after 10 seconds if it has not exited. `kill` immediately forces the VM off. `--rm` is unavailable with `-d`.

For a persistent writable directory:

```sh
mkdir -p data
rift run -v "$PWD/data:/data:rw" alpine sh -c 'echo saved > /data/example'
```

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
zig build cache-lock-check
zig build cache-prune-check
zig build run-process-check
zig build run-volume-check
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

For reproducible local size, startup, and host worker RSS measurements, run `zig build -Doptimize=ReleaseSafe benchmark` after pulling and running Alpine once. On one Apple M2, the current signed binary was 1,584,704 bytes; three cached Alpine runs had subsequent launch medians of 1,625.9, 1,671.0, and 1,010.8 ms. See [the benchmark method, samples, and limits](docs/BENCHMARKS.md).

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
- [x] Optional environment credentials for private Bearer-token challenges (unit-tested; no private-provider integration test yet)
- [x] Foreground and detached runs automatically pull uncached public images
- [x] Local image metadata and listing
- [x] Read-only disk usage report by storage category
- [x] Local Virtualization.framework bridge and Alpine guest boot check
- [x] First-run download and verification of pinned guest boot files from the binary
- [x] Local image reference removal with `rmi`; confirmed blob reclamation with `clean --yes`
- [x] Initial safe extraction of tar, gzip, and zstd layers, including OCI whiteouts and regular-file hardlinks
- [x] Local root filesystem assembly from verified manifest and layer blobs
- [x] Local VM smoke that executes pulled Alpine BusyBox through a read-only share
- [x] Apply standard tar modification times to files, symlinks, and directories during root filesystem assembly
- [ ] OCI ownership, PAX metadata, extended attributes, and special files
- [x] Basic foreground OCI command execution through Rift's public CLI
- [x] Image entrypoint, command, environment defaults, and `-e` overrides
- [x] Absolute image `WorkingDir`, `-w` override, numeric or named image `User`, and image supplementary groups through a static guest executor
- [x] Private PID and mount namespaces, basic `/dev` and `/proc`, reduced capabilities, and no privilege escalation
- [ ] Broader OCI process settings and isolation
- [x] Outbound NAT and DNS for foreground commands
- [x] One localhost TCP port mapping for foreground commands
- [x] Detached run, process listing, plain logs, graceful stop, force kill, and remove
- [x] Explicit read-only and writable directory volumes
- [x] Explicit read-only and writable file volumes
- [x] Preview and confirmed cleanup of abandoned runtime staging
- [x] Preview and confirmed pruning of unreferenced image blobs under a cache lock
- [ ] Structured logs

Foreground runs remove their temporary state on normal completion, including runs without `--rm`. Detached runs keep their logs and status until `rift rm`; the VM and temporary root filesystem are removed on stop, kill, or exit. Local checks have served the nginx welcome page over a forwarded localhost port, including with `run -d`. An interrupted foreground run can leave staging, which `rift clean` can preview and remove after the process exits. `clean` also reclaims blobs left by interrupted or refreshed pulls when no recorded image uses them. A local release archive is packaged and checked, but no public notarized release exists yet. Do not use Rift as a Docker replacement today.

## License

Apache-2.0. See [LICENSE](LICENSE).
