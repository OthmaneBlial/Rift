#!/usr/bin/env python3
"""Measure a cached Alpine workflow without changing the user's Rift store."""

import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
import time


def run(binary: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"rift {' '.join(args)} failed ({result.returncode}): {result.stderr.strip()}")
    return result


def timed(binary: Path, env: dict[str, str], *args: str) -> float:
    start = time.perf_counter_ns()
    run(binary, env, *args)
    return (time.perf_counter_ns() - start) / 1_000_000


def copy_cache(source: Path, destination: Path) -> None:
    for section in ("images", "blobs", "guest"):
        if (source / section).is_symlink() or not (source / section).is_dir():
            raise RuntimeError(f"missing {section} cache; pull and run Alpine before benchmarking")
        for base, dirs, files in os.walk(source / section):
            base_path = Path(base)
            if any((base_path / name).is_symlink() for name in (*dirs, *files)):
                raise RuntimeError("Rift cache contains a symlink; refusing to copy it")
            target = destination / base_path.relative_to(source)
            target.mkdir(parents=True, exist_ok=True)
            for name in files:
                source_file = base_path / name
                if not source_file.is_file():
                    raise RuntimeError(f"unexpected non-file in cache: {source_file}")
                shutil.copy2(source_file, target / name)


def total_bytes(binary: Path, env: dict[str, str]) -> int:
    output = run(binary, env, "system", "df").stdout
    match = re.search(r"^TOTAL\t(\d+)\t\d+$", output, re.MULTILINE)
    if match is None:
        raise RuntimeError(f"could not read Rift disk report: {output}")
    return int(match.group(1))


def worker_rss_kib(identifier: str) -> int:
    output = subprocess.run(["ps", "-axo", "pid=,rss=,command="], capture_output=True, text=True, check=True).stdout
    workers = []
    for line in output.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and re.search(rf"(?:^|\s)_worker {identifier}(?:\s|$)", parts[2]):
            workers.append(int(parts[1]))
    if len(workers) != 1:
        raise RuntimeError(f"expected one Rift worker for {identifier}, found {len(workers)}")
    return workers[0]


def measure_worker(binary: Path, env: dict[str, str]) -> int:
    started = run(binary, env, "run", "-d", "alpine", "/bin/sh", "-c", "echo RIFT_BENCH_READY; sleep 60")
    identifier = started.stdout.strip()
    if re.fullmatch(r"[0-9a-f]{32}", identifier) is None:
        raise RuntimeError(f"invalid detached container ID: {identifier!r}")
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if "RIFT_BENCH_READY" in run(binary, env, "logs", identifier).stdout:
                samples = []
                for _ in range(3):
                    samples.append(worker_rss_kib(identifier))
                    time.sleep(0.1)
                return int(statistics.median(samples))
            time.sleep(0.1)
        raise RuntimeError(f"detached Alpine did not become ready: {run(binary, env, 'ps').stdout}")
    finally:
        stopped = subprocess.run([str(binary), "stop", identifier], env=env, capture_output=True, text=True, timeout=15)
        removed = subprocess.run([str(binary), "rm", identifier], env=env, capture_output=True, text=True, timeout=15)
        if stopped.returncode or removed.returncode:
            raise RuntimeError(f"could not clean up benchmark container: {stopped.stderr} {removed.stderr}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--samples", type=int, default=5)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("the VM benchmark requires an Apple Silicon Mac")
    if not 1 <= args.samples <= 100:
        parser.error("--samples must be between 1 and 100")
    binary = args.binary.resolve(strict=True)
    source = Path.home() / "Library/Application Support/Rift"
    with tempfile.TemporaryDirectory(prefix="rift-benchmark-") as home:
        copy_cache(source, Path(home) / "Library/Application Support/Rift")
        env = dict(os.environ, HOME=home)
        before = total_bytes(binary, env)
        load_before = os.getloadavg()
        first = timed(binary, env, "run", "alpine", "/bin/true")
        subsequent = [timed(binary, env, "run", "alpine", "/bin/true") for _ in range(args.samples)]
        cli = [timed(binary, env, "version") for _ in range(args.samples)]
        rss = measure_worker(binary, env)
        load_after = os.getloadavg()
        after = total_bytes(binary, env)
        if after != before:
            raise RuntimeError(f"storage changed after benchmark: {before} -> {after} logical bytes")
    result = {
        "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "host": {
            "macos": platform.mac_ver()[0],
            "architecture": platform.machine(),
            "cpu": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True, check=True).stdout.strip(),
            "logical_cpus": os.cpu_count(),
            "load_average_before": [round(value, 2) for value in load_before],
            "load_average_after": [round(value, 2) for value in load_after],
        },
        "binary_bytes": binary.stat().st_size,
        "store_logical_bytes": before,
        "first_cached_alpine_run_ms": round(first, 1),
        "subsequent_alpine_run_ms": [round(sample, 1) for sample in subsequent],
        "subsequent_alpine_median_ms": round(statistics.median(subsequent), 1),
        "version_ms": [round(sample, 1) for sample in cli],
        "version_median_ms": round(statistics.median(cli), 1),
        "detached_worker_rss_kib": rss,
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
