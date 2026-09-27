# Rift v0.1.2 — Apple Silicon source preview

Rift v0.1.2 preserves OCI file ownership from tar headers and local or global PAX `uid`/`gid` fields. It applies non-root owners inside the disposable guest overlay, including ownership of the root directory, files, directories, symlinks, and hardlinks. A bounded manifest and no-follow path traversal keep image ownership changes inside the guest root. OverlayFS metadata-only copy-up avoids copying image file contents just to change owners. Image xattrs remain unsupported.

## Install with Homebrew

```sh
brew install OthmaneBlial/rift/rift
```

The formula builds Rift from the tagged source and installs Zig as a build dependency. The installed Rift executable does not need Zig.

## Verify locally

The local Apple Silicon suite covers formatting, unit tests, a `ReleaseSafe` build, VM and networking checks, container lifecycle, registry authentication, volumes, and an OCI ownership fixture. A Docker Hub `redis:alpine` run verified its `999:1000` `/data` ownership and a write as the `redis` user, without Docker installed.

## Limits

This preview has no Developer ID-signed or notarized binary. The full runtime workflow has not yet been tested on macOS 12. Interactive `exec`, remaining global PAX fields, extended attributes, FIFOs, special files, broader OCI process controls, and compatibility with additional registries remain open.
