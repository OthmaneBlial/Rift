# Architecture

## Current state

`help`, `version`, `system info`, `system df`, `clean`, public and credentialed `pull`, `images`, `rmi`, foreground and detached `run`, `ps`, `logs`, `stop`, and `rm` work. `system df` counts logical file bytes in each Rift storage category without changing files. `rmi` removes one local image reference under the cache lock. `clean` previews stale runtime staging and unreferenced image blobs; `clean --yes` removes them under process and cache locks. It keeps referenced images, logs, guest boot files, and active VM staging. Pull downloads and verifies OCI metadata and blobs for the host architecture, then records the resolved reference locally. Private pulls can use paired process-environment credentials to obtain a Bearer token; Rift does not persist them. Credential validation and Basic-header generation have unit coverage, but no private registry provider has been integration-tested. Foreground and detached `run` pull an uncached image automatically on Apple Silicon. A small statically linked Linux guest executor applies the image entrypoint, command, environment, numeric or named user/group, and absolute working directory. `-e KEY=VALUE` overrides image environment variables and `-w` overrides the directory. Outbound NAT, DNS, one localhost TCP port mapping, and explicit file and directory volumes work. File-volume sources must share a filesystem with Rift's runtime storage.

Rift's Zig/Objective-C VM bridge boots an Alpine ARM64 kernel and initramfs to a shell, runs a command, and shuts down through the local `zig build vm-check` gate. On first use, `rift run` downloads a pinned, SHA-256-verified Alpine ISO, extracts its boot files with macOS's built-in `tar`, and installs verified copies under the user's Application Support directory. Alpine packages its ARM64 kernel as a compressed EFI zboot image; Rift extracts the uncompressed `Image` needed for direct boot. `scripts/prepare_guest.py` separately prepares the same files for local VM probes.

The layer installer handles OCI tar, gzip, and zstd layers, including regular-file hardlinks and directory permissions. It applies whiteouts before entries from the same layer and refuses archive paths or parent symlinks that could redirect host writes. Root filesystem assembly reads a verified platform manifest, checks each cached layer digest and size again, and applies layers to a private staging directory. Rift exposes that directory read-only through VirtioFS. The guest mounts a writable tmpfs overlay above it, obtains a DHCP lease on a Virtualization.framework NAT adapter, and copies DNS settings into the overlay. The executor creates private PID and mount namespaces, enters the image with `chroot`, mounts a minimal `/dev` and namespace-specific `/proc`, drops most Linux capabilities, disables privilege escalation, and executes the command. The guest writes an exit status to a separate disposable control share and powers off. Directory volumes get separate VirtioFS devices. File volumes use private, one-file directories linked to the requested host file, then bind-mount that file inside the guest; this preserves direct read/write behavior without exposing neighboring host files. Both source kinds reject symlinks at their final path, and guest targets are traversed without following image symlinks. Host shares are read-only unless the user passes `:rw`. File sources must be on the runtime storage filesystem so Rift can create the private hard link. The CLI relays console output and returns the command's status. For `-p`, a host TCP listener on `127.0.0.1` forwards one port to the DHCP address reported by the guest. Detached runs spawn one background Rift process with a private state directory, a file lock for liveness, plain output logs, and a stop request file. `stop` currently forces the VM off, then normal host cleanup runs. Local checks have proved output, exit code 37, shell argument quoting, normal temporary directory cleanup, a DNS lookup from pulled Alpine, an HTTP 200 nginx welcome page through the forwarded port, detached lifecycle commands, read-only and writable file and directory volumes, nested volume targets, namespace-specific `/proc`, basic devices, and rejection of unsafe volume targets and container-initiated mounts. OCI ownership, timestamps, extended attributes, and special files remain unfinished.

## Runtime shape

Linux containers need a Linux kernel. On macOS, Rift will run workloads inside a small Linux virtual machine managed by Apple's Virtualization.framework. The host CLI will own the VM lifecycle; the Linux guest will own container namespaces and process execution.

The intended boundaries are:

