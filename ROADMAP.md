# Rift roadmap

This roadmap carries the original plan forward from the first project commit. `[x]` means delivered and verified within the stated scope; `[ ]` means work remains. Completed work stays checked as Rift grows. No dates or completion percentage are implied.

## 1. Start the project

- [x] Create the public `OthmaneBlial/Rift` repository and use `main` as the default branch.
- [x] Choose Zig, Apache-2.0, Apple Silicon macOS, and a Docker-free user experience.
- [x] Add the complete license, `.gitignore`, source-build instructions, and local project checks.
- [x] Build the host CLI in Zig with `--help`, `version`, and `system info`.
- [x] Set the default Apple Silicon deployment target to macOS 12.0, the minimum required by the directory-sharing APIs.
- [x] Document the architecture, security boundaries, supported behavior, and limitations.
- [x] Keep local checks in `scripts/check-local.sh`; leave GitHub Actions disabled as requested.
- [x] Write the README with working setup steps, examples, status, and limitations.
- [x] Link this cumulative roadmap from the README.
- [x] Add the project logo, 17 repository topics, and the first GitHub Pages site.
- [x] Publish the Apache-2.0 `v0.1.0` source-preview tag and release notes.

## 2. Boot Linux and run the first real container

- [x] Use Apple's `Virtualization.framework` to boot a Linux guest on Apple Silicon.
- [x] Download pinned guest boot files on first use and verify their SHA-256 digest.
- [x] Run real Alpine commands in the guest without Docker Engine, Docker CLI, Docker Desktop, or a permanent host daemon.
- [x] Build a standalone Rift executable without Zig or Python runtime dependencies.
- [x] Assemble image root filesystems from verified OCI manifests and layer blobs.
- [x] Keep image files read-only and use a disposable writable overlay for container changes.
- [x] Give each workload private PID and mount namespaces, basic `/dev` and `/proc`, reduced capabilities, and `no_new_privs`.
- [x] Apply image `Entrypoint`, `Cmd`, `Env`, `WorkingDir`, user, primary group, and supplementary groups.
- [x] Support explicit environment overrides and the `-w` working-directory override.
- [ ] Extend the host and guest architecture support beyond Apple Silicon macOS and `linux/arm64`.

## 3. Pull and store OCI images safely

- [x] Parse and normalize OCI image references, including Docker Hub shorthand.
- [x] Parse OCI manifests and indexes and select `linux/arm64` images explicitly.
- [x] Pull public images with registry Bearer authentication.
- [x] Verify downloaded blob digests and sizes before storing them.
- [x] Store blobs by content digest, deduplicate shared content, and keep image-reference metadata.
- [x] Pull uncached images automatically for foreground and detached runs.
- [x] Support environment credentials for private Bearer-token challenges; verify Basic-to-Bearer with a local registry fixture.
- [x] Verify an anonymous ARM64 pull and container run from Amazon ECR Public (`amazonlinux:latest`).
- [x] Coordinate pulls, runs, and cache pruning with a shared cache lock.
- [x] Preview cleanup and reclaim unreferenced blobs while preserving valid image records.
- [x] Cap each pull at 16 GiB of distinct image blobs missing from the verified cache.
- [x] Verify anonymous ARM64 pulls from GHCR, Quay, and Google GCR using public image samples.
- [ ] Verify private registry providers beyond the local Bearer-auth fixture.

## 4. Build the everyday container workflow

- [x] Pull images with `rift pull` and list them with `rift images`.
- [x] Run foreground containers, including `--rm` cleanup.
- [x] Run detached containers and manage them with `ps`, `inspect`, `logs`, `stop`, `kill`, and `rm`.
- [x] Run non-interactive commands with `exec` and preserve their exit status.
- [x] Remove image references with `rmi` and inspect storage with `system df`.
- [x] Send graceful stop signals, force-stop after the timeout, and support immediate `kill`.
- [x] Retain detached logs and status until `rm`; clean foreground state after normal completion.
- [ ] Add interactive `exec` with stdin, TTY allocation, and signal cancellation.
- [ ] Add image building with `rift build`.
- [ ] Implement broader OCI process and resource settings.
- [x] Review help and error messages across supported commands for clear, predictable use.
- [ ] Add structured log output.

## 5. Complete image filesystem and host integration

- [x] Extract tar, gzip, and zstd layers and apply OCI whiteouts.
- [x] Cap decompressed data at 8 GiB per layer and 32 GiB per image extraction pass.
- [x] Apply regular-file hardlinks and reject unsafe targets.
- [x] Reject archive traversal, unsafe links, and writes redirected outside the image root.
- [x] Preserve directory modes and standard tar modification times.
- [x] Apply directory metadata deepest-first so restrictive parents do not block their children.
- [x] Apply local PAX `path`, `linkpath`, and `size` overrides, then recheck path and link safety.
- [x] Apply local and global PAX `mtime`, including fractional and negative timestamps.
- [x] Ignore image character and block device entries below `/dev`; the guest replaces `/dev` with its restricted device filesystem.
- [x] Provide outbound networking and DNS.
- [x] Forward one TCP port from localhost into a container.
- [x] Mount explicit host files and directories read-only by default, with opt-in write access.
- [x] Preserve OCI file ownership and groups from tar headers and local/global PAX `uid`/`gid`; verify non-root file access in a VM.
- [ ] Preserve remaining global PAX fields and support OCI extended attributes and file capabilities.
- [ ] Support FIFOs and special files outside runtime-managed `/dev`.
- [ ] Reduce guest disk footprint and optimize startup and shutdown using measurements.
- [ ] Evaluate guest reuse while preserving workload isolation and cleanup.

## 6. Verify reliability, security, and performance

- [x] Run formatting, Zig unit tests, a `ReleaseSafe` build, guest preparation, and macOS integration checks locally.
- [x] Verify real CLI runs, automatic image pulls, DNS, detached lifecycle, and exit codes.
- [x] Verify Nginx over the forwarded localhost port, including a detached run.
- [x] Verify read-only and writable file and directory volumes.
- [x] Verify private-registry authentication against a local fixture.
- [x] Provide a reproducible local benchmark script and methodology.
- [x] Package and check a local release archive.
- [x] Verify a fresh Rift home on this Apple Silicon Mac without Docker: first guest setup, Alpine, Nginx HTTP, lifecycle, and cache cleanup.
- [x] Record fresh-home and cached benchmark samples with scope and limitations.
- [x] Verify a UID 0 workload inherits `no_new_privs` and cannot mount a new filesystem.
- [x] Verify file and directory volume targets reject paths beneath image symlinks.
- [ ] Complete an adversarial review of host/guest isolation assumptions; ownership-index work is now bounded, while volume races, mount layouts, workload behavior, network exposure, and VM-boundary review remain.
- [ ] Measure cold and warm startup, guest boot time, install footprint, image pull/cache behavior, disk usage, and total host-plus-VM memory.
- [ ] Repeat performance measurements across more Macs.
- [ ] Run the full runtime workflow on macOS 12 to verify the oldest declared host version.
- [ ] Verify the full install-to-clean workflow on a clean Apple Silicon Mac without Docker.
- [ ] Measure host/guest communication where it affects startup or runtime cost.

## 7. Ship a straightforward public release

- [ ] Sign and notarize macOS binaries; publish release assets and checksums.
- [x] Provide a Homebrew source-build install path for Apple Silicon; verify clean-HOME installation and use without Docker.
- [ ] Refresh and verify the GitHub Pages site when all roadmap work is complete.

Rift remains an early source preview. Local checks do not establish registry-wide compatibility, a complete Docker replacement, or a signed and notarized release.
