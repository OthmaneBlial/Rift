<div align="center">
  <img src="site/favicon.svg" alt="Rift logo" width="96" height="96">
  <h1>Rift ⚡</h1>
  <p><strong>Ridiculously lightweight containers for macOS.</strong><br>No Docker Engine. No daemon. No Docker Desktop. One CLI.</p>
  <p>
    <img alt="macOS · Apple Silicon" src="https://img.shields.io/badge/macOS-Apple%20Silicon-1d6f58?style=for-the-badge&logo=apple&logoColor=white">
    <img alt="Built with Zig" src="https://img.shields.io/badge/built%20with-Zig-f7a41d?style=for-the-badge&logo=zig&logoColor=black">
    <a href="LICENSE"><img alt="Apache 2.0 license" src="https://img.shields.io/badge/license-Apache%202.0-3478b5?style=for-the-badge"></a>
  </p>
  <p><a href="https://othmaneblial.github.io/Rift/">Website</a> · <a href="https://github.com/OthmaneBlial/Rift/releases">Releases</a> · <a href="ROADMAP.md">Roadmap</a></p>
</div>

## 🚀 Run your first container

```sh
brew install OthmaneBlial/rift/rift
rift pull alpine
rift run --rm alpine echo "Hello from Rift"
```

Homebrew builds Rift from source with Zig. The installed CLI needs neither Zig nor Docker. First use downloads guest boot files.

## 🪶 Why Rift?

Docker Desktop brings a full container platform to Mac. Rift focuses on running Linux containers locally with Apple's Virtualization.framework.

| | Docker Desktop | Rift |
| --- | --- | --- |
| Setup | Desktop app, Docker Engine, Linux VM | CLI and guest boot files; one VM per run |
| Idle | Resource Saver can stop the VM; restart takes 3–10 seconds | No persistent Rift daemon |
| VM memory setting | Limit defaults to **50% of Mac RAM** | **256 MiB** guest RAM by default |
| License | Paid subscription required for larger businesses and government use | **Apache 2.0** |

**Measured on one Apple M2 Mac:** 2.06 MB executable · 46.25 MiB installed plus first-use boot files, before images · 1.13 s cached Alpine launch · 154.7 MiB idle worker and VM-service process footprint. [Method and raw results](docs/BENCHMARKS.md). These are Rift measurements, not a head-to-head Docker benchmark; process footprint excludes kernel memory. Docker's 50% setting is a VM limit, not actual RAM usage.

Docker facts: [Mac requirements](https://docs.docker.com/desktop/setup/install/mac-install/), [resource settings](https://docs.docker.com/desktop/settings-and-maintenance/settings/), and [license terms](https://docs.docker.com/subscription-billing/desktop-license/).

## 🌐 Serve something

```sh
id=$(rift run -d -p 8080:80 nginx)
curl http://127.0.0.1:8080
rift logs "$id"
rift stop "$id"
rift rm "$id"
```

## 🧰 What works

- Pull and run verified `linux/arm64` OCI images. [Tested registries](docs/REGISTRIES.md).
- Run in foreground or detached mode; inspect, exec, log, stop, and remove containers.
- Build images from a useful Dockerfile subset with `rift build -t local/app .`.
- Forward one TCP port, mount host files, set resource limits, and manage local image storage.

## ⚠️ Source preview

Apple Silicon and macOS 12+ only. One TCP port and up to 16 volumes per run. Dockerfile support is partial. Signed and notarized downloads are not available yet; [security review](docs/THREAT_MODEL.md) is ongoing. Rift is not a full Docker Desktop replacement.

## 📚 More

[Architecture](docs/ARCHITECTURE.md) · [Benchmarks](docs/BENCHMARKS.md) · [Roadmap](ROADMAP.md) · [Releases](https://github.com/OthmaneBlial/Rift/releases)

Run local checks with `./scripts/check-local.sh`. GitHub Actions is disabled.
