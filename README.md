<div align="center">
  <img src="site/favicon.svg" alt="Rift logo" width="76" height="76">
  <h1>Rift</h1>
  <p><strong>Lightweight Linux containers for macOS.</strong></p>
  <p>No Docker. No daemon. No Docker Desktop. Just one binary.</p>
  <p>
    <a href="https://othmaneblial.github.io/Rift/">Website</a> ·
    <a href="https://github.com/OthmaneBlial/Rift/releases">Releases</a> ·
    <a href="ROADMAP.md">Roadmap</a> ·
    <a href="docs/ARCHITECTURE.md">Architecture</a>
  </p>
</div>

Rift runs Linux containers on Apple Silicon Macs using Apple's Virtualization.framework. Each run gets a lightweight Linux VM. Rift needs no Docker Engine, Docker CLI, Docker Desktop, or always-on service.

> **Source preview:** Rift is under active development. Install from source with Homebrew; signed and notarized macOS downloads are not available yet.

## Install

```sh
brew install OthmaneBlial/rift/rift
```

Homebrew builds Rift from source and installs Zig for the build. Zig is not needed to run Rift.

## Try it

```sh
rift pull alpine
rift run --rm alpine echo "Hello from Rift"
```

Start a small web server:

```sh
id=$(rift run -d -p 8080:80 nginx)
curl http://127.0.0.1:8080
rift logs "$id"
rift stop "$id"
rift rm "$id"
```

## Build an image

Create a `Dockerfile` and a `hello.txt` file in the same directory:

```dockerfile
FROM alpine
COPY hello.txt /hello.txt
CMD ["cat", "/hello.txt"]
```

```sh
rift build -t local/hello:dev .
rift run --rm local/hello:dev
```

## What works

- Pull and run verified `linux/arm64` images from Docker Hub, ECR Public, GHCR, Quay, and Google GCR. See [tested registries](docs/REGISTRIES.md).
- Run foreground or detached containers; inspect them, read logs, execute commands, and stop or remove them.
- Use outbound networking and DNS, disable networking per VM, forward one localhost port, and mount explicit host files or directories.
- Build multi-stage OCI images with `FROM`, `COPY`, `RUN`, `ENV`, `USER`, `WORKDIR`, `ENTRYPOINT`, `CMD`, and `STOPSIGNAL`.
- Set VM CPU and memory, optional per-container CPU, memory, and process limits, and Linux capabilities.
- Inspect and safely clean image storage with `rift system df` and `rift clean`.

For private registries, set `RIFT_REGISTRY_USERNAME` and `RIFT_REGISTRY_PASSWORD` for the pull. Rift does not save those credentials. Private Bearer-token authentication is verified with a local registry fixture; provider-specific private registries are not yet verified.

## Common options

```sh
# Limit guest resources
rift run --cpus 4 --memory 1g --cpu-limit 1.5 --memory-limit 512m --pids-limit 64 alpine /bin/true

# Disable networking for this VM
rift run --network none alpine echo offline

# Add or remove Linux capabilities
rift run --cap-profile none --cap-add SYS_ADMIN --rm alpine /bin/busybox true

# Mount a host directory (read-only unless :rw is given)
rift run -v "$PWD/data:/data:rw" alpine /bin/busybox ls /data
```

`rift exec -i` streams stdin; `rift exec -it` attaches a resizable terminal. `rift logs --json` writes binary-safe JSON Lines.

## Requirements and limits

- macOS 12 or newer on Apple Silicon; images must provide `linux/arm64` layers.
- One VM per run, with 2 CPUs and 256 MiB RAM by default. Both are configurable within the Mac's supported range.
- Dockerfile support is a useful subset. `.dockerignore`, globs, symlinks, special files, and other instructions are not supported.
- One TCP port mapping and up to 16 explicit volumes per run.
- No Developer ID signature or notarized binary downloads yet. The security review is ongoing; see the [threat model](docs/THREAT_MODEL.md).

See [benchmarks and measurement method](docs/BENCHMARKS.md) for local results and their limits.

## Local checks

GitHub Actions is disabled. Run checks locally on Apple Silicon:

```sh
./scripts/check-local.sh
```

## Project

- [Roadmap](ROADMAP.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Threat model](docs/THREAT_MODEL.md)
- [Releases](https://github.com/OthmaneBlial/Rift/releases)
- [Apache-2.0 license](LICENSE)