1. **CLI** — argument parsing, diagnostics, and user-visible lifecycle.
2. **OCI client** — registry authentication, manifests and indexes, platform selection, blob download, and digest checks.
3. **Image store** — content-addressed blobs and image metadata under the user's Application Support directory.
4. **Layer installer** — safe tar extraction and root filesystem assembly, without following paths outside the image root.
5. **VM controller** — Linux kernel and initramfs boot, console, guest communication, and shutdown through Virtualization.framework.
6. **Guest execution** — a generated initramfs script mounts the image and invokes a static helper for private PID/mount namespaces, basic devices and `/proc`, chroot, working directory, user/group, limited capabilities, and command execution. Configurable OCI capabilities, seccomp, and resource controls remain planned.
7. **Networking and mounts** — outbound guest networking, one localhost TCP port mapping, and explicit file and directory shares work; file sources must share a filesystem with runtime storage.

The host-facing implementation stays in Zig. A small static C helper handles Linux process setup inside the guest and is embedded in the Rift binary; Objective-C remains a narrow macOS framework bridge.

Each VM is currently configured for 2 virtual CPUs and 256 MiB of guest RAM. Local Alpine command and detached nginx HTTP checks pass with this setting. It is a fixed limit for now, not a measurement of total host memory used.

## Planned execution path

`rift pull alpine` resolves the reference, authenticates anonymously to public registries or uses optional process-environment credentials for a private Bearer challenge, selects the host's Linux architecture, fetches each required blob, verifies its digest, and publishes verified data into the content-addressed store. `rift images` lists locally recorded references and their platform manifest digests. `rift rmi alpine` removes its local reference; `rift clean --yes` later reclaims blobs no other reference uses.

`rift run --rm alpine echo hello` assembles the image root, starts a Linux VM with the pinned Alpine kernel, mounts the read-only image through VirtioFS, starts the command on an ephemeral writable overlay, relays output, returns its exit status, and removes temporary host state. The guest uses `chroot` inside a VM with private PID/mount namespaces and reduced capabilities; complete OCI process controls remain planned.

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
- Directory shares default to read-only at the Virtualization.framework boundary; `:rw` grants the guest write access to the selected host directory.
- The container process retains only `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `FSETID`, `KILL`, `SETGID`, `SETUID`, and `NET_BIND_SERVICE`. The executor drops other capability bounds, sets `no_new_privs`, and closes inherited file descriptors. This is a fixed profile, not full OCI capability configuration.
- Treat the guest VM as a security boundary that still needs threat-model review and adversarial testing; a VM alone does not make all host integration safe.
- Keep registry credentials out of logs and repository files. Current private-registry credentials are process-environment only, sent to the HTTPS token realm advertised by the requested registry, and never persisted. Select a macOS credential-storage mechanism before adding persistent authentication.
- Validate the signing and entitlement path needed to create Virtualization.framework VMs before claiming public binary distribution. See Apple's [Linux VM guide](https://developer.apple.com/documentation/virtualization/running-linux-in-a-virtual-machine).
- `rift clean` must report what it will delete and preserve user data unless the user confirms the requested cleanup.
- Cache pruning verifies every recorded image manifest before deleting a valid unreferenced blob filename; pulls and root filesystem assembly hold the same cache lock.

## Constraints and proof

Apple silicon is the first target. OCI platform selection must be explicit; an `arm64` host must not silently run an `amd64` image through emulation.

Boot time, memory, binary size, image storage, and cleanup behavior will be measured before performance claims are published. Local parsing and storage tests cannot prove a real VM boot or container execution. Those need macOS integration runs.

## Milestones

1. **Done:** OCI references, indexes, manifests, and platform selection with tests.
2. **Done:** Streaming content-addressed SHA-256 storage with atomic publication and verification.
3. Public pulls, anonymous Bearer authentication, optional one-shot private-registry credentials, and local image metadata work. Persistent credential storage remains open.
4. Initial secure image layer extraction, regular-file hardlinks, image listing, and reference removal work; file ownership, timestamps, extended attributes, and special files remain.
5. A bootable Linux guest and a minimal command result path, proven locally.
6. Alpine and nginx run through the public CLI; basic detached lifecycle and plain logs work. Full OCI process settings and broader cleanup remain.
7. Outbound networking, one localhost TCP port mapping, and explicit read-only and writable file and directory volumes are proven locally. File sources must be on the runtime storage filesystem.
8. Reproducible runtime benchmarks and signed release distribution.
