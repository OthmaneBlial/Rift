# Rift roadmap

This is the running checklist from Rift’s first CLI and OCI work through a dependable release. `[x]` means implemented and verified, locally where applicable; `[ ]` means still open.

## Project foundation

- [x] Build the Zig CLI with help, version, and host information.
- [x] Add the Apache-2.0 license and architecture documentation.
- [x] Run formatting, builds, unit tests, and macOS checks locally with `scripts/check-local.sh`.
- [x] Keep CI local-only as requested; no GitHub Actions workflows.
- [x] Add the repository logo, project topics, and first GitHub Pages website.
- [x] Create the `v0.1.0` source-preview tag and release.

## OCI images and local storage

- [x] Parse OCI image references, indexes, and manifests; select and test `linux/arm64` images.
- [x] Stream image blobs into content-addressed storage with SHA-256 and size verification.
- [x] Pull public OCI images with Bearer authentication and platform selection.
- [x] Support optional environment credentials for private Bearer challenges (unit-tested; provider integration remains open).
- [x] Automatically pull uncached public images for foreground and detached runs.
- [x] Store and list local image metadata.
- [x] Report local disk usage by storage category.
- [x] Remove image references with `rmi` and reclaim unreferenced blobs with `clean --yes`.
- [ ] Verify compatibility with more public registries and private registry providers.

## Linux guest and image filesystem

- [x] Boot a local Linux guest through Apple’s Virtualization.framework bridge.
- [x] Download and verify pinned guest boot files on first run.
- [x] Safely extract tar, gzip, and zstd layers, including OCI whiteouts and regular-file hardlinks.
- [x] Assemble a local root filesystem from verified image manifests and layers.
- [x] Preserve standard tar modification times for files, symlinks, and directories.
- [x] Smoke-test execution of pulled Alpine BusyBox inside the VM through a read-only share.
- [ ] Support OCI ownership, PAX metadata, extended attributes, and required special files.

## Container execution and lifecycle

- [x] Run basic foreground OCI commands through the public CLI.
- [x] Apply image Entrypoint, Cmd, and Env defaults, with `-e` overrides.
- [x] Apply absolute image `WorkingDir`, `-w`, numeric or named `User`, and supplementary groups.
- [x] Use private PID and mount namespaces, basic `/dev` and `/proc`, reduced capabilities, and `no_new_privs`.
- [ ] Implement broader OCI process settings and review isolation against a documented threat model.
- [x] Add non-interactive `rift exec` for detached containers; preserve arguments, environment, working directory, PID namespace, filesystem, and exit status.
- [ ] Add interactive exec stdin/TTY support and signal cancellation.
- [x] Provide outbound NAT and DNS for foreground commands.
- [x] Forward one localhost TCP port for foreground commands.
- [x] Run detached containers; provide `ps`, `inspect`, plain `logs`, graceful `stop`, force `kill`, and `rm`.
- [x] Mount explicit read-only and writable directory volumes.
- [x] Mount explicit read-only and writable file volumes.
- [x] Preview and confirm cleanup of abandoned runtime staging.
- [x] Preview and prune unreferenced image blobs under a cache lock.
- [ ] Add structured log output.

## Verification, release, and adoption

- [x] Verify the nginx welcome page over a forwarded localhost port, including a detached run.
- [x] Remove foreground temporary state after normal completion; retain detached logs and status until `rift rm`.
- [x] Package and check a local release archive.
- [ ] Add reproducible measurements for startup, idle memory, binary size, and storage.
- [ ] Establish Developer ID signing and notarization, then publish signed binaries and checksums.
- [ ] Provide a straightforward install and upgrade path for signed releases.
- [ ] Verify the complete install-to-clean workflow on a clean Apple Silicon Mac without Docker.
- [ ] Refresh and verify the GitHub Pages website when the project reaches 100%.

Rift is still an early source preview, not a Docker replacement. A passing local check does not establish registry-wide compatibility or a signed, notarized release.
