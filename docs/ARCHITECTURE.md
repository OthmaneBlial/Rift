# Architecture

## Current state

`help`, `version`, `system info`, `system df`, public `pull`, `images`, foreground and detached `run`, `ps`, `logs`, `stop`, and `rm` work. `system df` counts logical file bytes in each Rift storage category without changing files. Pull downloads and verifies OCI metadata and blobs for the host architecture, then records the resolved reference locally. `run` currently requires a previously pulled image on Apple Silicon. It applies image entrypoint, command, and environment defaults. Images requesting a non-root user or working directory other than `/` are rejected until those settings can be honored. Outbound NAT, DNS, and one localhost TCP port mapping work; volumes remain unfinished.

Rift's Zig/Objective-C VM bridge boots an Alpine ARM64 kernel and initramfs to a shell, runs a command, and shuts down through the local `zig build vm-check` gate. On first use, `rift run` downloads a pinned, SHA-256-verified Alpine ISO, extracts its boot files with macOS's built-in `tar`, and installs verified copies under the user's Application Support directory. Alpine packages its ARM64 kernel as a compressed EFI zboot image; Rift extracts the uncompressed `Image` needed for direct boot. `scripts/prepare_guest.py` separately prepares the same files for local VM probes.

The layer installer handles OCI tar, gzip, and zstd layers, including regular-file hardlinks. It applies whiteouts before entries from the same layer and refuses archive paths or parent symlinks that could redirect host writes. Root filesystem assembly reads a verified platform manifest, checks each cached layer digest and size again, and applies layers to a private staging directory. Rift exposes that directory read-only through VirtioFS. The guest mounts a writable tmpfs overlay above it, obtains a DHCP lease on a Virtualization.framework NAT adapter, copies DNS settings into the overlay, executes the command with `chroot`, writes an exit status to a separate disposable control share, and powers off. The CLI relays console output and returns that status. For `-p`, a host TCP listener on `127.0.0.1` forwards one port to the DHCP address reported by the guest. Detached runs spawn one background Rift process with a private state directory, a file lock for liveness, plain output logs, and a stop request file. `stop` currently forces the VM off, then normal host cleanup runs. Local checks have proved output, exit code 37, shell argument quoting, normal temporary directory cleanup, a DNS lookup from pulled Alpine, an HTTP 200 nginx welcome page through the forwarded port, and detached lifecycle commands. Complete OCI ownership, directory modes, timestamps, extended attributes, and special files remain unfinished.

## Runtime shape

Linux containers need a Linux kernel. On macOS, Rift will run workloads inside a small Linux virtual machine managed by Apple's Virtualization.framework. The host CLI will own the VM lifecycle; the Linux guest will own container namespaces and process execution.

The intended boundaries are:

1. **CLI** — argument parsing, diagnostics, and user-visible lifecycle.
2. **OCI client** — registry authentication, manifests and indexes, platform selection, blob download, and digest checks.
3. **Image store** — content-addressed blobs and image metadata under the user's Application Support directory.
4. **Layer installer** — safe tar extraction and root filesystem assembly, without following paths outside the image root.
5. **VM controller** — Linux kernel and initramfs boot, console, guest communication, and shutdown through Virtualization.framework.
6. **Guest execution** — a generated initramfs script currently mounts the image and starts explicit commands. A guest agent with OCI process settings and stricter isolation remains planned.
7. **Networking and mounts** — outbound guest networking and one localhost TCP port mapping work; explicit host directory shares remain planned.

The host-facing implementation stays in Zig. The guest agent is also intended to be Zig. Apple framework calls should remain a narrow macOS-only boundary.

## Planned execution path

`rift pull alpine` resolves the reference, authenticates anonymously to public registries, selects the host's Linux architecture, fetches each required blob, verifies its digest, and publishes verified data into the content-addressed store. `rift images` lists locally recorded references and their platform manifest digests.

`rift run --rm alpine echo hello` assembles the image root, starts a Linux VM with the pinned Alpine kernel, mounts the read-only image through VirtioFS, starts the command on an ephemeral writable overlay, relays output, returns its exit status, and removes temporary host state. The guest currently uses `chroot` inside a VM; Linux namespace and capability controls still need implementation.

Image downloads and guest execution are separate steps. A pull alone does not prove that an arbitrary image can execute with full OCI process semantics.

## Process model

Foreground commands own their VM for the duration of the command. A detached container has one host process that owns its VM, with state files for discovery and stop requests. A file lock tracks whether that process is still alive without relying on a reused PID. Rift does not require a shared, always-on daemon. Detached state and logs remain until `rift rm`.

Warm VM reuse is a measured optimization, not a prerequisite for correctness. Any reuse must preserve workload isolation and provide explicit shutdown and cleanup behavior.

## Security constraints

- Registry responses, image metadata, and layer archives are untrusted input.
- Verify content digests before making blobs visible to other commands.
- Bound response sizes and validate manifests before allocating or extracting data.
- Reject archive traversal, unsafe links, and writes outside the image root.
- Do not share host paths unless the user explicitly requests them.
- Treat the guest VM as a security boundary that still needs threat-model review and adversarial testing; a VM alone does not make all host integration safe.
- Keep registry credentials out of logs and repository files. Select a macOS credential-storage mechanism before implementing persisted authentication.
- Validate the signing and entitlement path needed to create Virtualization.framework VMs before claiming public binary distribution. See Apple's [Linux VM guide](https://developer.apple.com/documentation/virtualization/running-linux-in-a-virtual-machine).
- `rift clean` must report what it will delete and preserve user data unless the user confirms the requested cleanup.

## Constraints and proof

Apple silicon is the first target. OCI platform selection must be explicit; an `arm64` host must not silently run an `amd64` image through emulation.

Boot time, memory, binary size, image storage, and cleanup behavior will be measured before performance claims are published. Local parsing and storage tests cannot prove a real VM boot or container execution. Those need macOS integration runs.

## Milestones

1. **Done:** OCI references, indexes, manifests, and platform selection with tests.
2. **Done:** Streaming content-addressed SHA-256 storage with atomic publication and verification.
3. **Done:** Public registry pulls, authentication, and local image metadata.
4. Initial secure image layer extraction, regular-file hardlinks, and image listing; image removal remains.
5. A bootable Linux guest and a minimal command result path, proven locally.
6. Alpine and nginx run through the public CLI; basic detached lifecycle and plain logs work. Full OCI process settings and broader cleanup remain.
7. Outbound networking and one localhost TCP port mapping are proven locally; explicit volumes remain.
8. Reproducible runtime benchmarks and signed release distribution.
