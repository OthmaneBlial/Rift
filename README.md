<div align="center">
  <img src="site/favicon.svg" alt="Rift logo" width="76" height="76">
  <h1>Rift</h1>
  <p><strong>Ridiculously lightweight containers for macOS.</strong></p>
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

## Quick start

```sh
brew install OthmaneBlial/rift/rift
rift pull alpine
rift run --rm alpine echo "Hello from Rift"
```

Homebrew uses Zig to build Rift from source. The installed Rift binary needs neither Zig nor Docker.

## Why Rift on macOS?

Docker Desktop is a capable, mature platform. Its extra VM, desktop app, and background services can be more than you need when you only want to run a few Linux containers locally. Rift is built for that smaller job.

| | Docker Desktop for Mac | Rift |
| --- | --- | --- |
| Runtime | Docker Engine runs inside a Linux VM managed by Docker Desktop, alongside its macOS app and supporting services. | One small CLI starts a Linux VM for each run through Apple's Virtualization.framework. No Docker Engine, Docker Desktop, or persistent Rift daemon. |
| Memory | Docker lists 4 GB of host RAM as its minimum. Its Linux VM memory limit defaults to 50% of host RAM, with 1 GB swap. On a 16 GB Mac, that is an 8 GB VM limit; it is a configurable ceiling, not a claim that Docker always uses 8 GB. | Each VM defaults to 2 CPUs and 256 MiB of guest RAM. Across three idle samples on an M2 Mac, the Rift worker and VM service had a median process footprint of 154.7 MiB (range: 151.3–158.6 MiB). That excludes kernel and other system memory; it is not total host RAM or a universal workload figure. |
| Disk | Images and containers live in a VM disk image. Its configured maximum is not the same as actual disk space used. | A measured Homebrew install plus first-use guest boot files occupied 45.9 MiB, before image downloads. |
| Idle behavior | Resource Saver can stop the Linux VM while idle; Docker documents a 3–10 second restart when it is needed again. | No always-on Rift service to keep running. Starting a container still boots its VM. |
| Host files | File sharing into the Linux VM can add overhead; Docker notes that sharing many files can increase CPU use and slow filesystem operations. | Mount only the host files or directories you specify. Rift currently supports up to 16 volumes per run. |

Docker Desktop's macOS installer requires a supported macOS release (the current and two previous major releases) and at least 4 GB of RAM. See Docker's [Mac requirements](https://docs.docker.com/desktop/setup/install/mac-install/), [VM and backend architecture](https://docs.docker.com/desktop/features/networking/), [resource settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/), and [disk-image FAQ](https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/). Rift's measurements and exact method are in [benchmarks](docs/BENCHMARKS.md).

Docker Desktop is free for personal, education, non-commercial open-source use, and small businesses with fewer than 250 employees and under $10 million in annual revenue. Larger businesses and government use require a paid subscription under Docker's [license terms](https://docs.docker.com/subscription-billing/desktop-license/).

Rift is an early source preview, not a drop-in replacement for Docker Desktop. Docker has a broader, mature ecosystem, including workflows Rift does not support. Rift currently targets Apple Silicon and `linux/arm64`, implements a subset of Dockerfile instructions, maps one TCP port per run, and does not yet provide signed or notarized downloads. Choose Rift when a small, local container runtime on macOS matters more than broad Docker compatibility.

## Run a web server

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
