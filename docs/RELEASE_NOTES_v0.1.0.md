# Rift v0.1.0 — Apple Silicon source preview

Rift is an experimental Zig runtime that pulls OCI images and runs Linux commands inside disposable VMs managed by Apple's Virtualization.framework. This preview targets macOS on Apple Silicon.

## Try it from source

```sh
brew install zig
git clone https://github.com/OthmaneBlial/Rift.git
cd Rift
zig build -Doptimize=ReleaseSafe
zig build test
```

The binary is written to `zig-out/bin/rift`. The first `run` fetches the pinned Alpine guest ISO, verifies its SHA-256, and installs the guest boot files.

```sh
rift run --rm alpine echo hello
rift run -d -p 8080:80 nginx
rift ps
rift logs <container-id>
rift stop <container-id>
rift rm <container-id>
```

Rift also supports verified image pulls, environment and working-directory overrides, image users and groups, explicit file and directory volumes, one localhost TCP mapping, `kill`, `rmi`, disk reporting, and confirmed cache cleanup.

## Limits

Rift is early-stage and is not a Docker replacement yet. OCI ownership, PAX metadata, extended attributes, special files, broader process isolation, and structured logs remain unfinished. Port forwarding supports one TCP port per run. File-volume sources must share a filesystem with Rift's runtime storage. Private-registry provider compatibility is not yet validated beyond the local fixture.

This release has no macOS binary asset. Rift does not yet have a Developer ID signed and notarized public download; macOS Gatekeeper rejects the locally ad-hoc-signed archive. Building from source is the supported installation path.

All checks run locally; GitHub Actions remains disabled by project direction. See the [README](https://github.com/OthmaneBlial/Rift/blob/main/README.md), [architecture](ARCHITECTURE.md), and [benchmark method](BENCHMARKS.md) for the current state and evidence.
