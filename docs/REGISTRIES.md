# Registry compatibility checks

These are individual public image samples, not a guarantee that every image or authentication mode at a provider works. Checks ran on 2026-09-27 on an Apple M2 with macOS 26.6 and Zig 0.16.0. Each sample used a temporary `HOME` and an environment without registry credentials.

| Registry | Image reference | ARM64 manifest digest | Verified operation |
| --- | --- | --- | --- |
| GitHub Container Registry | `ghcr.io/fluxcd/flux-cli:v2.5.1` | `sha256:546b7ebc8bc166a83276e0df67ad2d4fb0f0fedc34715c5c43e107ff28d53210` | `rift run --rm ghcr.io/fluxcd/flux-cli:v2.5.1 --version` printed `flux version 2.5.1`. |
| Quay | `quay.io/libpod/alpine:latest` | `sha256:f270dcd11e64b85919c3bab66886e59d677cf657528ac0e4805d3c71e458e525` | `rift pull` fetched and verified its manifest and layer. |
| Google GCR | `gcr.io/distroless/static-debian12:nonroot` | `sha256:06c3c14b7fa252d9f4285242d2d665ce3b51f74b02d3c529464f220f2912aecb` | `rift pull` fetched 12 layers, including GCR's root-relative blob redirect. |
| Kubernetes registry | `registry.k8s.io/pause:3.10` | `sha256:e50b7059b633caf3c1449b8da680d11845cda4506b513ee7a2de00725f0a34a7` | `rift pull` fetched and verified its manifest and layer. |

Docker Hub and Amazon ECR Public have separate local samples recorded in the [release notes](RELEASE_NOTES_v0.1.1.md). Private-registry Bearer authentication is tested against a local fixture; compatibility with other private providers remains open.
