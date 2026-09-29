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

The benchmark copies local image blobs, image records, and guest boot files into a temporary `HOME`; setup and copying are outside the timed region. It measures one Alpine `/bin/true` launch, five subsequent launches, five `rift version` calls, VM-start-to-guest-control-ready latency, detached-run-to-workload-ready latency, and five warm `rift exec <id> /bin/true` calls. The VM timer starts immediately before `startWithCompletionHandler` and stops when the host observes an initramfs marker written after the guest mounts the rootfs and control VirtioFS shares, before overlay setup, DHCP, or workload execution. Host polling checks for this marker about every 10 ms.

Benchmark-only stage instrumentation is enabled only for the detailed detached VM sample; timed foreground launches do not write or poll benchmark markers. The detached duration is captured as soon as its workload-ready log appears. The script then allows up to two seconds for the host-side marker measurements to arrive, outside that duration, and reads the guest DHCP address before stopping the VM removes its temporary control directory.

Warm `exec` timing starts a fresh host CLI process for each call against the already-ready detached VM. It includes host request creation, guest control-share polling and dispatch, `/bin/true` startup, and result collection. It is end-to-end command overhead, not an isolated VirtioFS latency measurement. The five calls run before the idle-guest memory samples.

The detached timer starts before `rift run -d` and stops when the first `rift logs` poll returns the workload-ready marker. It includes host rootfs setup, VM startup, workload execution, and log polling; it excludes the later RSS and footprint sampling. Each launch starts a new VM. Graceful shutdown timing starts immediately before `rift stop` on that ready VM and ends when the command returns; it includes guest stop delivery and teardown plus the Virtualization.framework stop callback, but excludes `rift rm`.

The script records the worker RSS and, when process identification is unambiguous, Virtualization.framework VM-service RSS and process footprints. It also samples system memory immediately before VM launch and three times after the idle guest reports ready. These whole-Mac snapshots use `hw.memsize`, the free-page count from `vm_stat`, and `memory_pressure -Q` when available. They include every macOS process and the VM, so they are contextual system measurements, not memory attributable to Rift.

`bytes_not_on_free_list` is total physical RAM minus the strict free-page list. It includes reclaimable caches and other pages, so it is not a process footprint or a measure of memory exclusively consumed by Rift. `memory_pressure_free_percent` is macOS's system-wide available-memory percentage; it is not an exact byte count. Do not add either system metric to process footprints. The script stops and removes its container, checks that logical storage usage returns to its starting value, and deletes the temporary `HOME`. Output is JSON so individual samples remain visible. It also records logical CPU count and 1/5/15-minute host load averages before and after timing; load average is not CPU utilization.

The first launch already has the image and guest files cached. It is **not** a fresh installation or an uncached macOS filesystem measurement. `worker_and_vm_process_footprint_bytes` is the macOS footprint total for those two processes, with shared mappings de-duplicated by `footprint`; it excludes kernel and other system memory, so it is not total host memory. VM-service RSS can include shared mappings and should not be added to worker RSS as a unique-memory total. If the VM process or footprint report is ambiguous or unavailable, the footprint fields are null and `memory_measurement_note` explains why. Each VM is configured with 256 MiB of guest RAM. The store size is the logical size of all copied cache files, including any other images present, and excludes the binary.

`binary_bytes` records the local executable size. Local builds are ad-hoc signed for execution on macOS; this is not Developer ID signing or notarization.

## APFS initramfs sharing

On APFS, Rift uses `fclonefileat` to clone the immutable installed `initramfs-virt` before appending each run's CPIO entries. Other filesystems or unsupported clone operations fall back to the streaming copy. Logical file sizes remain unchanged; APFS shares the base data until a write changes it.

To measure the base-file storage effect, 12 temporary clones of the installed 10,161,578-byte initramfs reduced free space by 12,288 bytes. After removing those clones, 12 full copies reduced free space by 121,958,400 bytes for 121,938,936 logical bytes. Both groups were created under `~/Library/Application Support/Rift`; the temporary directory was removed. `shutil.disk_usage` reports free space for the whole volume, so the 12 KiB clone delta includes filesystem metadata and measurement noise. Each actual run also appends its own script and guest executor CPIO entries, which consume space in both cases. Treat this as evidence that cloning avoids roughly 122 MB of duplicate base data across these 12 files on this volume, not an exact per-file allocation guarantee.

