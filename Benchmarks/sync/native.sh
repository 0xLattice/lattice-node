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
#
# Optional, from the environment:
#   DATA=<dir>   the recorded chain (default <work-dir>/data/chain), recorded
#                there with BLOCKS, LEAVES and RATIO when it has no manifest.txt
#   RATIO=<r>    one Nexus block every r shares when recording (default 34;
#                1 makes every share a Nexus block: a Nexus-heavy chain of
#                about BLOCKS blocks, for HOSTED=0; at most 2,160 Nexus blocks,
#                as Nexus's difficulty doubles every 120 mined ahead of schedule)
#   TAG=<name>   run directories are <work-dir>/runs/<name>-<n> (default w<workers>)
#   HOSTED=<k>   the follower hosts Nexus and the first k child levels only
#                (it is given a manifest of those levels alone, so a ref
#                whose benchmark predates CHILD_BENCH_HOSTED does the same)
#   PAGES=<s>    bytes written by table and index, attributed every s seconds
#   TALLY=1      count the reads of each CID by the node's work (repeated decodes)
#   PROFILE=1    a CPU profile of the follower (macOS: sample) into sample.txt
#   TRACE=0      no sync trace
#   STALL=<s>    fail when the recording or a follower writes nothing for s
#                seconds (default 600), instead of waiting forever
# Each run also records the loopback interface's bytes before and after the
# follower's sync (net.txt): the server is on 127.0.0.1, so that is the
# traffic between them, plus whatever else this host sends over loopback.
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

# The benchmark is its own test target (ChildSyncBench); a ref from before
# that has it in LatticeNodeTests.
MODULE=LatticeNodeTests
[ -d "$W/src/Benchmarks/ChildSyncBench" ] && MODULE=ChildSyncBench
# SwiftPM names the bundle per target on macOS and per package on Linux.
B=$(ls -d "$W/src/.build/release/$MODULE.xctest" "$W"/src/.build/release/LatticeNodePackageTests.xctest 2>/dev/null | head -1)
[ -n "$B" ] || { echo "no test bundle under $W/src/.build/release"; exit 1; }
# Found once: xcrun's lookup can fail while another xcrun is running.
[ "$(uname)" = Darwin ] && XCTEST=$(xcrun --find xctest)
# On Linux, CPUS pins the process it runs to those CPUs (taskset): the
# follower to FOLLOWER_CPUS, the server to SERVER_CPUS, when set.
bench() {
  if [ "$(uname)" = Darwin ]; then "$XCTEST" -XCTest "$MODULE.ChildSyncBench/$1" "$B"
  elif [ -n "$CPUS" ]; then taskset -c "$CPUS" "$B" "$MODULE.ChildSyncBench/$1"
  else "$B" "$MODULE.ChildSyncBench/$1"; fi
}

# Bytes the loopback interface carried so far: received, sent.
net() {
  if [ "$(uname)" = Darwin ]; then netstat -ib -I lo0 | awk 'NR == 2 { print $6, $9 }'
  else echo "$(cat /sys/class/net/lo/statistics/rx_bytes) $(cat /sys/class/net/lo/statistics/tx_bytes)"; fi
}

# The recorder, the server, the follower and the profiler of the run in
# progress, stopped however the script ends.
RECORD= SERVE= FOLLOW= SAMPLE=
stop() {
  for p in $SAMPLE $FOLLOW $SERVE $RECORD; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
}
trap stop EXIT
trap 'stop; exit 130' INT TERM

# watch <pid> <path>...: waits while <pid> runs, and ends it (failing) when
# nothing under the paths, its output, has grown for STALL seconds.
watch() {
  p=$1; shift; last= quiet=0
  while kill -0 "$p" 2>/dev/null; do
    size=$(find "$@" -type f -exec ls -ln {} + 2>/dev/null | awk '{ s += $5 } END { print s + 0 }')
    if [ "$size" != "$last" ]; then last=$size quiet=0; else quiet=$((quiet + 1)); fi
    if [ "$quiet" -ge "${STALL:-600}" ]; then
      echo "no progress in ${STALL:-600} s: stopping"
      pkill -KILL -P "$p" 2>/dev/null || true; kill -KILL "$p" 2>/dev/null || true
      return 1
    fi
    sleep 1
  done
}

