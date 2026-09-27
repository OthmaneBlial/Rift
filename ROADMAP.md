# Rift roadmap

This cumulative checklist follows the goals in the original project brief. `[x]` means implemented and verified within the stated scope; `[ ]` means still open. A checked item records a milestone, not overall product readiness. Partial support and its limits are stated explicitly.

## Project foundation and distribution

- [x] Build the runtime in Zig for Apple Silicon macOS.
- [ ] Keep the architecture ready to support additional host architectures.
- [x] Publish the Apache-2.0 source repository on GitHub with `main` as the default branch.
- [x] Document the runtime architecture, security boundaries, current behavior, and limits.
- [x] Provide local source-build instructions and a standalone Rift executable with no Zig or Python runtime dependency.
- [x] Keep the runtime independent of Docker Engine and Docker CLI, with no permanent host daemon.
- [x] Keep checks local-only as requested; `.github` has no hosted Actions workflow.
- [x] Maintain the product README with setup, examples, current status, and limitations.
- [x] Add the project logo, GitHub Pages site, repository homepage, and 17 relevant topics.
- [x] Publish the semantic `v0.1.0` source-preview tag and release notes.
- [ ] Sign and notarize public macOS binaries; publish release assets and checksums.
- [ ] Provide a simple signed install and upgrade path, including Homebrew distribution.
- [ ] Refresh and verify the project website when the roadmap reaches 100%.

## CLI and image workflow

- [x] Provide `--help`, `version`, and `system info` commands.
- [x] Pull OCI images and list local images with `pull` and `images`.
- [x] Run foreground containers, including `--rm` cleanup.
- [x] Apply image `Entrypoint`, `Cmd`, and `Env`, with explicit environment overrides.
- [x] Apply image `WorkingDir` and the `-w` override.
- [x] Apply numeric or named image users, primary groups, and supplementary groups.
- [x] Run detached containers and manage them with `ps`, `inspect`, `logs`, `stop`, `kill`, and `rm`.
- [x] Run non-interactive commands in detached containers with `exec` and preserve their exit status.
- [x] Remove local image references with `rmi` and inspect storage with `system df`.
- [x] Preview cleanup and require confirmation before deleting stale runtime data or unused image blobs.
- [ ] Add image-building support with `rift build`.
- [ ] Add interactive `exec` with stdin, TTY allocation, and signal cancellation.
- [ ] Implement broader OCI process and resource settings.
- [ ] Review command help and error messages across the supported CLI for clear, predictable use.
- [ ] Add structured log output.

## OCI registries and local image store

- [x] Parse and normalize OCI image references, including Docker Hub shorthand.
- [x] Parse OCI manifests and indexes; select `linux/arm64` images explicitly.
- [x] Pull public images using registry Bearer authentication.
- [x] Support environment credentials for private Bearer-token challenges; verify the Basic-to-Bearer flow with a local registry fixture.
- [x] Verify downloaded blob digests and sizes before storing them.
- [x] Store image blobs by content digest, deduplicate shared content, and keep local image-reference metadata.
- [x] Pull uncached images automatically for foreground and detached runs.
- [x] Coordinate image pulls, runs, and cache pruning with a shared cache lock.
- [x] Reclaim unreferenced blobs while preserving blobs used by valid image records.
- [x] Cap each pull at 16 GiB of distinct image blobs missing from the verified cache.
- [ ] Verify compatibility with more public registries and private registry providers.

## Linux guest and image filesystem

- [x] Boot Linux guests through Apple's Virtualization.framework bridge.
- [x] Download pinned guest boot files on first use and verify their SHA-256 digest.
- [x] Boot and exercise Alpine through local macOS VM checks.
- [x] Assemble image root filesystems from verified manifests and layer blobs.
- [x] Extract tar, gzip, and zstd layers; apply OCI whiteouts.
- [x] Cap decompressed layer data at 8 GiB per layer and 32 GiB per image extraction pass.
- [x] Apply regular-file hardlinks and reject unsafe targets.
- [x] Reject archive traversal, unsafe links, and writes redirected outside the image root.
- [x] Preserve directory modes and standard tar modification times.
- [x] Apply final directory metadata deepest-first so restrictive parents cannot block their children.
- [x] Apply and test local PAX `path`, `linkpath`, and `size` overrides; recheck path and link safety after overrides.
- [x] Apply local and global PAX `mtime` values, including fractional and negative timestamps.
- [x] Smoke-test pulled Alpine BusyBox inside the VM through a read-only share.
- [x] Keep image files read-only and use a disposable writable overlay for container changes.
- [ ] Preserve OCI file ownership and groups during layer extraction.
- [ ] Preserve PAX `uid`/`gid` and global PAX fields beyond `mtime`.
- [ ] Support OCI extended attributes and file capabilities.
- [ ] Support required special files such as FIFOs and device nodes.
- [ ] Reduce guest disk footprint and optimize guest startup and shutdown based on measurements.
- [ ] Evaluate guest reuse between container executions while preserving workload isolation and cleanup.

## Container behavior, networking, and isolation

- [x] Give each workload private PID and mount namespaces, basic `/dev` and `/proc`, reduced capabilities, and `no_new_privs`.
- [x] Provide outbound networking and DNS.
- [x] Forward one TCP port from localhost into a container.
- [x] Mount explicit host directories and files, read-only by default with opt-in write access.
- [x] Run detached containers without a shared always-on daemon; keep one Rift worker per VM.
- [x] Send graceful stop signals, force-stop workloads after the timeout, and support immediate `kill`.
- [x] Retain detached logs and status until `rm`; clean foreground runtime state after normal completion.
- [x] Document security assets, trust boundaries, current controls, and known limits.
- [ ] Complete adversarial isolation review and test host/guest escape assumptions.
- [ ] Measure and improve communication between macOS and the Linux guest where it affects startup or runtime cost.

## Verification, performance, and adoption

- [x] Run formatting, Zig unit tests, a `ReleaseSafe` build, guest preparation, and macOS integration checks through `scripts/check-local.sh`.
- [x] Verify real CLI runs, automatic image pulls, DNS, detached lifecycle, and container exit codes locally.
- [x] Verify nginx over the forwarded localhost port, including a detached run.
- [x] Verify read-only and writable file and directory volumes.
- [x] Verify private-registry authentication against a local registry fixture.
- [x] Provide a reproducible local benchmark script and methodology for cached Alpine startup, CLI startup, host-worker RSS, binary size, and logical store size.
- [x] Package and check a local release archive.
- [x] Verify the source-built Alpine and Nginx workflow in a fresh Rift home on this Apple Silicon Mac without Docker, including first guest setup, localhost HTTP, lifecycle, and cache cleanup.
- [x] Record one fresh-home workflow and one cached benchmark sample with scope and limitations in `docs/BENCHMARKS.md`.
- [ ] Record end-to-end cold and warm startup, guest boot time, installation footprint, image pull/cache behavior, disk usage, and total host-plus-VM memory.
- [ ] Repeat the performance measurements across more Macs.
- [ ] Verify the complete first-use workflow on a clean Apple Silicon Mac without Docker: install, pull Alpine, run a command, serve nginx, and clean up.

Rift remains an early source preview. Local checks do not establish registry-wide compatibility, a complete Docker replacement, or a signed and notarized release.