The cached runtime benchmark showed no startup improvement: one pre-change sample measured 1,100.0 ms for subsequent Alpine launches and 433.828 ms to guest control readiness; one post-change sample measured 1,109.4 ms and 435.95 ms. One sample per revision is insufficient to infer a difference. Guest shutdown was not changed in those samples.

## Startup stages after profiling

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, source tree committed as `73e7935`; three independent runs on 2026-09-29 at 08:18, 08:27, and 08:28 UTC. Each used the same cached Alpine store (151,145,470 logical bytes). Five normal foreground launches were timed per run; stage markers were enabled only for the separate detailed detached sample.

| Metric | Run 1 | Run 2 | Run 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| Optimized executable size | 2,060,048 bytes | 2,060,048 bytes | 2,060,048 bytes | 2,060,048 bytes |
| Subsequent Alpine launches, median of 5 | 1,125.4 ms | 1,146.6 ms | 1,128.8 ms | 1,128.8 ms |
| VM start to guest control ready | 436.056 ms | 434.024 ms | 434.928 ms | 434.928 ms |
| Host setup before VM, including rootfs and initramfs | 304.050 ms | 305.956 ms | 307.186 ms | 305.956 ms |
| Rootfs assembly (part of host setup above) | 262.744 ms | 264.175 ms | 266.066 ms | 264.175 ms |
| Initramfs writing (part of host setup above) | 0.758 ms | 0.779 ms | 0.696 ms | 0.758 ms |
| Guest overlay and applet setup | 0.4 ms | 0.3 ms | 0.4 ms | 0.4 ms |
| Guest networking and DHCP | 204.1 ms | 216.4 ms | 215.1 ms | 215.1 ms |
| Detached run to workload ready | 943.8 ms | 969.9 ms | 975.4 ms | 969.9 ms |
| Graceful `rift stop` | 322.4 ms | 330.7 ms | 331.3 ms | 330.7 ms |
| Worker and VM-service process footprint | 151.3 MiB | 158.6 MiB | 154.7 MiB | 154.7 MiB |
| DHCP address acquired | Yes | Yes | Yes | Yes |

The host-setup row includes the rootfs and initramfs sub-rows; do not add them twice. The detached timing includes benchmark marker creation and host polling, so it is diagnostic and not directly comparable with uninstrumented detached launches. The guest stage timestamps are observations from the host, not kernel-only timings. These are three samples on one Mac, not a cross-machine performance claim. Cached foreground startup remains about 1.13 seconds; the measurement did not establish a startup improvement over earlier samples.

## Graceful shutdown baseline

Apple M2, macOS 26.6, `ReleaseSafe`, runtime commit `7e7480f`, three independent benchmark invocations on 2026-09-28 between 07:02 and 07:04 UTC. The benchmark measured `rift stop` after the detached Alpine workload and VM were ready; it did not include removal.

| Sample | VM start to guest control ready | Detached run to ready | Graceful `rift stop` |
| --- | ---: | ---: | ---: |
| 1 | 431.736 ms | 3,727.7 ms | 1,053.4 ms |
| 2 | 444.817 ms | 949.0 ms | 1,153.0 ms |
| 3 | 426.132 ms | 3,611.3 ms | 1,148.3 ms |
| Median | 431.736 ms | 3,611.3 ms | 1,148.3 ms |

The detached-ready samples vary substantially even though VM control readiness stays near 0.43 seconds; this benchmark does not isolate the source of that later variation. Shutdown clusters near the guest script's one-second stop-file polling interval, plus guest and VM teardown. This is a three-sample baseline, not a cross-machine performance claim.

## Graceful shutdown after stop-polling change

Apple M2, macOS 26.6, `ReleaseSafe`, runtime commit `2d66fc8`, benchmark script commit `6f3acb3`; three independent invocations on 2026-09-28 between 07:08 and 07:11 UTC. The guest C executor checks for the stop file in its existing 50 ms control loop and forwards the configured stop signal; the init shell no longer starts a one-second polling watcher. The benchmark measures `rift stop` on a ready detached Alpine VM and excludes removal.

| Sample | VM start to guest control ready | Detached run to ready | Graceful `rift stop` |
| --- | ---: | ---: | ---: |
| 1 | 429.592 ms | 952.7 ms | 322.9 ms |
| 2 | 432.584 ms | 952.1 ms | 320.0 ms |
| 3 | 426.504 ms | 929.5 ms | 319.8 ms |
| Median | 429.592 ms | 952.1 ms | 320.0 ms |

The graceful-stop median fell by 828.3 ms (72.1%) from the three-sample baseline above on this Mac. The result includes guest and Virtualization.framework teardown; it does not predict shutdown time on other Macs. VM startup behavior was not changed.

