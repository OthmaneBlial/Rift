# Threat model

Rift accepts OCI images and container commands as untrusted. This document describes the intended boundaries and current controls; it is an initial threat model, not a security audit or a guarantee against VM escape. Rift remains an early source preview.

## Security goals

- Keep host files and credentials outside a container unless the user explicitly shares them.
- Keep each workload inside its own disposable Linux VM, with a read-only image base and an ephemeral writable layer.
- Reject malformed registry data and unsafe archive paths before they can redirect host writes.
- Make writable host access and inbound port forwarding explicit.

## Assumptions

- The macOS host, the signed-in user account, and the local Rift executable are trusted.
- The user chooses which registry, image reference, command, host paths, and ports to use.
- The macOS kernel, Apple's Virtualization.framework, the Linux guest kernel, and hardware virtualization behave as intended.

Rift does not defend against a compromised host or user account, a malicious process running as the same macOS user, physical access, or vulnerabilities in macOS, the hypervisor, or the guest kernel. OCI digests verify bytes against descriptors; they do not prove who published an image. Rift does not verify image signatures or publisher provenance.

## Assets and entry points

Protected assets include the host filesystem outside selected volumes, registry credentials, the local image cache, other Rift runtime state, and services reachable through the host network.

Untrusted inputs include registry challenges and responses, image indexes and manifests, image configuration, compressed layer archives, image-defined process settings, and container commands. Explicit volume targets and host port requests are also treated as untrusted input.

## Boundaries and current controls

- **Registry to host:** Remote registry traffic uses HTTPS. Plain HTTP is limited to loopback registries and their loopback token realms. Manifest and token bodies have size limits; each pull caps distinct uncached image blobs at 16 GiB, and blob downloads must match each descriptor's declared size and SHA-256 digest before atomic publication. Redirects are limited to HTTPS, and authorization headers are not forwarded across them. Basic credentials come from process environment variables, are sent to the HTTPS token realm advertised by the selected registry, are not persisted, and are never passed into the container environment. A registry controls its advertised token realm, so use credentials only with registries you trust.
- **Host store to image root:** Blobs are addressed by SHA-256 and verified again before root filesystem assembly. Extraction rejects absolute paths, `..` traversal, unsafe symlinks and hardlinks, and parent paths that resolve through symlinks. Whiteouts run before entries from their layer. Decompressed tar reads are capped at 8 GiB per layer and 32 GiB across the image in each extraction pass. Non-root UID/GID values from tar headers and PAX overrides are recorded in a 64 MiB manifest whose budget is enforced while entries are indexed; cumulative scans of the ownership index are capped at 10 million entries to bound repeated whiteout and replacement work. Guest ownership changes use no-follow path traversal. `metacopy=on` keeps owner changes metadata-only; image xattrs are not restored, so untrusted layer data cannot supply OverlayFS control xattrs. Image files remain read-only to the guest; container writes go to a disposable tmpfs overlay.
- **Guest to host:** Each run gets its own VM. The Linux executor creates private PID and mount namespaces, makes mounts private, uses `chroot`, mounts a minimal `/dev` and a read-only namespace-specific `/proc`, drops all but a fixed capability set, sets `no_new_privs`, and closes inherited descriptors. There is no separate network namespace inside the VM; VM separation is the workload boundary.
- **Host volumes:** Rift shares only paths named by the user. Volumes are read-only by default at the Virtualization.framework boundary; `:rw` grants write access to that selected path. Guest targets are walked without following symlinks. File volumes use a one-file share and require the source to share a filesystem with Rift's runtime storage.
- **Networking:** Guest networking uses Apple's NAT attachment. Rift forwards at most one requested TCP port and binds the host listener to `127.0.0.1`. This limits remote network exposure; other processes on the same Mac can still connect to that local port.
- **Guest assets and control:** The first-run Alpine ISO, kernel, and initramfs are pinned and checked with SHA-256. Guest control files use a separate VirtioFS share outside the container root. `rift exec` accepts a bounded NUL-delimited request and starts it in the existing container namespaces and filesystem.

## Known limits and review status

- There is no user namespace, seccomp filter, configurable capability profile, or complete OCI resource-control implementation. UID 0 in a workload is root in the guest's initial user namespace, with the fixed reduced capability set above; the VM remains the host boundary.
- Outbound guest networking is not filtered. Localhost port forwarding is explicit, but guest egress policy is not configurable.
- PAX fields other than `path`, `linkpath`, `size`, `mtime`, `uid`, and `gid`, OCI extended attributes, and file capabilities are not implemented. Image device nodes under `/dev` are ignored because the guest replaces that directory; FIFOs and special files outside `/dev` are unsupported.
- A pull refuses more than 16 GiB of distinct blobs missing from the verified cache; larger fully cached images remain usable. The cap is fixed today; add an opt-in override if real uncached workloads require more.
- Layer expansion has fixed per-layer and per-image-pass limits, but Rift does not enforce a filesystem free-space reservation or a wall-clock limit for extraction.
- Registry TLS and content digests do not replace publisher signature verification. Registry-wide provider compatibility is not established.
- The local `scripts/check-local.sh` suite exercises extraction, registry authentication fixtures, volumes, networking, process lifecycle, and real VM workflows on this Mac. It is not an adversarial escape test and does not establish safety across Macs or guest kernels.

The adversarial isolation review remains open. In particular, test the VM and guest integration boundaries against hostile image metadata, mount layouts, process behavior, network traffic, resource exhaustion, and concurrent host-file changes before making stronger security claims.
