#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Self-check fixture: a deliberate data race that ThreadSanitizer must report.
#
# We previously used `DispatchQueue.concurrentPerform` with 2,000 iterations of
# `box.value += 1`. On the Linux CI container that occasionally serialized (the
# pool collapsed to effectively one worker), so the racy read-modify-write never
# actually overlapped, tsan reported no race, and the gate falsely failed
# unrelated PRs (#169, #171, #175).
#
# This version makes the race RELIABLE: it spawns several long-lived Threads that
# each spin a tight, unsynchronized read-modify-write loop over many iterations on
# the same shared mutable `box.value`. With multiple dedicated threads (not a
# work-stealing pool) hammering the same word concurrently for a sustained period,
# the accesses provably overlap and tsan deterministically flags the race.
cat > "$tmp_dir/tsan-red-fixture.swift" <<'SWIFT'
import Foundation

final class Box {
    var value: Int = 0
}

let box = Box()
let threadCount = 8
let iterationsPerThread = 2_000_000
let group = DispatchGroup()

for _ in 0..<threadCount {
    group.enter()
    let thread = Thread {
        for _ in 0..<iterationsPerThread {
            // Unsynchronized read-modify-write on shared mutable state.
            box.value = box.value + 1
        }
        group.leave()
    }
    thread.stackSize = 1 << 20
    thread.start()
}

group.wait()
print(box.value)
SWIFT

swiftc -sanitize=thread "$tmp_dir/tsan-red-fixture.swift" -o "$tmp_dir/tsan-red-fixture"

fixture_status="$(
    python3 - "$tmp_dir/tsan-red-fixture" "$tmp_dir/tsan-red-fixture.out" <<'PY'
import os
import subprocess
import sys

binary, output = sys.argv[1], sys.argv[2]
env = os.environ.copy()
env["TSAN_OPTIONS"] = "halt_on_error=0:exitcode=66"
with open(output, "wb") as out:
    proc = subprocess.run([binary], stdout=out, stderr=subprocess.STDOUT, env=env)
print(proc.returncode if proc.returncode >= 0 else 128 - proc.returncode)
PY
)"

if [[ "$fixture_status" == "0" ]]; then
    cat "$tmp_dir/tsan-red-fixture.out" >&2
    echo "TSan red fixture was accepted without reporting a race" >&2
    exit 1
fi

if ! grep -q "ThreadSanitizer" "$tmp_dir/tsan-red-fixture.out"; then
    cat "$tmp_dir/tsan-red-fixture.out" >&2
    echo "TSan red fixture failed without a ThreadSanitizer report" >&2
    exit 1
fi

if [[ "${SKIP_TSAN_STRESS_TEST:-0}" == "1" ]]; then
    echo "TSan red fixture passed; skipping stress test because SKIP_TSAN_STRESS_TEST=1"
    exit 0
fi

export LATTICE_TSAN_STRESS=1
export TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1:exitcode=66:history_size=7}"

swift test --sanitize thread --filter NetworkTrustTests