## Latest cached benchmark

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `3ad3b27`, benchmark script commit `fc4c3e5`, three runs from 2026-09-28 04:38:49 to 04:39:11 UTC. Each run used the same cached store:

| Metric | Run 1 | Run 2 | Run 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| Local executable size | 2,039,216 bytes | 2,039,216 bytes | 2,039,216 bytes | 2,039,216 bytes |
| First Alpine launch with cached assets | 1,362.6 ms | 1,135.7 ms | 1,177.5 ms | 1,177.5 ms |
| Subsequent Alpine launches, median of 5 | 1,143.7 ms | 1,146.3 ms | 1,126.9 ms | 1,143.7 ms |
| VM start to guest control ready | 431.219 ms | 428.958 ms | 432.384 ms | 431.219 ms |
| Detached run to workload-ready marker | 974.9 ms | 976.9 ms | 969.5 ms | 974.9 ms |
| Warm detached `rift exec <id> /bin/true`, median of 5 | 75.4 ms | 67.8 ms | 70.0 ms | 70.0 ms |
| Worker and VM-service process footprint | 159.1 MiB | 151.3 MiB | 150.8 MiB | 151.3 MiB |
| Copied store, logical file bytes | 151,145,470 bytes | 151,145,470 bytes | 151,145,470 bytes | 151,145,470 bytes |

The small differences from recent samples do not establish a performance change. Process footprint varied between runs; it includes the Rift worker and VM service, not the whole Mac. Warm exec measures command overhead through the guest control path, not isolated IPC latency. VM-start timing ends at guest control-share readiness, before overlay setup and workload startup.

## Previous single cached benchmark

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `3ad3b27`, benchmark script commit `fc4c3e5`, 2026-09-28 04:36:11 UTC. One run with the cached store:

| Metric | Result |
| --- | ---: |
| Local executable size | 2,039,216 bytes |
| First Alpine launch with cached assets | 1,196.7 ms |
| Subsequent Alpine launches, median of 5 | 1,140.1 ms |
| Subsequent Alpine launch samples | 1,146.9, 1,140.1, 1,140.8, 1,109.7, 1,120.8 ms |
| VM start to guest control ready | 429.3 ms |
| Detached run to workload-ready marker | 971.1 ms |
| Warm detached `rift exec <id> /bin/true`, median of 5 | 77.1 ms |
| Warm detached exec samples | 69.3, 122.0, 76.7, 77.1, 79.7 ms |
| `rift version`, median of 5 | 7.0 ms |
| Detached Rift worker RSS | 10,784 KiB |
| Virtualization.framework VM-service RSS | 207,024 KiB |
| VM-service process footprint | 160,645,936 bytes (153.2 MiB) |
| Worker and VM-service combined process footprint | 163,317,008 bytes (155.8 MiB) |
| Whole-Mac physical RAM | 16 GiB |
| Whole-Mac memory pressure available | 66% before VM; 66% across 3 idle-guest samples |
| Whole-Mac free pages | 32,262 before VM; 20,738–20,789 across 3 idle-guest samples |
| Copied store, logical file bytes | 151,145,470 bytes |
| Host load average, 1/5/15 minute, before | 2.22 / 3.48 / 3.61 |
| Host load average, 1/5/15 minute, after | 2.19 / 3.44 / 3.59 |

This is one local sample. The warm exec figure is command overhead through the guest control path, not isolated IPC latency. The whole-Mac memory values include unrelated host processes and must not be attributed to Rift. The VM-start metric ends at guest control-share readiness, before overlay setup and workload startup.

## Earlier cached benchmark

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `a272cef`, benchmark script commit `fc4c3e5`, 2026-09-28 02:56:35 UTC. One run with the cached store:

