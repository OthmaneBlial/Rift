# Local benchmarks

Rift benchmarks run on the current Mac. They do not compare Rift with Docker. The cached benchmark does not measure network pulls; a separate fresh-home smoke run below records one pull sample. Results depend on filesystem cache, host load, network conditions, and image cache contents.

## Reproduce

On an Apple Silicon Mac with Zig 0.16.0, pull Alpine and perform one run to install the verified guest boot files, then run:

```sh
zig build -Doptimize=ReleaseSafe
zig-out/bin/rift pull alpine
zig-out/bin/rift run --rm alpine /bin/true
zig build -Doptimize=ReleaseSafe benchmark
```

The benchmark copies the local image blobs, image records, and guest boot files into a temporary HOME. Setup and copying are outside the timed region. It measures one Alpine `/bin/true` launch, five subsequent launches, five `rift version` calls, and the host worker's RSS after a detached Alpine command reports ready. Each launch starts a new VM. The script stops and removes its container, checks that logical storage usage returns to its starting value, and deletes the temporary HOME. Output is JSON so individual samples remain visible. It also records logical CPU count and 1/5/15-minute host load averages before and after timing; load average is not CPU utilization.

The first launch already has the image and guest files cached. It is **not** a fresh installation or an uncached macOS filesystem measurement. The RSS figure comes from `ps` for the Rift host worker; it does not measure VM memory or total system pressure. Each VM is configured with 256 MiB of guest RAM. The store size is the logical size of all copied cache files, including any other images present, and excludes the binary.

`binary_bytes` records the local executable size. Local builds are ad-hoc signed for execution on macOS; this is not Developer ID signing or notarization.

## Latest cached benchmark

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `60000c7`, 2026-09-27 17:59:58 UTC. One run with the cached store:

| Metric | Result |
| --- | ---: |
| Local executable size | 1,693,360 bytes |
| First Alpine launch with cached assets | 1,377.1 ms |
| Subsequent Alpine launches, median of 5 | 1,112.5 ms |
| Subsequent Alpine launch samples | 1,100.5, 1,132.1, 1,130.4, 1,112.5, 1,103.8 ms |
| `rift version`, median of 5 | 7.1 ms |
| Detached host worker RSS after guest ready | 10,736 KiB |
| Copied store, logical file bytes | 112,367,255 bytes |
| Host load average, 1/5/15 minute, before | 5.43 / 6.22 / 5.47 |
| Host load average, 1/5/15 minute, after | 5.65 / 6.24 / 5.48 |

The worker RSS does not include VM memory. This run is a local sample, not a cross-machine performance claim.

## Fresh-home first-use check

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `60000c7`, 2026-09-27. The `docker` CLI and `/Applications/Docker.app` were absent. Rift ran with a new temporary `HOME` whose initial image, blob, and guest storage was empty; Rift's normal data directory was not used or changed.

| Step | Result |
| --- | ---: |
| `rift pull alpine` | 2.22 s; one ARM64 layer |
| First `rift run --rm alpine echo "Hello from Rift"` | 3.38 s; guest boot files downloaded and command output verified |
| `rift pull nginx` | 4.21 s; seven ARM64 layers |
| Detached Nginx start | 0.04 s to return a container ID |
| Nginx over forwarded localhost TCP port | HTTP response contained `Welcome to nginx!` |
| `ps`, `logs`, `stop`, `rm`, `system df`, `clean`, `clean --yes` | All commands returned successfully |
| Store after pulling Alpine and Nginx | 112,367,255 logical bytes; guest files were 46,402,986 bytes |
| Complete smoke-run elapsed time | 17.89 s |

The cleanup preview identified 19,447 logical bytes in two unreferenced blobs; `clean --yes` removed them. Timings are one sample and include this Mac's network and host load. The test did not measure guest download time separately, total host-plus-VM memory, or Homebrew installation, and a temporary home does not stand in for a freshly provisioned Mac.

## Isolation milestone under host load

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `564a9cb`, 2026-09-27 UTC. Two runs used the same cached store:

| Metric | Run 1 | Run 2 |
| --- | ---: | ---: |
| Local executable size | 1,620,496 bytes | 1,620,496 bytes |
| First Alpine launch with cached assets | 4,907.3 ms | 1,450.7 ms |
| Subsequent Alpine launches, median of 5 | 1,909.3 ms | 3,288.7 ms |
| `rift version`, median of 5 | 11.2 ms | 16.4 ms |
| Detached host worker RSS after guest ready | 10,688 KiB | 10,656 KiB |
| Copied store, logical file bytes | 112,367,255 bytes | 112,367,255 bytes |
| One-minute host load average, before to after | Not captured | 13.55 to 22.71 |

Subsequent launch samples were 2,608.8, 1,909.3, 2,164.4, 1,075.2, and 1,784.3 ms in run 1; 1,655.1, 3,288.7, 5,325.8, 3,797.5, and 3,026.1 ms in run 2. This Mac has 8 logical CPUs. An earlier working-tree run with the same namespace executor but before the final read-only `/proc` change measured a 1,046.1 ms median. The high and changing host load prevents attributing these slower exact-commit samples to the isolation code.

## Earlier local runs

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `8b0138b`, 2026-09-27 UTC. Three runs used the same cached store and benchmark script:

| Metric | Run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: |
| Local executable size | 1,584,704 bytes | 1,584,704 bytes | 1,584,704 bytes |
| First Alpine launch with cached assets | 2,057.2 ms | 2,205.5 ms | 1,050.8 ms |
| Subsequent Alpine launches, median of 5 | 1,625.9 ms | 1,671.0 ms | 1,010.8 ms |
| `rift version`, median of 5 | 7.2 ms | 6.9 ms | 7.2 ms |
| Detached host worker RSS after guest ready | 10,560 KiB | 10,544 KiB | 10,544 KiB |
| Copied store, logical file bytes | 112,367,255 bytes | 112,367,255 bytes | 112,367,255 bytes |

The slower samples' cause was not isolated. A fresh local build of earlier commit `2dec30e` measured a 1,030.2 ms subsequent median between runs 2 and 3; run 3 of the current commit then measured 1,010.8 ms. These results do not establish a consistent startup regression or cross-machine speed.

## First local run

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `2dec30e`, 2026-09-27 UTC:

| Metric | Result |
| --- | ---: |
| Local executable size | 1,500,192 bytes |
| First Alpine launch with cached assets | 1,298.6 ms |
| Subsequent Alpine launches, median of 5 | 1,028.8 ms |
| `rift version`, median of 5 | 7.0 ms |
| Detached host worker RSS after guest ready | 10,480 KiB |
| Copied store, logical file bytes | 112,367,255 bytes |

Subsequent launch samples: 1,007.5, 1,030.1, 1,028.8, 1,057.5, and 991.8 ms. This is one local run, not a cross-machine performance claim. Total host-plus-VM memory and larger-image startup are still unmeasured. The fresh-home sample above times public image pulls but does not establish repeatable throughput.
