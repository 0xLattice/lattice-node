#!/bin/sh
# run.sh <bundle-dir> <dataset-dir> <cpus> <run-dir>: one follower sync of the
# recorded chain. A server container (CPUs 4-7, the same build) serves the
# dataset; the follower container gets <cpus> CPUs (pinned to 0..cpus-1) and
# the workers a host with that many CPUs runs (cpus - 1, at least 1), and keeps
# its data on the container filesystem, so every SQLite sync is a real fsync.
# Writes out, vfs.txt, trace, ref and chain.sha256 to <run-dir>. TRACE=0 skips
# the sync trace (no W/B/E/P split, no trace cost in wall, CPU and disk).
set -e
. "$(dirname "$0")/common.sh"
B=$(cd "$1" && pwd); D=$(cd "$2" && pwd); N=$3; mkdir -p "$4"; O=$(cd "$4" && pwd)
[ "$N" -ge 1 ] && [ "$N" -le 4 ] || { echo "cpus must be 1-4 (the server uses 4-7)"; exit 1; }
rm -f "$O/out" "$O/vfs.txt" "$O/trace"
cp "$B/ref" "$D/chain.sha256" "$O/"
image
SERVE=sync-bench-serve-$$
trap 'docker rm -f $SERVE > /dev/null 2>&1 || true' EXIT
docker run -d --name $SERVE --network host --cpuset-cpus 4-7 -v "$B":/bench:ro -v "$D":/data:ro $IMAGE sh -c "
  mkdir /chain && tar -C /chain -xf /data/chain.tar &&
  CHILD_BENCH=serve CHILD_BENCH_DIR=/chain CHILD_BENCH_SERVE=7200 \
    /bench/LatticeNodePackageTests.xctest LatticeNodeTests.ChildSyncBench/testServe" > /dev/null
for i in $(seq 120); do
  PEER=$(docker logs $SERVE 2>&1 | grep -o 'CHILD_BENCH serving [^ ]*' | cut -d' ' -f3)
  [ -n "$PEER" ] && break
  [ "$(docker inspect -f '{{.State.Running}}' $SERVE)" = true ] || break
  sleep 1
done
[ -n "$PEER" ] || { docker logs $SERVE 2>&1 | tail -20; echo "server did not start"; exit 1; }
# The trace goes to tmpfs: it costs CPU, not disk writes.
TRACE_ENV="LATTICE_SYNC_TRACE=/dev/shm/trace LATTICE_SYNC_TRACE_MAX_BYTES=0"
[ "${TRACE:-1}" = 0 ] && TRACE_ENV=
# What the follower keeps, when set here (README): passed through as set.
docker run --rm --network host --shm-size 1g --cpus $N --cpuset-cpus 0-$((N - 1)) \
  -e BENCH_STATE -e BENCH_BODIES -e BENCH_STATE_BUFFER \
  -v "$B":/bench:ro -v "$D":/data:ro -v "$O":/out $IMAGE sh -c "
  env CHILD_BENCH=follow CHILD_BENCH_WORKERS=$((N > 1 ? N - 1 : 1)) CHILD_BENCH_DIR=/follower \
    CHILD_BENCH_MANIFEST=/data/manifest.txt CHILD_BENCH_PEER=$PEER CHILD_BENCH_VFS=/out/vfs.txt $TRACE_ENV \
    /bench/LatticeNodePackageTests.xctest LatticeNodeTests.ChildSyncBench/testFollow > /out/out 2>&1
  status=\$?; [ -f /dev/shm/trace ] && cp /dev/shm/trace /out/trace; exit \$status"
grep '^CHILD_BENCH' "$O/out"
