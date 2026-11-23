#!/bin/sh
# record.sh <bundle-dir> <dataset-dir> [alpha-blocks=3000] [leaves=2]: mines the
# benchmark chain once and saves it as <dataset-dir>/chain.tar, manifest.txt
# (each level's height and tip, and the share counts) and chain.sha256.
set -e
. "$(dirname "$0")/common.sh"
B=$(cd "$1" && pwd); mkdir -p "$2"; D=$(cd "$2" && pwd)
# build.sh names the suite; a bundle built before it did has it in LatticeNodeTests.
SUITE=$(cat "$B/suite" 2>/dev/null || echo LatticeNodeTests.ChildSyncBench)
image
# The node's SQLite needs a local filesystem: record inside the container, then copy out.
docker run --rm -v "$B":/bench:ro -v "$D":/out $IMAGE sh -c "
  set -e
  CHILD_BENCH=record CHILD_BENCH_DIR=/chain CHILD_BENCH_BLOCKS=${3:-3000} CHILD_BENCH_LEAVES=${4:-2} \
    /bench/LatticeNodePackageTests.xctest $SUITE/testRecord
  cp /chain/manifest.txt /out/ && tar -C /chain -cf /out/chain.tar . && cd /out && sha256sum chain.tar > chain.sha256"
cat "$D/manifest.txt" "$D/chain.sha256"
