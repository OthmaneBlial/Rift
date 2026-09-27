# Architecture

## Current state

Only `help`, `version`, and `system info` work. Rift cannot pull an image, start a VM, or execute a container. The rest of this document records the intended design and work still to prove.

## Runtime shape

Linux containers need a Linux kernel. On macOS, Rift will run workloads inside a small Linux virtual machine managed by Apple's Virtualization.framework. The host CLI will own the VM lifecycle; the Linux guest will own container namespaces and process execution.

The intended boundaries are:

1. **CLI** — argument parsing, diagnostics, and user-visible lifecycle.
2. **OCI client** — registry authentication, manifests and indexes, platform selection, blob download, and digest checks.
3. **Image store** — content-addressed blobs and image metadata under the user's Application Support directory.
4. **Layer installer** — safe tar extraction and root filesystem assembly, without following paths outside the image root.
5. **VM controller** — Linux kernel and initramfs boot, console, guest communication, and shutdown through Virtualization.framework.
6. **Guest agent** — a small Linux-side binary that mounts an image root, creates container isolation, starts commands, and reports exit status and logs.
7. **Networking and mounts** — outbound guest networking, requested port forwarding, and explicit host directory shares.

The host-facing implementation stays in Zig. The guest agent is also intended to be Zig. Apple framework calls should remain a narrow macOS-only boundary.

## Planned execution path

`rift pull alpine` should resolve the reference, authenticate to the registry, select the `linux/arm64` manifest on Apple silicon, fetch each required blob, verify its digest, and publish verified data into the content-addressed store.

`rift run --rm alpine echo hello` should assemble the image root, start a Linux VM with the matching kernel and guest agent, ask the guest to launch the command with container isolation, relay output and exit status, then stop the VM and remove only the temporary container state.

Image downloads and guest execution are separate milestones. A successful image pull must not be described as a runnable container.

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

Boot time, memory, binary size, image storage, and cleanup behavior will be measured before performance claims are published. CI can test portable parsing and storage code, but it cannot prove a real VM boot or container execution. Those need macOS integration runs.

## Milestones

1. OCI reference and manifest parsing with tests.
2. Authenticated registry pulls, platform selection, verified content-addressed storage.
3. Secure image layer extraction and image listing/removal.
4. A bootable Linux guest and a minimal guest command protocol.
5. One real Alpine command, followed by lifecycle, logs, and cleanup.
6. Outbound networking, port forwarding, and explicit volumes.
7. Reproducible runtime benchmarks and signed release distribution.
