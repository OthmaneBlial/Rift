# Rift v0.1.0 draft

First Apple Silicon preview. Rift is a Zig CLI that pulls public OCI images and runs Alpine and nginx in short-lived Linux VMs through macOS Virtualization.framework. No Docker installation or permanent daemon is required.

Working commands: `pull`, `images`, foreground and detached `run`, one localhost TCP port mapping, `ps`, `logs`, `stop`, `rm`, `system info`, `system df`, and `clean`. On the first run, Rift fetches a pinned Alpine ISO, verifies it with SHA-256, and installs its guest boot files. Detached nginx served its welcome page through `-p 8080:80` in local checks. The release archive contains one executable, the license, and the README; `SHA256SUMS` verifies the archive.

This is an early preview. Apple Silicon only; anonymous public registry access only; pull images before running them; one TCP port mapping; no volumes, `exec`, image removal, or complete OCI process isolation. Images requesting a non-root user or working directory other than `/` are rejected. `stop` currently forces VM shutdown. `clean` removes only abandoned runtime staging after an explicit `--yes`; it keeps image blobs and logs.

**Distribution limit:** The binary is ad-hoc signed with the Virtualization entitlement, but no Developer ID identity is available on the build Mac. Gatekeeper rejects this archive. Build locally with Zig 0.16.0 and `zig build -Doptimize=ReleaseSafe` until a Developer ID signed and notarized release is available. This draft must not be presented as a notarized download.

All checks ran locally, with GitHub Actions disabled: Zig tests, Alpine foreground and detached lifecycle, DNS and localhost forwarding, first-use guest bootstrap, an nginx HTTP 200 response, archive extraction and signature verification, and execution of Alpine from the unpacked archive. Benchmark method and one Apple M2 sample are in [BENCHMARKS.md](https://github.com/OthmaneBlial/Rift/blob/main/docs/BENCHMARKS.md).
