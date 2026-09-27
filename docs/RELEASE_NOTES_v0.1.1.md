# Rift v0.1.1 — Apple Silicon source preview

Rift v0.1.1 is a source preview for Apple Silicon Macs. It adds anonymous Amazon ECR Public support, handles image device entries under the runtime-managed `/dev`, and targets macOS 12.0 instead of the build host's OS version.

## Install with Homebrew

```sh
brew install OthmaneBlial/rift/rift
```

The Homebrew formula builds Rift from source. Homebrew installs Zig as a build dependency. The installed Rift executable does not need Zig at runtime.

## Verify locally

The full `./scripts/check-local.sh` suite passed on Apple Silicon with macOS 26.6 and Zig 0.16.0. Anonymous ARM64 pull and execution passed for Docker Hub and Amazon ECR Public. Private Basic-to-Bearer authentication passed against a local registry fixture.

## Limits

This preview has no Developer ID-signed or notarized binary. The full runtime workflow has not yet been tested on macOS 12. Image ownership, extended attributes, FIFOs, interactive `exec`, broader OCI process controls, and compatibility with additional registries remain open.
