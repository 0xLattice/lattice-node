# Testing

## What a test states

A test states something an operator or a peer could observe: a node that
crashes comes back to the same tip with the same balances; two releases
follow each other's blocks; a transaction a node accepted is in a block. It
does not restate the implementation: it does not assert a setting's value,
count internal jobs or syncs, read a store's contents after a step, or walk
the branches of one function.

The check: would the test still pass if the code were rewritten with the
same behaviour? A test that would not breaks on a correct change and
catches nothing else. When a behavioural test could pass without the thing
it is about having happened, it asserts that premise once and says so. A
guarantee about a failure is tested by making the failure: what a crash or
a power cut leaves is put in front of a node, and the test states what the
operator then finds, not which calls were made on the way.

The default local suite covers the production runtime, storage, HTTP surface,
mining components, and fast deterministic core tests:

```sh
swift test --skip LatticeNodeSimulationTests
```

The long deterministic simulator has its own CI lane. Run the same five-seed
profile locally with:

```sh
SIM_SEEDS=5 swift test --filter LatticeNodeSimulationTests
```

## Suite ownership

- `LatticeNodeTests` covers the production shell: configuration, HTTP and
  public-read boundaries, wire codecs and fuzzing, metrics, runtime job order,
  merged mining, whole-tree restart, storage audits, retained content, and
  corruption refusal.
- `LatticeNodeSimulationTests` drives the synchronous core through partitions,
  loss, delay, crashes, invalid peers, reorgs, body unavailability, proof
  contention, and transaction workloads. The same seed reproduces the same
  run.
- `LatticeMinerCoreTests` and `LatticeMiningCoordinatorTests` cover target
  parsing, template freshness, nonce-range allocation, worker lifecycle,
  cancellation, and the current unversioned mining payloads.
- `LatticeNodeE2ETests` contains the opt-in `LatticeCtlE2ETests`. These launch
  the shipped `lattice`, `lattice-node`, coordinator, and miner as external
  processes, mine real blocks, create and resume a child chain, submit signed
  transactions, and verify state after restart.

  `TwoVersionE2ETests`, also opt-in, peers a node of an older release with a
  node of this build and has each follow the blocks the other mines.

Support utilities live under `Tests/LatticeNodeTests/Support`; they are test
infrastructure, not alternate runtime implementations.

## Operator E2E

Build the optimized binaries and test bundle first, then opt in explicitly:

```sh
swift build -c release -Xswiftc -warnings-as-errors
swift build --build-tests -Xswiftc -warnings-as-errors

E2E_CTL=1 \
E2E_CTL_BIN="$PWD/.build/release/lattice" \
E2E_NODE_BIN="$PWD/.build/release/lattice-node" \
E2E_COORDINATOR_BIN="$PWD/.build/release/lattice-mining-coordinator" \
E2E_MINER_BIN="$PWD/.build/release/lattice-miner" \
swift test --skip-build --filter LatticeCtlE2ETests
```

The E2E suite retains its temporary roots on failure and prints their paths.
Set `LATTICE_SYNC_TRACE=1` when diagnosing a sync failure.

## Two-version E2E

A change must leave this build working with the older releases still on the
network. Point `E2E_OLD_BIN_DIR` at the `bin` directory of an older release's
archive, with its checksum verified, and run:

```sh
swift build --build-tests -Xswiftc -warnings-as-errors
E2E_OLD_BIN_DIR=/path/to/lattice-node-4.0.0-macos-arm64/bin \
swift test --skip-build --filter TwoVersionE2ETests
```

Each release is driven through its own `lattice` CLI on loopback and read over
`/health`; neither host can reach the public peers. One host mines Nexus, the
other follows it to the same tip, in both directions. It covers Nexus blocks
only: not child chains, transactions or state reads between the two.

## Invariants pinned here

Tests require, among other things, that:

- Nexus reconstructs to the exact configured genesis CID;
- one `NodeBatch` commits facts and stream cursors for every affected path in
  one SQLite transaction;
- restart rebuilds Nexus and hosted children from the stored facts, with
  every weigh-log position unchanged;
- a saved proof, kept as its entries' CIDs, reads back byte for byte;
- an unknown hosted path is a 404 and `/v1/...` routes do not exist;
- a nested child genesis waits until its parent has executed a block of its
  own;
- the mining template digest changes for relevant input at any hosted level;
- submitted work stores only child blocks whose target the grind meets;
- no snapshot is published before the facts and referenced evidence are
  durable;
- network and pending queues remain bounded, and honest peers are not blamed
  for availability failures.

Consensus validation and signature rules are owned and tested by the pinned
Lattice dependency. VolumeBroker, cashew, Ivy, and Tally own their storage and
transport primitive suites; this repository tests the node-facing integration.

## CI and release gates

Pull requests run strict-concurrency builds on Linux and macOS, unit/integration
tests, the simulator, wire fuzzing, SwiftLint, deployment configuration checks,
Docker builds, reproducible Linux builds, the dedicated operator E2E lane, and
the two-version E2E against the older releases listed in the workflow, each pinned by sha256. Sanitizers run on main and merge-queue pushes.

Release jobs run on every pull request as well as release events. They package
all four operator binaries, run the genesis/mining/restart smoke, extract the
archive, and run the opt-in operator E2E against the archived binaries. Linux
also executes every shipped binary in a container with no Swift toolchain.