| Metric | Result |
| --- | ---: |
| Local executable size | 2,037,536 bytes |
| First Alpine launch with cached assets | 1,369.0 ms |
| Subsequent Alpine launches, median of 5 | 1,122.4 ms |
| Subsequent Alpine launch samples | 1,122.4, 1,114.0, 1,134.2, 1,127.1, 1,115.7 ms |
| VM start to guest control ready | 431.71 ms |
| Detached run to workload-ready marker | 983.1 ms |
| Warm detached `rift exec <id> /bin/true`, median of 5 | 66.0 ms |
| Warm detached exec samples | 60.0, 61.9, 66.0, 66.2, 70.3 ms |
| `rift version`, median of 5 | 7.0 ms |
| Detached Rift worker RSS | 10,816 KiB |
| Virtualization.framework VM-service RSS | 201,920 KiB |
| VM-service process footprint | 155,976,472 bytes (148.7 MiB) |
| Worker and VM-service combined process footprint | 158,647,544 bytes (151.3 MiB) |
| Whole-Mac physical RAM | 16 GiB |
| Whole-Mac memory pressure available | 66% before VM; 66% across 3 idle-guest samples |
| Whole-Mac free pages | 40,330 before VM; 29,049–29,209 across 3 idle-guest samples |
| Copied store, logical file bytes | 151,145,470 bytes |
| Host load average, 1/5/15 minute, before | 2.33 / 3.58 / 3.59 |
| Host load average, 1/5/15 minute, after | 2.42 / 3.56 / 3.58 |

This is one local sample. It does not establish a performance change against earlier samples. The warm exec figure is command overhead through the guest control path, not isolated IPC latency. The whole-Mac memory values include unrelated host processes and must not be attributed to Rift. The VM-start metric ends at guest control-share readiness, before overlay setup and workload startup.

## Older cached benchmark

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `cdeb627`, benchmark script commit `fc4c3e5`, 2026-09-27 22:18:39 UTC. One run with the cached store:

| Metric | Result |
| --- | ---: |
| Local executable size | 1,782,832 bytes |
| First Alpine launch with cached assets | 1,213.6 ms |
| Subsequent Alpine launches, median of 5 | 1,141.8 ms |
| Subsequent Alpine launch samples | 1,104.1, 1,113.8, 1,148.4, 1,141.8, 1,149.9 ms |
| VM start to guest control ready | 433.6 ms |
| Detached run to workload-ready marker | 1,092.9 ms |
| Warm detached `rift exec <id> /bin/true`, median of 5 | 72.1 ms |
| Warm detached exec samples | 68.6, 75.5, 71.0, 72.1, 132.8 ms |
| `rift version`, median of 5 | 7.0 ms |
| Detached Rift worker RSS | 10,832 KiB |
| Virtualization.framework VM-service RSS | 201,504 KiB |
| VM-service process footprint | 156,058,440 bytes (148.8 MiB) |
| Worker and VM-service combined process footprint | 158,844,200 bytes (151.5 MiB) |
| Whole-Mac physical RAM | 16 GiB |
| Whole-Mac memory pressure available | 64% before VM; 64% across 3 idle-guest samples |
| Whole-Mac free pages | 61,715 before VM; 50,462–50,506 across 3 idle-guest samples |
| Copied store, logical file bytes | 151,145,470 bytes |
| Host load average, 1/5/15 minute, before | 3.41 / 3.68 / 3.86 |
| Host load average, 1/5/15 minute, after | 3.35 / 3.65 / 3.85 |

This is one local sample. The warm exec figure is command overhead through the guest control path, not isolated IPC latency. The whole-Mac memory values include unrelated host processes and must not be attributed to Rift. The VM-start metric ends at guest control-share readiness, before overlay setup and workload startup.

## Older cached benchmark

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `c5c3dd6`, 2026-09-27 20:36:44 UTC. One run with the cached store:

| Metric | Result |
| --- | ---: |
| Local executable size | 1,730,064 bytes |
| First Alpine launch with cached assets | 1,167.3 ms |
| Subsequent Alpine launches, median of 5 | 1,157.5 ms |
| Subsequent Alpine launch samples | 1,157.5, 1,189.8, 1,174.0, 1,137.6, 1,134.2 ms |
| VM start to guest control ready | 437.35 ms |
| Detached run to guest-ready marker | 1,733.7 ms |
| `rift version`, median of 5 | 7.1 ms |
| Detached Rift worker RSS | 10,848 KiB |
| Virtualization.framework VM-service RSS | 202,304 KiB |
| VM-service process footprint | 156,910,360 bytes (149.6 MiB) |
| Worker and VM-service combined process footprint | 159,712,504 bytes (152.3 MiB) |
| Copied store, logical file bytes | 151,145,470 bytes |
| Host load average, 1/5/15 minute, before and after | 4.46 / 4.35 / 4.41 |

The VM-start metric ends at guest control-share readiness, before overlay setup and workload startup. This and the `3ea8402` sample below recorded detached latency after RSS and footprint sampling; those values include that post-ready work and are not comparable with the corrected marker timestamp above.

## Homebrew first-use footprint

