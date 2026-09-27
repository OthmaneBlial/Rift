<div align="center">
  <img src="site/favicon.svg" alt="Rift logo" width="88" height="88">
  <h1>Rift</h1>
  <p><strong>Lightweight Linux containers for macOS.</strong></p>
  <p>No Docker. No daemon. No Docker Desktop. Just one binary.</p>
  <p>
    <a href="https://othmaneblial.github.io/Rift/">Website</a> ·
    <a href="https://github.com/OthmaneBlial/Rift/releases">Releases</a> ·
    <a href="docs/ARCHITECTURE.md">Architecture</a>
  </p>
</div>

Rift is an experimental OCI container runtime for Apple Silicon Macs. It runs Linux workloads in Apple's Virtualization.framework and builds with Zig. The current [v0.1.2 release](https://github.com/OthmaneBlial/Rift/releases/tag/v0.1.2) is a source preview; public notarized binaries are not available yet.

## Quick start

Install Rift with Homebrew:

```sh
brew install OthmaneBlial/rift/rift
```

Homebrew builds Rift from source and installs Zig as a build dependency. Zig is not needed to run Rift.

Run a container:

```sh
rift pull alpine
rift run --rm alpine echo "Hello from Rift"
```

The first run downloads and verifies the pinned Alpine guest files. Image pulls and first-run setup need network access.

## Run a small service

```sh
rift pull nginx
id=$(rift run -d -p 8080:80 nginx)
curl http://127.0.0.1:8080
rift ps
rift logs "$id"
rift exec "$id" /bin/sh -c 'echo online'
rift stop "$id"
rift rm "$id"
```

Rift forwards one TCP port per run. Detached containers keep their logs and status until removed. `exec` runs a non-interactive command with the container's environment and working directory; output appears when it exits.

## What works

- Pull `linux/arm64` images from Docker Hub, Amazon ECR Public, `registry.k8s.io`, GitHub Container Registry, Quay, and Google GCR. [Registry checks](docs/REGISTRIES.md) list the tested image samples; private Bearer-token support is verified against a local fixture.
- Run foreground and detached containers with image entrypoint, command, environment, working directory, user, and supplementary groups.
- Use outbound networking, DNS, one localhost port mapping, and explicit file or directory volumes.
- Inspect and manage detached containers with `ps`, `inspect`, `logs`, non-interactive `exec`, `stop`, `kill`, and `rm`.
- Check storage with `system df` and preview or remove unused data with `clean`.

For private registries, set `RIFT_REGISTRY_USERNAME` and `RIFT_REGISTRY_PASSWORD` for the pull. Rift does not store them.

Example overrides:

```sh
mkdir -p data
rift run -w /tmp alpine pwd
rift run -e MESSAGE=hello alpine sh -c 'echo "$MESSAGE"'
rift run -v "$PWD/data:/data:rw" alpine sh -c 'echo saved > /data/example'
```

Host environment variables are not copied into containers. Volumes are read-only by default; `:rw` gives the container write access to the selected host path. File-volume sources must share a filesystem with Rift's runtime storage.

## Benchmarks

One cached run on an Apple M2 with macOS 26.6 and Zig 0.16.0 (`ReleaseSafe`, commit `c5c3dd6`):

| Metric | Result |
| --- | ---: |
| First cached Alpine launch | 1,167 ms |
| Subsequent launches, median of 5 | 1,158 ms |
| VM start to guest control ready | 437 ms |
| Detached start to workload-ready marker | 1,734 ms |
| Executable size | 1,730,064 bytes |
| Worker and VM-service process footprint after ready | 152.3 MiB |

The image and guest files were cached. VM-start timing ends when the guest mounts its rootfs and control shares; it excludes guest overlay setup and workload startup. The process footprint excludes kernel and other system memory. Homebrew v0.1.2's installed keg uses 1,724 KiB; its first-run guest assets use 44.3 MiB separately from the image cache. These are single-machine samples, not a Docker comparison. See [benchmark method and history](docs/BENCHMARKS.md).

## Requirements and limits

- macOS 12 or newer on Apple Silicon.
- Zig 0.16 or newer for manual source builds; Homebrew installs the build dependency automatically.
- One lightweight Linux VM per run; the current guest limit is 2 CPUs and 256 MiB RAM.
- One TCP port mapping per run; up to 16 explicit file or directory volumes.
- Each pull is capped at 16 GiB of distinct image blobs not already verified in the local cache.
- Each layer is capped at 8 GiB decompressed; all image layers together are capped at 32 GiB per extraction pass.
- `exec` does not support interactive stdin or TTY allocation yet.
- Remaining global PAX fields, extended attributes, FIFOs, and special files outside `/dev` are unsupported. Rift preserves tar and PAX `uid`/`gid` ownership in the guest overlay. Image device nodes under `/dev` are ignored because every container gets a fresh restricted `/dev`.
- No Developer ID signature or notarized download yet. Build from source for now; do not use this preview as a Docker replacement.

Treat images and workloads as untrusted. See the [threat model](docs/THREAT_MODEL.md) for current protections, assumptions, and open security review work.

## Local checks

GitHub Actions is disabled. Run the local suite on Apple Silicon:

```sh
./scripts/check-local.sh
```

It checks Zig formatting, unit tests, a `ReleaseSafe` build, Python check scripts, guest preparation, and VM/OCI integration including non-root access to OCI-owned files. The integration suite uses the local image cache and network access on first use. Run `zig build -Doptimize=ReleaseSafe benchmark` separately; benchmark results depend on the host and system load.

## Project status

Rift is an early source preview. The command examples above are implemented and checked locally, with the limits listed here. See the [architecture notes](docs/ARCHITECTURE.md) for implementation details.

## Build from source

```sh
brew install zig
git clone https://github.com/OthmaneBlial/Rift.git
cd Rift
zig build -Doptimize=ReleaseSafe
```

## Roadmap

[ROADMAP.md](ROADMAP.md)

## License

[Apache-2.0](LICENSE)
