# Testing

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

## Invariants pinned here

Tests require, among other things, that:

- Nexus reconstructs to the exact configured genesis CID;
- one `NodeBatch` commits facts and stream cursors for every affected path in
  one SQLite transaction;
- restart rebuilds Nexus and hosted children from the tree-wide journal;
- saved proof bytes decode and match their path, child, and grind indexes;
- normalized fact and accepted-block indexes exactly match immutable batches;
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
the nginx public-read allowlist, Docker builds, reproducible Linux builds, and
the dedicated operator E2E lane. Sanitizers run on main and merge-queue pushes.

Release jobs run on every pull request as well as release events. They package
all four operator binaries, run the genesis/mining/restart smoke, extract the
archive, and run the opt-in operator E2E against the archived binaries. Linux
also executes every shipped binary in a container with no Swift toolchain.
