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
from typing import Optional


def run(binary: Path, env: dict[str, str], *args: str) -> subprocess.CompletedProcess[str]:
    result = subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError(f"rift {' '.join(args)} failed ({result.returncode}): {result.stderr.strip()}")
    return result


def timed(binary: Path, env: dict[str, str], *args: str) -> float:
    start = time.perf_counter_ns()
    run(binary, env, *args)
    return (time.perf_counter_ns() - start) / 1_000_000


def system_memory_snapshot() -> dict[str, object]:
    env = dict(os.environ, LC_ALL="C")
    result = subprocess.run(["vm_stat"], env=env, capture_output=True, text=True, check=True, timeout=10)
    page_size = re.search(r"page size of ([\d,]+) bytes", result.stdout)
    free_pages = re.search(r"^Pages free:\s*([\d,]+)", result.stdout, re.MULTILINE)
    if page_size is None or free_pages is None:
        raise RuntimeError(f"could not read system memory statistics from vm_stat: {result.stdout}")
    page_size_bytes = int(page_size.group(1).replace(",", ""))
    free_page_count = int(free_pages.group(1).replace(",", ""))
    memory_size = subprocess.run(["sysctl", "-n", "hw.memsize"], env=env, capture_output=True, text=True, check=True, timeout=10)
    physical_memory_bytes = int(memory_size.stdout.strip())
    free_page_bytes = free_page_count * page_size_bytes
    if page_size_bytes <= 0 or physical_memory_bytes % page_size_bytes or free_page_bytes > physical_memory_bytes:
        raise RuntimeError("system memory statistics are internally inconsistent")
    try:
        pressure = subprocess.run(["memory_pressure", "-Q"], env=env, capture_output=True, text=True, check=True, timeout=10)
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        pressure_free_percent = None
    else:
        match = re.search(r"System-wide memory free percentage:\s*(\d+)%", pressure.stdout)
        pressure_free_percent = int(match.group(1)) if match else None
        if pressure_free_percent is not None and not 0 <= pressure_free_percent <= 100:
            pressure_free_percent = None
    return {
        "physical_memory_bytes": physical_memory_bytes,
        "page_size_bytes": page_size_bytes,
        "free_pages": free_page_count,
        "free_page_bytes": free_page_bytes,
        "bytes_not_on_free_list": physical_memory_bytes - free_page_bytes,
        "memory_pressure_free_percent": pressure_free_percent,
    }


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


def process_rows() -> list[tuple[int, int, str]]:
    output = subprocess.run(["ps", "-axo", "pid=,rss=,command="], capture_output=True, text=True, check=True).stdout
    processes = []
    for line in output.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3:
            processes.append((int(parts[0]), int(parts[1]), parts[2]))
    return processes


def worker_process(identifier: str) -> tuple[int, int]:
    workers = [(pid, rss) for pid, rss, command in process_rows() if re.search(rf"(?:^|\s)_worker {identifier}(?:\s|$)", command)]
    if len(workers) != 1:
        raise RuntimeError(f"expected one Rift worker for {identifier}, found {len(workers)}")
    return workers[0]


def virtualization_processes() -> dict[int, int]:
    return {
        pid: rss
        for pid, rss, command in process_rows()
        if "com.apple.Virtualization.VirtualMachine" in command
    }


def process_footprints(pids: list[int]) -> Optional[tuple[int, dict[int, int]]]:
    with tempfile.TemporaryDirectory(prefix="rift-footprint-") as directory:
        report = Path(directory) / "footprint.json"
        command = ["/usr/bin/footprint", "--format", "bytes", "--noCategories", "--json", str(report)]
        for pid in pids:
            command.extend(("--pid", str(pid)))
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return None
        if result.returncode != 0:
            return None
        try:
            data = json.loads(report.read_text())
            per_process = {item["pid"]: item["footprint"] for item in data["processes"]}
            total = data["total footprint"]
        except (OSError, ValueError, KeyError, TypeError):
            return None
        if data.get("errors") or any(pid not in per_process for pid in pids):
            return None
        return int(total), {pid: int(per_process[pid]) for pid in pids}


