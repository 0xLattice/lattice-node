#!/usr/bin/env bash
# Set the Nexus genesis timestamp and re-pin every copy of the genesis CID.
#
#   scripts/set-nexus-genesis-timestamp.sh <unix-milliseconds | now>
#
# The timestamp is the chain's real launch time. It is the only lower bound on
# block 1's timestamp, and block 1 anchors the ASERT schedule, so run this as
# close to the start of mining as the release allows (re-run it if the launch
# slips), then commit the result. It:
#   1. writes the timestamp into Sources/LatticeNode/Configuration/NexusGenesis.swift;
#   2. computes the resulting genesis CID with the canonical genesis test;
#   3. replaces the old CID in every tracked file (NexusGenesis.swift,
#      docs/protocol.md, docs/rpc-api.md, READMEs, smoke script, fixtures);
#   4. does the same for the mining-worker reference vector (a hash of the
#      genesis preimage, pinned in its test and docs/mining-workers.md);
#   5. re-runs both tests, which now pass with the new pins.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

genesis_file=Sources/LatticeNode/Configuration/NexusGenesis.swift

# A failed run restores the tracked tree, so it must start clean.
git diff --quiet HEAD || { echo "commit or stash tracked changes first" >&2; exit 1; }

ts="${1:?usage: $0 <unix-milliseconds | now>}"
now_ms=$(( $(date +%s) * 1000 ))
[ "$ts" = now ] && ts=$now_ms
if ! [[ "$ts" =~ ^[1-9][0-9]*$ ]]; then
  echo "timestamp must be positive unix milliseconds, got: $ts" >&2
  exit 1
fi
if [ "$ts" -gt "$now_ms" ]; then
  echo "timestamp $ts is in the future (now $now_ms): block 1 could not be admitted until then" >&2
  exit 1
fi
if [ "$ts" -lt 1000000000000 ]; then
  echo "timestamp $ts looks like seconds, not milliseconds" >&2
  exit 1
fi

genesis_test=NexusGenesisArchitectureTests/testCanonicalNexusGenesisIsDeterministicAndUnsigned
vector_test=MiningWorkerContractTests/testReferenceVectorMatchesConsensusPreimage
vector_file=Tests/LatticeNodeTests/Mining/MiningWorkerContractTests.swift

old_cid=$(sed -n 's/^ *"\(bafy[a-z0-9]*\)"$/\1/p' "$genesis_file")
[ -n "$old_cid" ] || { echo "no expectedBlockHash in $genesis_file" >&2; exit 1; }
old_vector=$(sed -n 's/^ *"\([0-9a-f]\{64\}\)"$/\1/p' "$vector_file")
[ -n "$old_vector" ] || { echo "no vectorHashHex in $vector_file" >&2; exit 1; }

# Only the config's `timestamp: <n>` line (the builder passes config.timestamp).
count=$(grep -cE '^ +timestamp: [0-9]+$' "$genesis_file")
[ "$count" = 1 ] || { echo "expected one 'timestamp: <n>' line, found $count" >&2; exit 1; }
sed -i.bak -E "s/^( +timestamp: )[0-9]+$/\1$ts/" "$genesis_file"
rm -f "$genesis_file.bak"

# repin <test> <old pin>: the test's pinned assertion fails and prints the
# computed value first; replace the old pin with it in every tracked file.
repin() {
  local out new
  out=$(swift test --filter "$1" 2>&1 || true)
  new=$(printf '%s\n' "$out" \
    | sed -n 's/.*XCTAssertEqual failed: ("\([a-z0-9]*\)") is not equal to ("'"$2"'").*/\1/p' \
    | head -1)
  if [ -z "$new" ]; then
    printf '%s\n' "$out" | tail -30 >&2
    if printf '%s\n' "$out" | grep -q 'XCTAssertEqual failed'; then
      echo "could not read the computed value for $2 from $1" >&2
    else
      echo "$1 did not report a new value: the build or test failed, or the pin is already current" >&2
    fi
    git checkout -- .
    exit 1
  fi
  git grep -l "$2" | while IFS= read -r file; do
    sed -i.bak "s/$2/$new/g" "$file"
    rm -f "$file.bak"
  done
  echo "$2 -> $new"
}

repin "$genesis_test" "$old_cid"
repin "$vector_test" "$old_vector"
swift test --filter "$genesis_test|$vector_test" >/dev/null
echo "timestamp $ts pinned; changed files:"
git status --short