D=${DATA:-$W/data/chain}
if [ ! -f "$D/manifest.txt" ]; then
  # A chain is recorded only inside the work directory: DATA elsewhere must
  # already hold one, since recording starts by removing the directory.
  case $D in /*) A=$D ;; *) A=$PWD/$D ;; esac
  case $A in
    */../*|*/..) echo "DATA=$D: no '..' please"; exit 1 ;;
    "$W"/*) ;;
    *) echo "DATA=$D holds no manifest.txt and is outside $W: not recording there"; exit 1 ;;
  esac
  rm -rf "$D"; mkdir -p "$D"; D=$(cd "$D" && pwd); mkdir -p "$W/data"
  echo "recording into $D (progress in $W/data/record.log)"
  (export CHILD_BENCH=record CHILD_BENCH_DIR=$D CHILD_BENCH_BLOCKS=${BLOCKS:-3000} CHILD_BENCH_LEAVES=${LEAVES:-2} CHILD_BENCH_RATIO=${RATIO:-34}
   bench testRecord) > "$W/data/record.log" 2>&1 &
  RECORD=$!
  watch $RECORD "$W/data/record.log" || true
  wait $RECORD && [ -f "$D/manifest.txt" ] || { tail -20 "$W/data/record.log"; echo "recording failed"; exit 1; }
  RECORD=
fi
cat "$D/manifest.txt"

n=1
while [ "$n" -le "$REPEATS" ]; do
  O=$W/runs/${TAG:-w$N}-$n; rm -rf "$O" "$W/follower"; mkdir -p "$O"; cp "$W/ref" "$O/ref"
  (export CHILD_BENCH=serve CHILD_BENCH_DIR=$D CHILD_BENCH_SERVE=7200 CPUS=$SERVER_CPUS; exec 2>&1; bench testServe) > "$O/serve.log" &
  SERVE=$!
  PEER=
  for i in $(seq 120); do
    PEER=$(grep -o 'CHILD_BENCH serving [^ ]*' "$O/serve.log" 2>/dev/null | cut -d' ' -f3)
    [ -n "$PEER" ] && break
    kill -0 $SERVE 2>/dev/null || break
    sleep 1
  done
  [ -n "$PEER" ] || { tail -20 "$O/serve.log"; echo "server did not start"; exit 1; }  # stop() ends it
  M=$D/manifest.txt
  if [ -n "$HOSTED" ]; then
    # Nexus and the first HOSTED child levels, in the manifest's order.
    M=$O/manifest.txt
    awk -v k="$HOSTED" '/^level Nexus /{print; next} /^level /{if (n++ < k) print; next} {print}' "$D/manifest.txt" > "$M"
  fi
  status=0
  net > "$O/net.txt"
  (
    export CHILD_BENCH=follow CHILD_BENCH_WORKERS=$N CHILD_BENCH_DIR=$W/follower CPUS=$FOLLOWER_CPUS
    export CHILD_BENCH_MANIFEST=$M CHILD_BENCH_PEER=$PEER CHILD_BENCH_VFS=$O/vfs.txt
    # TRACE=0 skips the sync trace: no W/B/E/P split, no trace cost.
    [ "${TRACE:-1}" = 0 ] || export LATTICE_SYNC_TRACE=$O/trace LATTICE_SYNC_TRACE_MAX_BYTES=0
    [ -z "$HOSTED" ] || export CHILD_BENCH_HOSTED=$HOSTED
    [ -z "$PAGES" ] || export CHILD_BENCH_PAGES=$PAGES
    [ "${TALLY:-0}" = 0 ] || export LATTICE_READ_TALLY=1
    bench testFollow
  ) > "$O/out" 2>&1 &
  FOLLOW=$!; SAMPLE=
  if [ "${PROFILE:-0}" = 1 ]; then
    # The xctest the follow subshell started, once the follower is set up.
    F=
    for i in $(seq 100); do
      F=$(pgrep -P $FOLLOW | head -1)
      grep -q 'CHILD_BENCH follower' "$O/out" 2>/dev/null && break
      sleep 0.1
    done
    if [ -z "$F" ]; then echo "PROFILE=1: no follower process to sample" > "$O/sample.txt"
    elif [ "$(uname)" = Darwin ]; then sample "$F" 7200 1 -mayDie -file "$O/sample.txt" > /dev/null 2>&1 & SAMPLE=$!
    else echo "PROFILE=1 is macOS only (sample); use perf record -p on Linux" > "$O/sample.txt"; fi
  fi
  watch $FOLLOW "$O/out" "$O/trace" || true
  wait $FOLLOW || status=$?
  net >> "$O/net.txt"
  [ -z "$SAMPLE" ] || wait $SAMPLE
  pkill -P $SERVE 2>/dev/null || true; kill $SERVE 2>/dev/null || true; wait $SERVE 2>/dev/null || true
  SERVE= FOLLOW= SAMPLE=
  grep '^CHILD_BENCH follow' "$O/out" || { tail -20 "$O/out"; echo "run $n did not finish"; exit 1; }
  [ "$status" = 0 ] || { echo "run $n failed (see $O/out)"; exit 1; }
  n=$((n + 1))
done