def measure_worker(binary: Path, env: dict[str, str]) -> dict[str, object]:
    vm_processes_before = set(virtualization_processes())
    system_memory_before = system_memory_snapshot()
    run_started_ns = time.perf_counter_ns()
    started = run(binary, env, "run", "-d", "alpine", "/bin/sh", "-c", "echo RIFT_BENCH_READY; sleep 60")
    identifier = started.stdout.strip()
    if re.fullmatch(r"[0-9a-f]{32}", identifier) is None:
        raise RuntimeError(f"invalid detached container ID: {identifier!r}")
    boot_measurement = Path(env["HOME"]) / "Library/Application Support/Rift/runtime" / f"run-{identifier}" / "control/guest-boot-ms"
    guest_boot_ms = None
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if guest_boot_ms is None and boot_measurement.is_file():
                try:
                    guest_boot_ms = float(boot_measurement.read_text().strip())
                except (OSError, ValueError):
                    pass
            if "RIFT_BENCH_READY" in run(binary, env, "logs", identifier).stdout:
                if guest_boot_ms is None:
                    raise RuntimeError("detached VM exited or became ready without a guest boot measurement")
                detached_ready_ms = round((time.perf_counter_ns() - run_started_ns) / 1_000_000, 1)
                worker_rss = []
                vm_rss = []
                vm_footprints = []
                combined_footprints = []
                system_memory_samples = []
                vm_pid = None
                note = None
                for _ in range(3):
                    system_memory_samples.append(system_memory_snapshot())
                    worker_pid, worker_sample = worker_process(identifier)
                    worker_rss.append(worker_sample)
                    vm_processes = virtualization_processes()
                    candidates = set(vm_processes) - vm_processes_before
                    if len(candidates) != 1:
                        note = f"expected one new Virtualization.framework VM process, found {len(candidates)}"
                    else:
                        sample_vm_pid = candidates.pop()
                        if vm_pid is not None and sample_vm_pid != vm_pid:
                            note = "Virtualization.framework VM process changed during sampling"
                        else:
                            vm_pid = sample_vm_pid
                            vm_rss.append(vm_processes[vm_pid])
                            footprints = process_footprints([worker_pid, vm_pid])
                            if footprints is None:
                                note = "macOS footprint data was unavailable for the Rift worker and VM process"
                            else:
                                combined, per_process = footprints
                                combined_footprints.append(combined)
                                vm_footprints.append(per_process[vm_pid])
                    time.sleep(0.1)
                return {
                    "vm_start_to_guest_control_ready_ms": guest_boot_ms,
                    "detached_run_to_guest_ready_ms": detached_ready_ms,
                    "detached_worker_rss_kib": int(statistics.median(worker_rss)),
                    "virtualization_vm_service_rss_kib": int(statistics.median(vm_rss)) if len(vm_rss) == 3 else None,
                    "virtualization_vm_service_footprint_bytes": int(statistics.median(vm_footprints)) if len(vm_footprints) == 3 else None,
                    "worker_and_vm_process_footprint_bytes": int(statistics.median(combined_footprints)) if len(combined_footprints) == 3 else None,
                    "system_memory_before_vm": system_memory_before,
                    "system_memory_idle_guest_samples": system_memory_samples,
                    "memory_measurement_note": note,
                }
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
        env = dict(os.environ, HOME=home, RIFT_BENCHMARK_GUEST_BOOT="1")
        before = total_bytes(binary, env)
        load_before = os.getloadavg()
        first = timed(binary, env, "run", "alpine", "/bin/true")
        subsequent = [timed(binary, env, "run", "alpine", "/bin/true") for _ in range(args.samples)]
        cli = [timed(binary, env, "version") for _ in range(args.samples)]
        memory = measure_worker(binary, env)
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
        **memory,
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
