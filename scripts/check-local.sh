#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    printf '%s\n' "Rift's full local checks require macOS on Apple Silicon." >&2
    exit 2
fi

printf '%s\n' '==> Zig formatting'
zig fmt --check build.zig src

printf '%s\n' '==> Unit tests'
zig build test

printf '%s\n' '==> ReleaseSafe build'
zig build -Doptimize=ReleaseSafe

printf '%s\n' '==> Python check scripts'
python3 -m py_compile scripts/*.py

printf '%s\n' '==> Prepare pinned Linux guest'
python3 scripts/prepare_guest.py

for check in \
    run-check \
    vm-check \
    vm-share-check \
    vm-network-check \
    oci-vm-check \
    run-network-check \
    run-port-check \
    run-detached-check \
    run-exec-check \
    run-auto-pull-check \
    build-check \
    cache-lock-check \
    cache-prune-check \
    run-process-check \
    run-resources-check \
    run-volume-check \
    registry-auth-check
do
    printf '==> zig build %s\n' "$check"
    zig build "$check"
done