Apple M2, macOS 26.6, Homebrew formula `rift` v0.1.2, 2026-09-27. `brew test rift` passed. A clean temporary `HOME` ran `rift run --rm alpine echo RIFT_BREW_CLEAN_HOME_OK` successfully with both the Docker CLI and Docker Desktop absent.

| Component | Result |
| --- | ---: |
| Homebrew keg disk allocation (`du -sk`) | 1,724 KiB |
| Installed executable logical size | 1,728,992 bytes |
| First-use Alpine kernel and initramfs logical size | 46,402,986 bytes (44.3 MiB) |
| Guest asset directory disk allocation (`du -sk`) | 45,316 KiB |
| Keg plus guest asset disk allocation | 47,040 KiB (45.9 MiB) |
| Alpine image blobs and record in the fresh home | 4,198,660 logical bytes, separate from runtime install |

The Homebrew keg includes its executable, license, README, SBOM, formula source, and receipt; the formula has no runtime dependencies and uses Zig as a build dependency. Guest assets are downloaded on first use into `~/Library/Application Support/Rift/guest`. The combined allocation excludes image-cache data, the Zig build dependency, and unrelated files. Reproduce the directory sizes with `du -sk /opt/homebrew/Cellar/rift/0.1.2 "$HOME/Library/Application Support/Rift/guest"`; measure the executable's logical bytes with `stat -f '%z' /opt/homebrew/Cellar/rift/0.1.2/bin/rift`.

## Earlier cached benchmark

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `3ea8402`, 2026-09-27 20:25:08 UTC. One run with the cached store:

| Metric | Result |
| --- | ---: |
| Local executable size | 1,729,520 bytes |
| First Alpine launch with cached assets | 1,380.3 ms |
| Subsequent Alpine launches, median of 5 | 1,115.5 ms |
| Subsequent Alpine launch samples | 1,115.5, 1,112.3, 1,131.8, 1,131.0, 1,107.9 ms |
| `rift version`, median of 5 | 7.2 ms |
| Detached run to guest-ready marker | 1,717.1 ms |
| Detached Rift worker RSS | 10,688 KiB |
| Virtualization.framework VM-service RSS | 204,192 KiB |
| VM-service process footprint | 158,876,440 bytes (151.5 MiB) |
| Worker and VM-service combined process footprint | 161,580,280 bytes (154.1 MiB) |
| Copied store, logical file bytes | 151,145,470 bytes |
| Host load average, 1/5/15 minute, before | 2.98 / 4.58 / 4.86 |
| Host load average, 1/5/15 minute, after | 3.00 / 4.53 / 4.84 |

## Older cached benchmark

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `9f95df9`, 2026-09-27 19:57:42 UTC. One earlier run with the cached store:

| Metric | Result |
| --- | ---: |
| Local executable size | 1,729,376 bytes |
| First Alpine launch with cached assets | 1,433.4 ms |
| Subsequent Alpine launches, median of 5 | 1,115.4 ms |
| Subsequent Alpine launch samples | 1,103.4, 1,152.7, 1,111.4, 1,115.4, 1,160.7 ms |
| `rift version`, median of 5 | 7.0 ms |
| Detached Rift worker RSS | 10,688 KiB |
| Virtualization.framework VM-service RSS | 206,208 KiB |
| VM-service process footprint | 160,547,680 bytes (153.1 MiB) |
| Worker and VM-service combined process footprint | 163,235,136 bytes (155.7 MiB) |
| Copied store, logical file bytes | 151,145,470 bytes |
| Host load average, 1/5/15 minute, before | 5.44 / 4.47 / 4.64 |
| Host load average, 1/5/15 minute, after | 4.91 / 4.39 / 4.61 |

These process-attributed memory values are idle snapshots after the guest reports ready, not peak usage or whole-Mac memory. The separate whole-Mac snapshot is recorded in the latest result above.

Apple M2, macOS 26.6, Zig 0.16.0, `ReleaseSafe`, runtime commit `60000c7`, 2026-09-27 17:59:58 UTC. Earlier run with the cached store:

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

The cleanup preview identified 19,447 logical bytes in two unreferenced blobs; `clean --yes` removed them. Timings are one sample and include this Mac's network and host load. That historical run did not measure guest download time separately or total host-plus-VM memory. A temporary home does not stand in for a freshly provisioned Mac.

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

Subsequent launch samples: 1,007.5, 1,030.1, 1,028.8, 1,057.5, and 991.8 ms. This is one local run, not a cross-machine performance claim. This historical run predates the whole-Mac memory snapshots recorded above; larger-image startup remains unmeasured. The fresh-home sample above times public image pulls but does not establish repeatable throughput.
