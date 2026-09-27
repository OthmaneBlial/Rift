# Local benchmarks

Rift benchmarks run on the current Mac. They do not compare Rift with Docker or measure a network pull. Results depend on filesystem cache, host load, and image cache contents.

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

## Isolation milestone under host load

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `564a9cb`, 2026-09-27 UTC. Two runs used the same cached store:

| Metric | Run 1 | Run 2 |
| --- | ---: | ---: |
| Signed binary size | 1,620,496 bytes | 1,620,496 bytes |
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
| Signed binary size | 1,584,704 bytes | 1,584,704 bytes | 1,584,704 bytes |
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
| Signed binary size | 1,500,192 bytes |
| First Alpine launch with cached assets | 1,298.6 ms |
| Subsequent Alpine launches, median of 5 | 1,028.8 ms |
| `rift version`, median of 5 | 7.0 ms |
| Detached host worker RSS after guest ready | 10,480 KiB |
| Copied store, logical file bytes | 112,367,255 bytes |

Subsequent launch samples: 1,007.5, 1,030.1, 1,028.8, 1,057.5, and 991.8 ms. This is one local run, not a cross-machine performance claim. Pull speed, first-use ISO download, total host memory, and larger-image startup are still unmeasured.
