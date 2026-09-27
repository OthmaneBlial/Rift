# Rift roadmap

This checklist follows the goals in the original project brief. `[x]` marks work implemented and verified within the stated scope; `[ ]` marks work still open. Partial support is split from the work that remains.

**Checklist progress: 53 of 68 items complete (78%).** This is verified roadmap progress; Rift remains an early source preview until the open release, compatibility, security, and adoption work is complete.

## Project foundation

- [x] Build the host runtime in Zig and target Apple Silicon macOS.
- [x] Publish the Apache-2.0 source repository on GitHub with `main` as the default branch.
- [x] Document the runtime architecture, security boundaries, current behavior, and limits.
- [x] Provide local source-build instructions and a standalone Rift executable with no Zig or Python runtime dependency.
- [x] Keep checks local-only as requested; `.github` has no hosted Actions workflow.
- [x] Add the project logo, GitHub Pages site, repository homepage, and 17 relevant topics.
- [x] Publish the `v0.1.0` source-preview tag and GitHub release.
- [ ] Sign and notarize public macOS binaries; publish release checksums.
- [ ] Provide a simple signed install and upgrade path, including Homebrew distribution.
- [ ] Refresh and verify the project website when the roadmap reaches 100%.

## CLI and image workflow

- [x] Provide `--help`, `version`, and `system info` commands.
- [x] Pull OCI images and list local images with `pull` and `images`.
- [x] Run foreground containers, including `--rm` cleanup.
- [x] Run detached containers and manage them with `ps`, `inspect`, `logs`, `stop`, `kill`, and `rm`.
- [x] Run non-interactive commands in detached containers with `exec` and preserve their exit status.
- [x] Remove local image references with `rmi` and inspect storage with `system df`.
- [x] Preview cleanup and require confirmation before deleting stale runtime data or unused image blobs.
- [ ] Add image-building support with `rift build`.

## OCI registries and local image store

- [x] Parse and normalize OCI image references, including Docker Hub shorthand.
- [x] Parse OCI manifests and indexes; select `linux/arm64` images explicitly.
- [x] Pull public images using registry Bearer authentication.
- [x] Verify downloaded blob digests and sizes before storing them.
- [x] Store image blobs by content digest and keep local image-reference metadata.
- [x] Pull uncached images automatically for foreground and detached runs.
- [x] Support environment credentials for private Bearer-token challenges; verify the Basic-to-Bearer flow with a local registry fixture.
- [x] Coordinate image pulls, runs, and cache pruning with a shared cache lock.
- [x] Reclaim unreferenced blobs while preserving blobs used by valid image records.
- [ ] Verify compatibility with more public registries and private registry providers.

## Linux guest and image filesystem

- [x] Boot Linux guests through Apple's Virtualization.framework bridge.
- [x] Download pinned guest boot files on first use and verify their SHA-256 digest.
- [x] Boot and exercise Alpine through local macOS VM checks.
- [x] Assemble image root filesystems from verified manifests and layer blobs.
- [x] Extract tar, gzip, and zstd layers; apply OCI whiteouts.
- [x] Apply regular-file hardlinks and reject unsafe targets.
- [x] Reject archive traversal, unsafe links, and writes redirected outside the image root.
- [x] Preserve directory modes and standard tar modification times.
- [x] Apply final directory metadata deepest-first so restrictive parents cannot block their children.
- [x] Smoke-test pulled Alpine BusyBox inside the VM through a read-only share.
- [x] Keep image files read-only and use a disposable writable overlay for container changes.
- [ ] Preserve OCI file ownership and groups during layer extraction.
- [x] Apply and test local PAX `path`, `linkpath`, and `size` overrides; recheck path and link safety after overrides.
- [ ] Preserve PAX `mtime`/`uid`/`gid` fields; honor global PAX headers.
- [ ] Support OCI extended attributes and file capabilities.
- [ ] Support required special files such as FIFOs and device nodes.

## Container behavior and isolation

- [x] Apply image `Entrypoint`, `Cmd`, and `Env`, with explicit environment overrides.
- [x] Apply image `WorkingDir` and the `-w` override.
- [x] Apply numeric or named image users, primary groups, and supplementary groups.
- [x] Give each workload private PID and mount namespaces, basic `/dev` and `/proc`, reduced capabilities, and `no_new_privs`.
- [x] Provide outbound networking and DNS.
- [x] Forward one TCP port from localhost into a container.
- [x] Mount explicit host directories and files, read-only by default with opt-in write access.
- [x] Run detached containers without a shared always-on daemon; keep one Rift worker per VM.
- [x] Send graceful stop signals, force-stop workloads after the timeout, and support immediate `kill`.
- [x] Retain detached logs and status until `rm`; clean foreground runtime state after normal completion.
- [x] Support non-interactive `exec` in the existing container namespaces, filesystem, environment, user, and working directory.
- [ ] Add interactive `exec` with stdin, TTY allocation, and signal cancellation.
- [ ] Implement broader OCI process and resource settings.
- [ ] Document the threat model and complete adversarial isolation review.
- [ ] Add structured log output.

## Verification, performance, and adoption

- [x] Run formatting, Zig unit tests, a `ReleaseSafe` build, guest preparation, and macOS integration checks through `scripts/check-local.sh`.
- [x] Verify real CLI runs, automatic image pulls, DNS, detached lifecycle, and container exit codes locally.
- [x] Verify nginx over the forwarded localhost port, including a detached run.
- [x] Verify read-only and writable file and directory volumes.
- [x] Verify private-registry authentication against a local registry fixture.
- [x] Provide a reproducible local benchmark script and methodology for cached Alpine startup, CLI startup, host-worker RSS, binary size, and logical store size.
- [x] Package and check a local release archive.
- [ ] Measure fresh guest setup, registry pull speed, total host and VM memory, and results across more Macs.
- [ ] Verify the complete first-use workflow on a clean Apple Silicon Mac without Docker: install, pull Alpine, run a command, serve nginx, and clean up.

Rift remains an early source preview. Local checks do not establish registry-wide compatibility, a complete Docker replacement, or a signed and notarized release.
