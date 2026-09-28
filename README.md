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

Set resources for a run:

```sh
rift run --cpus 4 --memory 1g --cpu-limit 1.5 --memory-limit 512m --pids-limit 64 --rm alpine sh -c 'grep -c "^processor" /proc/cpuinfo; grep MemTotal /proc/meminfo'
```

`--cpus` and `--memory` set CPU and RAM visible to the private VM. Defaults are 2 CPUs and 256 MiB; Virtualization.framework limits accepted values. `--cpu-limit` sets a per-container CPU-time quota from 0.001 up to the VM's vCPU count, with at most three decimal places. `--memory-limit` sets a per-container cgroup memory limit and accepts bytes or `m`/`g` sizes; it cannot exceed `--memory`. Exceeding this hard memory limit can trigger the guest kernel's cgroup OOM handling. `--pids-limit` caps guest processes and threads; Rift reserves one task for its PID namespace supervisor. All three cgroup limits are optional. `--cap-profile none` removes Linux capabilities from workload and `exec` processes; the default is Rift's reduced capability set.

Use `rift run --network none alpine ...` to start a container without a VM network adapter. Port forwarding requires networking.

The first run downloads and verifies the pinned Alpine guest files. Image pulls and first-run setup need host network access, even when a container uses `--network none`.

## Run a small service

```sh
rift pull nginx
id=$(rift run -d -p 8080:80 nginx)
curl http://127.0.0.1:8080
rift ps
rift logs "$id"
rift logs --json "$id"
rift exec "$id" /bin/sh -c 'echo online'
rift stop "$id"
rift rm "$id"
```

Rift forwards one TCP port per run. Detached containers keep their logs and status until removed. `rift logs` prints the original combined output; `rift logs --json` emits binary-safe JSON Lines with the container ID, combined stream, byte offset, and base64 data. `exec` runs a non-interactive command by default, streaming combined stdout and stderr; add `-i` to stream stdin or `-it` to attach a terminal.

## Build an image

In a context containing a `Dockerfile` and `message` file:

```dockerfile
FROM alpine
ENV MESSAGE="built image"
WORKDIR /tmp/rift-app
USER 65534
COPY message /tmp/rift-app/message
RUN test "$(cat message)" = "built image"
ENTRYPOINT ["/bin/sh", "-c"]
CMD ["printf '%s: ' \"$MESSAGE\"; cat message"]
```

Build and run it:

```sh
rift build -t local/message:dev .
rift run --rm local/message:dev
```

External base images are pulled automatically when needed. Directory copies are recursive and preserve file modes. The builder executes each shell-form or JSON-array `RUN` in a temporary Linux VM against the image state built so far. It applies `ENV`, `USER`, `WORKDIR`, `ENTRYPOINT`, and `CMD`; `ENV` uses literal `NAME=value` assignments, and `WORKDIR` must be absolute. Rift creates a missing working directory in the disposable container overlay when it starts.

Multi-stage builds can name stages with `FROM image AS name`, inherit a previous stage with `FROM name`, and copy files with `COPY --from=name` or its earlier stage index. Only the final stage receives the output tag.

Detached containers honor image `StopSignal`. Dockerfile `STOPSIGNAL` accepts canonical Linux signal names or numbers; `SIGKILL`, `SIGSTOP`, and real-time signals are unsupported.

## What works

- Pull `linux/arm64` images from Docker Hub, Amazon ECR Public, `registry.k8s.io`, GitHub Container Registry, Quay, and Google GCR. [Registry checks](docs/REGISTRIES.md) list the tested image samples; private Bearer-token support is verified against a local fixture.
- Run foreground and detached containers with image entrypoint, command, environment, working directory, user, supplementary groups, and configurable guest CPU and RAM.
- Use outbound networking and DNS by default, disable the VM network adapter with `--network none`, forward one localhost port, and mount explicit file or directory volumes.
- Inspect and manage detached containers with `ps`, `inspect`, `logs`, `exec`, `stop`, `kill`, and `rm`. `logs --json` emits byte-preserving JSON Lines. `exec -i` streams stdin; `exec -it` adds a resizable TTY and forwards SIGINT, SIGTERM, SIGHUP, and SIGQUIT.
- Build OCI images from multiple `FROM` stages, file or directory `COPY` (including `COPY --from`), ordered single-line `RUN`, `STOPSIGNAL`, and the `ENV`, `USER`, `WORKDIR`, `ENTRYPOINT`, and `CMD` process settings. Each successful `RUN` squashes the prior filesystem into one layer. `.dockerignore`, globs, symlinks, special files, and other Dockerfile instructions remain unsupported.
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

Three cached benchmark runs on an Apple M2 with macOS 26.6 and Zig 0.16.0 (`ReleaseSafe`, runtime `3ad3b27`, benchmark `fc4c3e5`):

