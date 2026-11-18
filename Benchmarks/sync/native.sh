#!/bin/sh
# native.sh <work-dir> <workers> [repeats=1] [ref=HEAD]: the benchmark without
# containers, on this host (macOS or Linux). Builds <ref>'s release test bundle
# into <work-dir>/src (once per ref), records the chain into
# <work-dir>/data/chain (once), then syncs it <repeats> times with <workers>
# workers, each into <work-dir>/runs/w<workers>-<n>, ready for report.py.
#
# Nothing is pinned: the server and the follower share the host's CPUs. On
# macOS an fsync is not forced to the device, so disk timings understate
# Linux; counts (commits, fsyncs, bytes, jobs) and the per-level split hold.
# Compare runs from the same machine only.
set -e
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
mkdir -p "$1"; W=$(cd "$1" && pwd); N=$2; REPEATS=${3:-1}; REF=${4:-HEAD}
[ "$N" -ge 1 ] || { echo "workers must be at least 1"; exit 1; }
# Tests and smokes must never start a node on the built-in public peers.
export LATTICE_FORBID_DEFAULT_PEERS=1
WANT=$(git -C "$REPO" rev-parse "$REF")

if [ "$(cat "$W/ref" 2>/dev/null)" != "$WANT" ]; then
  mkdir -p "$W/src"
  find "$W/src" -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +
  git -C "$REPO" archive "$REF" | tar -x -C "$W/src"
  # Tests that use Ivy's debug-only dial hook do not compile in release.
  grep -rl 'setDialEndpointRewriteForTesting' "$W/src/Tests" | xargs rm -f
  (cd "$W/src" && swift build -c release --build-tests -Xswiftc -enable-testing)
  echo "$WANT" > "$W/ref"
fi

# SwiftPM names the bundle per target on macOS and per package on Linux.
B=$(ls -d "$W"/src/.build/release/LatticeNodeTests.xctest "$W"/src/.build/release/LatticeNodePackageTests.xctest 2>/dev/null | head -1)
[ -n "$B" ] || { echo "no test bundle under $W/src/.build/release"; exit 1; }
bench() {
  if [ "$(uname)" = Darwin ]; then xcrun xctest -XCTest "LatticeNodeTests.ChildSyncBench/$1" "$B"
  else "$B" "LatticeNodeTests.ChildSyncBench/$1"; fi
}

D=$W/data/chain
if [ ! -f "$D/manifest.txt" ]; then
  rm -rf "$D"; mkdir -p "$W/data"
  (export CHILD_BENCH=record CHILD_BENCH_DIR=$D CHILD_BENCH_BLOCKS=${BLOCKS:-3000} CHILD_BENCH_LEAVES=${LEAVES:-2}
   bench testRecord) > "$W/data/record.log" 2>&1 || { tail -20 "$W/data/record.log"; exit 1; }
fi
cat "$D/manifest.txt"

n=1
while [ "$n" -le "$REPEATS" ]; do
  O=$W/runs/w$N-$n; rm -rf "$O" "$W/follower"; mkdir -p "$O"; cp "$W/ref" "$O/ref"
  (export CHILD_BENCH=serve CHILD_BENCH_DIR=$D CHILD_BENCH_SERVE=7200; exec 2>&1; bench testServe) > "$O/serve.log" &
  SERVE=$!
  PEER=
  for i in $(seq 120); do
    PEER=$(grep -o 'CHILD_BENCH serving [^ ]*' "$O/serve.log" 2>/dev/null | cut -d' ' -f3)
    [ -n "$PEER" ] && break
    kill -0 $SERVE 2>/dev/null || break
    sleep 1
  done
  [ -n "$PEER" ] || { tail -20 "$O/serve.log"; echo "server did not start"; exit 1; }
  status=0
  (
    export CHILD_BENCH=follow CHILD_BENCH_WORKERS=$N CHILD_BENCH_DIR=$W/follower
    export CHILD_BENCH_MANIFEST=$D/manifest.txt CHILD_BENCH_PEER=$PEER CHILD_BENCH_VFS=$O/vfs.txt
    # TRACE=0 skips the sync trace: no W/B/E/P split, no trace cost.
    [ "${TRACE:-1}" = 0 ] || export LATTICE_SYNC_TRACE=$O/trace LATTICE_SYNC_TRACE_MAX_BYTES=0
    bench testFollow
  ) > "$O/out" 2>&1 || status=$?
  pkill -P $SERVE 2>/dev/null || true; kill $SERVE 2>/dev/null || true; wait $SERVE 2>/dev/null || true
  grep '^CHILD_BENCH follow' "$O/out" || { tail -20 "$O/out"; echo "run $n did not finish"; exit 1; }
  [ "$status" = 0 ] || { echo "run $n failed (see $O/out)"; exit 1; }
  n=$((n + 1))
done
