# Architecture

## Current state

`help`, `version`, `system info`, public `pull`, `images`, and a basic foreground `run` work. Pull downloads and verifies OCI metadata and blobs for the host architecture, then records the resolved reference locally. `run` currently requires a previously pulled image on Apple Silicon. It applies image entrypoint, command, and environment defaults. Images requesting a non-root user or working directory other than `/` are rejected until those settings can be honored. Outbound NAT and DNS work; port forwarding, volumes, and detached containers remain unfinished.

Rift's Zig/Objective-C VM bridge boots an Alpine ARM64 kernel and initramfs to a shell, runs a command, and shuts down through the local `zig build vm-check` gate. `scripts/prepare_guest.py` reproduces those guest files from a pinned, SHA-256-verified Alpine ISO. Alpine packages its ARM64 kernel as a compressed EFI zboot image; the script extracts the uncompressed `Image` needed for direct boot. `rift run` uses verified copies installed under the user's Application Support directory.

The layer installer handles OCI tar, gzip, and zstd layers. It applies whiteouts before entries from the same layer and refuses archive paths or parent symlinks that could redirect host writes. Root filesystem assembly reads a verified platform manifest, checks each cached layer digest and size again, and applies layers to a private staging directory. Rift exposes that directory read-only through VirtioFS. The guest mounts a writable tmpfs overlay above it, obtains a DHCP lease on a Virtualization.framework NAT adapter, copies DNS settings into the overlay, executes the command with `chroot`, writes an exit status to a separate disposable control share, and powers off. The CLI relays console output and returns that status. Local checks have proved output, exit code 37, shell argument quoting, temporary directory cleanup, and a DNS lookup from the pulled Alpine image. Hardlinks and complete OCI ownership, directory modes, timestamps, and extended attributes remain unfinished.

## Runtime shape

Linux containers need a Linux kernel. On macOS, Rift will run workloads inside a small Linux virtual machine managed by Apple's Virtualization.framework. The host CLI will own the VM lifecycle; the Linux guest will own container namespaces and process execution.

The intended boundaries are:

1. **CLI** — argument parsing, diagnostics, and user-visible lifecycle.
2. **OCI client** — registry authentication, manifests and indexes, platform selection, blob download, and digest checks.
3. **Image store** — content-addressed blobs and image metadata under the user's Application Support directory.
4. **Layer installer** — safe tar extraction and root filesystem assembly, without following paths outside the image root.
5. **VM controller** — Linux kernel and initramfs boot, console, guest communication, and shutdown through Virtualization.framework.
6. **Guest execution** — a generated initramfs script currently mounts the image and starts explicit commands. A guest agent with OCI process settings and stricter isolation remains planned.
7. **Networking and mounts** — outbound guest networking, requested port forwarding, and explicit host directory shares.

The host-facing implementation stays in Zig. The guest agent is also intended to be Zig. Apple framework calls should remain a narrow macOS-only boundary.

## Planned execution path

`rift pull alpine` resolves the reference, authenticates anonymously to public registries, selects the host's Linux architecture, fetches each required blob, verifies its digest, and publishes verified data into the content-addressed store. `rift images` lists locally recorded references and their platform manifest digests.

`rift run --rm alpine echo hello` assembles the image root, starts a Linux VM with the pinned Alpine kernel, mounts the read-only image through VirtioFS, starts the command on an ephemeral writable overlay, relays output, returns its exit status, and removes temporary host state. The guest currently uses `chroot` inside a VM; Linux namespace and capability controls still need implementation.

Image downloads and guest execution are separate steps. A pull alone does not prove that an arbitrary image can execute with full OCI process semantics.

## Process model

Foreground commands own their VM for the duration of the command. A detached container needs a process to keep its VM alive. The current proposal is one host process per running VM, with state files for discovery and control; Rift should not require a shared, always-on daemon. This lifecycle still needs a working prototype before the CLI promises detached containers.

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
4. Initial secure image layer extraction and image listing; hardlinks and removal remain.
5. A bootable Linux guest and a minimal command result path, proven locally.
6. One real Alpine command through the public CLI, followed by full OCI process settings, lifecycle, logs, and cleanup.
7. Outbound networking is proven locally; port forwarding and explicit volumes remain.
8. Reproducible runtime benchmarks and signed release distribution.