| Metric | Result |
| --- | ---: |
| First cached Alpine launch, median of 3 | 1,178 ms |
| Subsequent launches, median of 3 run medians | 1,144 ms |
| VM start to guest control ready, median of 3 | 431 ms |
| Detached start to workload-ready marker, median of 3 | 975 ms |
| Warm detached `rift exec <id> /bin/true`, median of 3 run medians | 70 ms |
| Executable size | 2,039,216 bytes |
| Worker and VM-service process footprint after ready, median of 3 | 151.3 MiB |
| Copied store, logical file bytes | 151,145,470 bytes |
| Whole-Mac physical RAM | 16 GiB |

The image and guest files were cached. Each run median covers five launches; the table reports the median across three benchmark runs. The process footprint varied from 150.8 to 159.1 MiB and includes only the Rift worker and VM service. Warm `exec` timing includes the host CLI, guest control request/response, supervisor dispatch, and `/bin/true`; it is not isolated IPC latency. VM-start timing ends when the guest mounts its rootfs and control shares; it excludes guest overlay setup and workload startup. Homebrew v0.1.2's installed keg uses 1,724 KiB; its first-run guest assets use 44.3 MiB separately from the image cache. These are single-machine samples, not a Docker comparison. See [benchmark method and history](docs/BENCHMARKS.md).

## Requirements and limits

- macOS 12 or newer on Apple Silicon.
- Zig 0.16 or newer for manual source builds; Homebrew installs the build dependency automatically.
- One lightweight Linux VM per run; defaults are 2 CPUs and 256 MiB RAM. `--cpus` and `--memory` change guest VM capacity within the range supported by the Mac. `--cpu-limit`, `--memory-limit`, and `--pids-limit` optionally enforce per-container cgroup v2 quotas; `--cap-profile none` removes capabilities from workload processes.
- One TCP port mapping per run; up to 16 explicit file or directory volumes.
- `rift build` supports up to 128 stages, one source per `COPY` (from the local context or an earlier named or indexed stage), single-line shell or JSON-array `RUN`, `STOPSIGNAL`, and `ENV`, `USER`, `WORKDIR`, `ENTRYPOINT`, and `CMD`. Each `RUN` boots a temporary Linux VM, applies the preceding image state, and stores the successful result as a squashed OCI layer; failed commands stop the build without recording its tag. Each build VM has 256 MiB RAM and a 256 MiB writable overlay. `ENV` values are literal and `WORKDIR` must be absolute. Targets must be absolute. Stop signals accept canonical names or numbers except for `SIGKILL`, `SIGSTOP`, and real-time signals. `.dockerignore`, globs, symlinks, special files, line continuations, and other Dockerfile instructions are unsupported.
- Each pull is capped at 16 GiB of distinct image blobs not already verified in the local cache.
- Each layer is capped at 8 GiB decompressed; all image layers together are capped at 32 GiB per extraction pass.
- `rift exec -i` streams stdin. Use `rift exec -it` from a terminal for a resizable guest TTY; Rift restores host terminal settings when the command ends.
- Rift restores `SCHILY.xattr.*`, `LIBARCHIVE.xattr.*`, and legacy `security.capability` PAX values on files, nested directories, and the root directory. Root-directory attributes are copied into each run's private tmpfs upper layer so they remain visible at `/`. Image `user.overlay.*` and `trusted.overlay.*` attributes are rejected because OverlayFS reserves them for its own metadata. Workloads run with `no_new_privs`, so file capabilities cannot grant extra process privileges. Other PAX fields remain unsupported. OCI FIFOs are restored as named pipes; character and block devices outside `/dev` are recreated in the disposable guest overlay with their device numbers, owner, mode, and modification time. Device-node PAX xattrs are ignored; setting a `user.*` attribute on the verified Alpine device-node fixture returned `EPERM`. Unix-domain socket entries remain unsupported. Image device nodes under `/dev` are ignored because every container gets a fresh restricted `/dev`.
- No Developer ID signature or notarized download yet. Build from source for now; do not use this preview as a Docker replacement.

Treat images and workloads as untrusted. See the [threat model](docs/THREAT_MODEL.md) for current protections, assumptions, and open security review work.

## Local checks

GitHub Actions is disabled. Run the local suite on Apple Silicon:

```sh
./scripts/check-local.sh
```

It checks Zig formatting, unit tests, a `ReleaseSafe` build, Python check scripts, guest preparation, and VM/OCI integration including xattrs, file capabilities, OCI character/block devices, and non-root access to OCI-owned files. The integration suite uses the local image cache and network access on first use. Run `zig build -Doptimize=ReleaseSafe benchmark` separately; benchmark results depend on the host and system load.

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
