# Rift roadmap

This roadmap carries the original plan forward from the first project commit. `[x]` means delivered and verified within the stated scope; `[ ]` means work remains. The local completion score counts only sections 1–7 and excludes the separate external gates below.

**Locally verifiable scope: 100% (93/93).** This is not a claim of broad compatibility, an independent security audit, or a signed public release.

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

## 4. Build the everyday container workflow

- [x] Pull images with `rift pull` and list them with `rift images`.
- [x] Run foreground containers, including `--rm` cleanup.
- [x] Run detached containers and manage them with `ps`, `inspect`, `logs`, `stop`, `kill`, and `rm`.
- [x] Run non-interactive commands with `exec` and preserve their exit status.
- [x] Stream detached `exec` output while the command runs.
- [x] Stream host stdin through opt-in `exec -i` while the command runs.
- [x] Remove image references with `rmi` and inspect storage with `system df`.
- [x] Send graceful stop signals, force-stop after the timeout, and support immediate `kill`.
- [x] Retain detached logs and status until `rm`; clean foreground state after normal completion.
- [x] Add interactive `exec` with stdin, TTY allocation, resize forwarding, and signal cancellation.
- [x] Build and run an OCI image from one `FROM` and local file or directory `COPY` instructions.
- [x] Apply `ENV`, `USER`, `WORKDIR`, `ENTRYPOINT`, and `CMD` to built image configuration; create a missing configured working directory in the disposable run overlay at launch.
- [x] Execute single-stage Dockerfile `RUN` commands in order against preceding image state; fail builds when a command exits nonzero.
- [x] Support multiple Dockerfile build stages, named or indexed `COPY --from`, and `FROM` inheritance from earlier stages.
- [x] Honor validated OCI image `StopSignal` values for detached shutdown, with Dockerfile `STOPSIGNAL` support.
- [x] Configure the private guest VM's CPU count and RAM per run, with host-supported range checks and documented defaults; these set guest capacity rather than per-process quotas.
- [x] Disable the guest VM network adapter per run; verify no guest interface or IPv4 default route.
- [x] Apply an optional cgroup v2 task cap with `--pids-limit`; reserve one task for the PID namespace supervisor.
- [x] Provide reduced and empty capability profiles with `--cap-profile default|none`.
- [x] Apply optional cgroup v2 CPU and memory quotas per container with `--cpu-limit` and `--memory-limit`, including `exec` processes.
- [x] Add repeatable per-capability `--cap-add` and `--cap-drop` controls for Linux capability names; verify default-profile removal, explicit root and non-root grants, and detached `exec` propagation.
- [x] Review help and error messages across supported commands for clear, predictable use.
- [x] Add binary-safe JSON Lines for detached logs with container ID, combined stream, and byte offsets; preserve output bytes as base64 data.

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
- [x] Preserve global PAX `path`, `linkpath`, and `size` overrides, including local precedence and empty-value resets.
- [x] Restore PAX xattrs on files and nested directories, including binary values, local/global precedence, and legacy `security.capability`; verify in Alpine.
- [x] Expose OCI root-directory xattrs at `/` by copying them into the private upper layer; verify in Alpine.
- [x] Extract OCI FIFO entries as named pipes with preserved mode and ownership.
- [x] Recreate OCI character and block device nodes outside runtime-managed `/dev` inside the disposable guest overlay, preserving device numbers, owner, mode, and modification time; Unix-domain socket entries remain unsupported.
- [x] Use local measurements to reduce guest disk footprint and improve offline startup and shutdown: APFS shares immutable base initramfs data, `--network none` skips network setup, and graceful-stop median fell from 1,148.3 ms to 320.0 ms. Three current cached runs measured a 1.13-second median launch; no further default-startup improvement was established. See `docs/BENCHMARKS.md`.
- [x] Evaluate guest reuse while preserving workload isolation and cleanup. Keep one VM per run: a warm guest would share its kernel across workloads, while the measured VM-start stage is about 435 ms. See `docs/ARCHITECTURE.md`.

## 6. Verify reliability, security, and performance

- [x] Run formatting, Zig unit tests, a `ReleaseSafe` build, guest preparation, and macOS integration checks locally.
- [x] Verify real CLI runs, automatic image pulls, DNS, detached lifecycle, and exit codes.
- [x] Verify Nginx over the forwarded localhost port, including a detached run.
- [x] Verify read-only and writable file and directory volumes.
- [x] Verify private-registry authentication against a local fixture.
- [x] Provide a reproducible local benchmark script and methodology.
- [x] Package and check a local release archive.
- [x] Verify a fresh Rift home on this Apple Silicon Mac without Docker: first guest setup, Alpine, Nginx HTTP, lifecycle, and cache cleanup.
- [x] Record first-cached and subsequent startup, fresh-home pulls, logical store size, and worker-plus-VM process memory with scope and limitations.
- [x] Verify a UID 0 workload inherits `no_new_privs` and cannot mount a new filesystem.
- [x] Verify file and directory volume targets reject paths beneath image symlinks.
- [x] Complete the locally verifiable isolation review: test volume symlink/nesting boundaries, disabled networking, localhost forwarding and idle-client cleanup, process/capability limits, resource limits, and temporary-state cleanup. Unit tests cover staged volume replacement. Remaining framework races and VM-boundary questions are listed under external gates and in `docs/THREAT_MODEL.md`.
- [x] Measure VM-start-to-guest-control-ready latency on Apple M2; record timer endpoints and host polling resolution.
- [x] Measure the Homebrew v0.1.2 keg and first-run guest assets in a fresh Rift home on Apple M2.
- [x] Capture whole-Mac physical memory, free-page, and memory-pressure snapshots before VM startup and with an idle guest on Apple M2.
- [x] Measure warm detached `rift exec /bin/true` end-to-end overhead on Apple M2; document that the sample includes the host CLI, guest control request/response, supervisor dispatch, and command startup rather than claiming isolated IPC latency.

## 7. Ship a straightforward public release

- [x] Provide a Homebrew source-build install path for Apple Silicon; verify clean-HOME installation and use without Docker.
- [x] Verify first-use-to-clean behavior in a fresh temporary `HOME` on this Apple Silicon Mac without Docker: guest setup, Alpine and Nginx runs, detached lifecycle, and cache cleanup. Homebrew v0.1.2 separately passed its formula check and clean-`HOME` run. See `docs/BENCHMARKS.md`.

## External verification gates

These need another host, provider credentials, Apple signing credentials, an independent reviewer, or publication to the public Pages repository. They are excluded from the local completion score and remain unchecked.

- [ ] Extend host and guest architecture support beyond Apple Silicon macOS and `linux/arm64`.
- [ ] Verify private registry providers beyond the local Bearer-auth fixture.
- [ ] Repeat performance measurements across more Macs.
- [ ] Run the full runtime workflow on macOS 12 to verify the oldest declared host version.
- [ ] Sign and notarize macOS binaries; publish release assets and checksums.
- [ ] Refresh and verify the live GitHub Pages site after the local scope is complete.
- [ ] Complete an independent adversarial assessment of the VM boundary and residual host/guest races.

Rift remains an early source preview. Local checks do not establish registry-wide compatibility, a complete Docker replacement, or a signed and notarized release.
