#!/bin/sh
# build.sh <out-dir> [ref]: Linux release build (swift:6.1-jammy) of the test
# bundle at <ref> (default HEAD), copied to <out-dir>/LatticeNodePackageTests.xctest.
# Sources and .build live in $BENCH_WORK (default <repo>/.build/sync-bench), reused across refs.
set -e
. "$(dirname "$0")/common.sh"
mkdir -p "$1"; OUT=$(cd "$1" && pwd); REF=${2:-HEAD}
WORK=${BENCH_WORK:-$REPO/.build/sync-bench}
mkdir -p "$WORK/src"
find "$WORK/src" -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +
git -C "$REPO" archive "$REF" | tar -x -C "$WORK/src"
# Tests that use Ivy's debug-only dial hook do not compile in release.
grep -rl 'setDialEndpointRewriteForTesting' "$WORK/src/Tests" | xargs rm -f
image
docker run --rm -v "$WORK/src":/work -w /work $IMAGE \
  swift build -c release --build-tests -Xswiftc -enable-testing
cp "$WORK/src/.build/release/LatticeNodePackageTests.xctest" "$OUT/"
# The benchmark's test suite: its own target, or LatticeNodeTests in a ref from before.
if [ -d "$WORK/src/Benchmarks/ChildSyncBench" ]; then echo ChildSyncBench.ChildSyncBench; else echo LatticeNodeTests.ChildSyncBench; fi > "$OUT/suite"
echo "$(git -C "$REPO" rev-parse "$REF")" > "$OUT/ref"
echo "built $(cat "$OUT/ref") -> $OUT"
