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

Rift is an experimental OCI container runtime for Apple Silicon Macs. It runs Linux workloads in Apple's Virtualization.framework and builds with Zig. The current [v0.1.0 release](https://github.com/OthmaneBlial/Rift/releases/tag/v0.1.0) is a source preview; public notarized binaries are not available yet.

## Quick start

Install Zig 0.16 or newer, then build Rift:

```sh
brew install zig
git clone https://github.com/OthmaneBlial/Rift.git
cd Rift
zig build -Doptimize=ReleaseSafe
mkdir -p "$HOME/.local/bin"
install -m 755 zig-out/bin/rift "$HOME/.local/bin/rift"
```

Add `~/.local/bin` to your `PATH`, then run a container:

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

- Pull public OCI images for `linux/arm64`; optional credentials support private Bearer-token registries.
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

## Requirements and limits

- macOS on Apple Silicon.
- Zig 0.16 or newer to build from source.
- One lightweight Linux VM per run; the current guest limit is 2 CPUs and 256 MiB RAM.
- One TCP port mapping per run; up to 16 explicit file or directory volumes.
- `exec` does not support interactive stdin or TTY allocation yet.
- OCI file ownership, PAX `uid`/`gid` and global fields other than `mtime`, extended attributes, special files, and broader process isolation remain unsupported.
- No Developer ID signature or notarized download yet. Build from source for now; do not use this preview as a Docker replacement.

Treat images and workloads as untrusted. See the [threat model](docs/THREAT_MODEL.md) for current protections, assumptions, and open security review work.

## Local checks

GitHub Actions is disabled. Run the local suite on Apple Silicon:

```sh
./scripts/check-local.sh
```

It checks Zig formatting, unit tests, a `ReleaseSafe` build, Python check scripts, guest preparation, and the VM/OCI integration checks. The integration suite uses the local image cache and network access on first use. Run `zig build -Doptimize=ReleaseSafe benchmark` separately; benchmark results depend on the host and system load.

## Project status

Rift is an early source preview. The command examples above are implemented and checked locally, with the limits listed here. See the [architecture notes](docs/ARCHITECTURE.md) for implementation details.

## Roadmap

[ROADMAP.md](ROADMAP.md)

## License

[Apache-2.0](LICENSE)
