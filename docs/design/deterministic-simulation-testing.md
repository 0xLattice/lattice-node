# Deterministic Simulation Testing

> **Status: proposed concept.** The normative consensus rules belong in
> Lattice's specification. This document states the testing problem those rules
> leave open in `lattice-node` and the concept that would close it.

## Problem

The node is tested well at every boundary it owns. Reducers are driven by
explicit events, components by latches and blocking content sources, the
network layer by real Ivy sessions on loopback, and the shipped binaries by
black-box multi-process E2Es that can cut a real link through a transparent TCP
fault proxy and suspend a process with `SIGSTOP`. CI adds strict concurrency
checking, ThreadSanitizer, ASan and UBSan over the hierarchy regressions,
reproducible release builds, and seeded fuzzing of the wire decoders and the
public read router (`WireProtocolFuzzTests`, `DaemonHTTPTests`). The stated test
bar in [testing](../testing.md) is boundary-focused rather than timing-focused:
assert explicit latches, persisted facts, or recorded requests.

That bar is right, and it leaves one class of failure without a home: failures
that depend on **which of several legal orders actually happened**. They are
not data races, so sanitizers and strict concurrency pass. They are not
malformed inputs, so fuzzing passes. A component test catches one only after
someone has already imagined the exact interleaving and built a latch for it.
The E2E tier reaches them by accident, through real scheduling on a loaded
runner, which is the one place a failure cannot be reproduced.

This repository's history records that class repeatedly.

### Flakes absorbed by time and retries

- Every E2E wait is multiplied by `E2E_TIME_SCALE`, set to 3 in every CI job
  (`.github/workflows/test.yml`, `release.yml`). The harness comment is candid
  that scaling "lengthens only genuinely failing runs", which is also why a slow
  run and a stuck run look the same until the deadline.
- Four merged changes wrap a swap step in retry-until-accepted because a
  dependent submit validates against state that lags its predecessor: the
  child-receipt submit (5de5dd5c), the grandchild withdrawal (bc9ca52b), the
  full-swap withdrawal (1f61087a, "third and last swap-E2E site of the recurring
  fail-closed 400 flake") and then every dependent submit (af33bd6b, "the
  carrier-link/state-lag race is not confined to the withdrawal").
- The deep churn tests are opt-in behind `LATTICE_E2E_DEEP_CHURN`
  (`ParentChildE2ETests`). The deep one is gated for cost (7aadea0d). The shallow
  twin is gated because it "wedge[s] on a shallow-gap content live-lock ... for
  10–20 minutes when they do"; its gating commit (1a18bb44) reports it failing
  4/4 recent runs, including on the pre-fix state, with the cause diagnosed from
  a log rather than reproduced.
- Test ports are probed below the ephemeral range because a released
  reservation can be handed to a concurrent outbound connection as its source
  port, killing the daemon with `EADDRINUSE` (`E2EPorts`).
- A coordinator test documents the "did not finish within 20 seconds" flake
  that only appeared under sustained instant-block mining on Linux
  (`MiningCoordinatorTests`).
- A convergence assertion compares both nodes live rather than against a
  snapshot, because "an equal-work same-height sibling (candidate relay races
  mint them) can deterministically replace the tip on BOTH nodes"
  (`ParentChildE2ETests`).

### Ordering bugs found by reading, not by testing

Several recent fixes are interleavings at actor suspension points that no test
had exercised until review named them:

- a hello path that silently dropped work when a range sync started between its
  two checks (504f77cd);
- an evidence wait that stayed suspended for the life of the process when a
  parent session dropped at the wrong moment (43431f87);
- a stale runtime releasing a reservation after stop and restart, either
  trapping or freeing a fresh runtime's reservation (45ba4560);
- a stale discovery creator evicting a fresh in-flight discovery after a
  stop/start cycle (e0bf5cc8).

Reproducing one after the fact needs a purpose-built hook: the validated-tip
eviction race is exercised by a DEBUG `demoteValidatedForTesting` call placed
"behind the probe's back" (`ChainServiceTests`). Each hook pins one ordering that
someone already suspected.

### The retired smoke harness

The JavaScript smoke harness removed in 17e5e8e9 carried the same lesson in its
comments. Its progress-aware wait existed because fixed deadlines are "the
single most common cause of flaky integration tests". Its runner capped workers
at the core count because CPU contention starving block production was "the
verified flake cause". It respawned nodes that crashed before RPC came up,
attributing that to "a transient resource race". A SIGKILL-mid-reorg scenario
accepted that "any kill timing still tests crash recovery", because the kill
point could not be chosen. A proof-backfill scenario declined to require a
baseline because "merged-mining live proof persistence is timing-flaky".

An earlier lineage of this repository, which the current main does not descend
from (for example d40f8eaa), went further and quarantined scenarios behind
`SMOKE_RUN_TASKALLOC_BUG` and `SMOKE_RUN_DEEPSWAP_BUG`. Its investigation notes
are the clearest statement of the problem. The deep swap stall was
"non-deterministic: which cycle dies, and the failure manifestation, vary across
runs", and it was pursued through five successive disproven hypotheses. The
task-allocator crash came back clean under ASan and TSan because sanitizers
"slow execution enough to close the race window". A two-node convergence flake
passed about 3 runs in 8 on unmodified main, and one of its causes was a
consensus rule violation that only an unlucky ordering exposed.

### What is missing

None of these failures lacked a test tier. They lacked **control**: the ability
to choose an interleaving, a crash point, a partition, a clock offset or a
misbehaving peer, to explore many of them cheaply, and to rerun the one that
failed exactly. Without control, the repository pays for this class three times:
in scaled deadlines and retries that hide it, in opt-in gates that remove it
from the merge path, and in investigations that begin from a log.

## Concept

**A simulation run is a pure function of its seed.** One run hosts one or many
nodes, each made of its real chain processes, and connects them through
simulated versions of everything the node does not decide for itself. The seed
chooses every outcome the production system leaves to its environment. The same
seed on the same build produces the same run, event for event.

### What the seed controls

- **Scheduling.** Which runnable piece of work proceeds next, at every point
  where production code could legally be interleaved with other work.
- **Network delivery.** Whether a message arrives, when, in what order relative
  to others, how many times, and whether a connection survives.
- **Disk.** Whether a write completes, how long it takes, what survives a crash,
  and whether the device reports an error or runs out of space.
- **Time.** What each node's clock reads. Simulated time advances only when the
  run chooses to advance it, so hours of retry windows, request timeouts and
  template lifetimes pass in the time it takes to run the code between them.
- **Randomness.** Every value a node would otherwise draw from the system:
  jitter, shuffles, nonces, session identifiers, nonce search order.

Anything not on this list and not deterministic by construction is a hole in the
simulation. A hole does not merely lower coverage. It breaks replay, which is the
property everything else depends on.

### Faults

Faults are drawn from the seed and applied to the simulated environment, never
by editing node state:

- **Partition and heal:** arbitrary, asymmetric, and possibly separating a child
  process from its configured immediate parent while leaving overlay peers
  reachable.
- **Delay, reorder, drop and duplicate** on every channel, including the
  hierarchy plane.
- **Crash and restart at arbitrary points**, including between any two durable
  writes and at any suspension point of an admission, eviction or evidence flow.
  A restarted node sees only what its simulated disk durably held.
- **Disk failure:** write errors, a full device, slow writes, and loss of
  anything not yet durable at the moment of a crash.
- **Clock skew and drift** per node, including a node whose clock runs ahead of
  honest block timestamps and one that runs behind them.
- **Slow and lying peers:** peers that stall, withhold bodies or evidence,
  serve bytes that do not match their CID, advertise content they do not hold,
  announce heights and tips they cannot back, or relay valid but irrelevant
  data. A peer is adversarial through what it sends, never through access to
  another node's internals.

A fault schedule is part of the run, not a separate script. The same seed
decides both the workload (transactions, mined blocks, child deployments,
joins) and the faults interleaved with it.

### Invariants are checked continuously

Checking only at the end asks whether the system recovered. Checking after every
step asks whether it was ever wrong. Safety properties are evaluated at every
observable step on every node and against a reference model fed the same facts.
A transient violation that later heals is still a failure: a node that briefly
served an invalid head or promised bytes it had lost did so to real peers.

Liveness properties are checked differently, because under partial synchrony a
slow peer and a stuck peer are indistinguishable at any single instant
([bulk sync](bulk-sync-stream.md)). A run stops injecting faults at a
seed-chosen point, lets simulated time pass, and then requires convergence
within a bound stated in simulated time. A liveness failure is a quiet network
in which progress should be possible and does not happen.

### Replay

A failure reports its seed and the build it ran on. Rerunning that seed replays
the run exactly, with any amount of tracing added, because tracing observes the
run without changing its choices. A replayed failure can be reduced by removing
faults and workload from its schedule while it still fails, and the reduced
schedule can be kept as a fixed regression. The repository's fuzzers already
hold this discipline for single inputs: a `WireProtocolFuzzTests` failure
records the generator state it started from so that "it replays exactly".
Simulation applies the same discipline to whole runs.

## What is checked

Invariants come from the specification and the design documents, not from the
simulation. Where a rule is normative in Lattice, the simulation checks the
node's observable behaviour against it; it does not restate it.

### Safety

1. **Fork choice matches a straightforward reference.** Given the same accepted
   blocks, verified grind locations and exclusions, every node's selected tip
   equals the tip chosen by a plain GHOST reference model: greatest effective
   `trueCumWork`, exact ties broken by the smaller segment-base CID, and no
   dependence on arrival or replay order. Sources: Lattice spec §9.2, §9.4 and
   §12.5 (items 4–6, 10); Lattice
   [consensus-fork-choice](https://github.com/adalinxx/Lattice/blob/30.4.0/docs/consensus-fork-choice.md);
   the exact reference gate in the
   [work-proof collapse north star](work-proof-collapse-north-star.md).
2. **One grind is counted once per location.** No root contributes more than its
   strongest target-derived bound at one chain-local location, a conflicting
   location is rejected atomically, distinct grinds sum, and replay never
   multiplies weight. Sources: spec §9.1 and §12.5 (items 3–4); north star gate
   items 1–2; [composable node architecture](modular-admission-pipeline.md).
3. **Work affects fork choice only once connected.** Effective weight contains
   only connected, accepted same-chain locations derived from verified proof
   bytes; carrier validity, admission and canonicity neither create nor remove
   it. Sources: spec §9.5 and §12.5 (items 2, 5, 7).
4. **Durability precedes visibility.** No graph mutation, canonical publication
   or served reference is observable before the batch behind it is durable, and a
   storage failure leaves the accepted graph unchanged. Sources: spec §9.3 and
   §9.8; NODE-STORAGE-002 in [correctness invariants](../correctness-invariants.md);
   the atomic mutation section of the composable node architecture.
5. **A reference never outlives its bytes.** After any crash, including one
   during eviction, no index, cursor or advertisement promises content the node
   no longer holds. Sources: NODE-STORAGE-002; the recovery invariant in
   [operator finality](operator-finality.md).
6. **Availability never becomes invalidity.** A timeout, withheld body, missing
   evidence or offline parent is retried and never recorded as a verdict, never
   excludes a block, and never penalizes the supplier. Only a completed
   deterministic check records invalidity. Sources: spec §9.9;
   [deferred execution](weight-first-acquisition.md) "Availability never judges";
   NODE-SEMANTICS-003 to 005; the absence rule in operator finality.
7. **Nothing is acted on from unvalidated weight.** Templates, served state,
   issued continuity facts and asserted heads come only from the validated tier,
   and unvalidated weight is never pivotal to a decision the node acts on.
   Sources: spec §9.9; the pivotality rule in deferred execution; the
   data-availability linchpin in bulk sync, which that document names "the one
   part to model adversarially first".
8. **Exclusion is durable and replayed identically.** An excluded subtree stays
   excluded across restart, is never resurrected by later work beneath it, and
   remains held and served. Sources: spec §9.9; "Exclusion is chain-local and
   never touches exported work" in deferred execution.
9. **Restart changes nothing without new facts.** A node's head after recovery
   equals its head before the crash given the same durable facts, and a retention
   setting never changes the selected head. Sources: spec §9.8; "Eviction is
   weight-preserving" in operator finality.
10. **Chain structure holds.** The tip is on the main chain and exists, the main
    chain is a connected path from one genesis root, a canonical delta's added
    and removed sets are disjoint, consecutive blocks satisfy state continuity,
    and a non-genesis child's parent-state reference only stays put or moves
    transitively forward through the immediate parent's graph. Sources: spec
    §12.1, §12.3 and §12.5 (item 8).
11. **Clock skew changes when, never whether.** A block from a node's future is
    deferred until that node's clock reaches it and is never permanently
    rejected; skew never changes which blocks are valid. Sources: spec §5.1 and
    §5.2 (`validationContext.now`).
12. **Deferral is invisible to decisions.** A deferred-execution node and a node
    that validated every block it obtained act identically on the same bytes. The
    simulation can run both side by side as a differential oracle. Source:
    "Acted-on decisions are uniform over obtained bytes" in deferred execution.
13. **Authority stays where it belongs.** No peer other than the authenticated
    immediate parent supplies a continuity or genesis verdict, and no content
    reaches state before its CID and evidence verify. Sources: the
    [process trust model](process-trust-model.md); spec §9.5.

### Liveness, after faults stop

14. **Honest nodes converge.** Once connectivity returns and the network is
    quiet, honest nodes holding the same facts select the same tip, whatever the
    arrival order and whether or not they restarted. Sources: north star gate
    items 7–8.
15. **No obligation is lost.** Every candidate that is available from some
    reachable honest peer is eventually admitted or explicitly invalidated; no
    ordering, backpressure or reset silently drops it. Sources: invariants 8 and
    9 and the acceptance criteria in [candidate acquisition](candidate-acquisition.md).
16. **State stays bounded.** Every retained collection respects its bound under
    any fault schedule. Source: candidate acquisition invariant 10.

The adversarial scenarios the north star lists (withholding and batched release,
balanced forks, eclipse and delay, equal-work ties, invalid carriers,
reordering, duplication, restart) are fault schedules in this model rather than
separate tests.

## Determinism in Swift

## Determinism in Swift

Deterministic simulation is easiest in a system designed for it from the first
line. `lattice-node` was not, and Swift makes several of the missing properties
hard to recover. This section states what is achievable and what is not.

### Why Swift resists it

- **The global executor is nondeterministic.** Unstructured tasks, task-group
  children and nonisolated async functions run on a shared thread pool whose
  job order user code does not choose. Two runs of the same test on the same
  machine can interleave differently, and a loaded runner interleaves
  differently again.
- **Actors are reentrant.** Every `await` inside an actor is a point at which
  another message may run and change the state the suspended code will resume
  with. The node knows this and defends against it by hand: `ChainProcess`
  queues admission and eviction because "actors are reentrant", and
  `ChainService` keeps "one externally observable order" because it "calls other
  actors and is therefore reentrant". The review-found bugs above are this
  hazard at places the defence did not cover. Strict concurrency rules out data
  races; it does not rule out an unlucky order of legal steps.
- **Time comes from the system.** The network runtime, template book and
  runtime caches read `ContinuousClock.now` or `Date()` directly, and the
  runtime waits with `Task.sleep` in roughly two dozen places. Tally's
  admission bookkeeping and VolumeBroker's `MemoryBroker` also read the clock
  directly. Even the test helper `TestBlockClock` in `NetworkTrustTests` is
  anchored to real wall time, because admission compares block timestamps with
  the real clock.
- **The network is real sockets.** Ivy builds SwiftNIO client, server and
  datagram bootstraps over the operating system's sockets. SwiftNIO event loops
  run on their own threads, outside Swift Concurrency's executor entirely.
- **Disk is real SQLite and a real broker.** `NodeStore` opens its database
  directly and `ChainProcess` holds a concrete `DiskBroker`. Durability timing
  and crash behaviour belong to the operating system.
- **Randomness is ambient.** Ivy draws reconnect jitter and session secrets from
  the system generator, the runtime shuffles hierarchy peers, and the stores
  mint `UUID`s.

### What is and is not achievable

Full determinism of the unmodified production binary is not achievable. The
achievable target is narrower and still valuable: **every piece of node logic
above a small set of seams runs deterministically, and everything below those
seams is simulated rather than real.**

Scheduling determinism means that all work belonging to the simulated nodes
runs on a single controlled executor, so only one job runs at a time and the
seed chooses the order. Swift provides legitimate tools for moving actor and
task work onto a chosen executor, and every task that escapes them reintroduces
the global pool. Serializing alone is not enough, because a serial executor with
a fixed order explores only one interleaving. The seed has to choose among the
runnable jobs.

Two consequences follow and should be accepted openly:

- **Simulation does not find true parallel data races.** A run that executes one
  job at a time cannot corrupt memory through simultaneous access. The
  task-allocator crash investigated in the earlier lineage would not reproduce.
  ThreadSanitizer, ASan and strict concurrency remain the tools for that class,
  and simulation is the tool for the class they cannot see.
- **Simulation does not test what it replaces.** Ivy's socket handling, SwiftNIO,
  SQLite's durability, the operating system's scheduler, and compiler or
  runtime defects stay outside the simulated world. The real-network and
  multi-process tiers keep owning them.

### Seams that already exist

The codebase already has boundaries a simulated environment could attach to,
because boundary-focused testing needed the same things:

- **Content.** Admission takes a cashew `ContentSource` (`InMemoryContentSource`,
  `FetcherContentSource`, `OverlayContentSource`), and component tests already
  substitute blocking, counting and recording sources. Ivy's content exchange
  is served through the `IvyContentSource` protocol, with test sources in
  `NetworkTrustTests`.
- **Service ports.** `ChainService` receives its network effects as injected
  closures: `validateBodySource`, `validateEvidenceSource`, the child-candidate
  provider and reconciler, and the block, transaction and proof publishers. Its
  validate-walk retry interval is a parameter. `NodeNetworkHandlers` is the
  same kind of boundary between the runtime and the service.
- **Pure reducers.** `CandidateAcquirer`, `ParentEvidenceFlow` and
  `ChildCandidateOwnership` are synchronous state machines that perform neither
  Ivy I/O nor consensus ([composable node architecture](modular-admission-pipeline.md)).
  `CandidateAcquirer` already takes time as an explicit `now:` argument, and its
  tests advance time by hand. These are already deterministic.
- **Validation time.** Lattice's admission accepts an explicit
  `ValidationContext` carrying the clock reading for one attempt, as spec §9.3
  requires. The node does not pass one today and so takes the wall-clock
  default. The seam exists and stops at the node boundary.
- **Peer delivery.** The node receives transport events through the
  `IvyDelegate` protocol, and tests already install recording delegates. Ivy's
  `PeerHealthMonitor` accepts injected `now` and nonce functions.
- **Storage.** The retained-root path is written against VolumeBroker's broker
  protocols, which lets `NodeStoreTests` interpose a `BlockingVolumeBroker`.
- **Precedent for seeded runs.** Lattice's `LatticeSim` drives the real
  `ChainState` fork choice from a seed and requires "the same trace
  byte-for-byte" ([consensus simulator](https://github.com/adalinxx/Lattice/blob/30.4.0/docs/consensus-simulator.md)).
  The wire fuzzers use a portable seeded generator rather than the system one.

### Where no seam exists

- **Scheduling.** Nothing today runs node work on an executor a test controls.
- **Outbound transport.** The runtime constructs its two Ivy instances itself,
  and Ivy's sockets have no in-memory substitute. Receiving is a seam; sending,
  connecting and disconnecting are not.
- **Runtime and mining time.** Deadlines, retry sleeps, template lifetimes and
  task-local budgets read the system clock directly.
- **Durable storage faults.** Nothing can fail, delay or lose a `NodeStore` write
  or a `DiskBroker` store on demand, or crash a process between two of them.
  Crash tests today open a fresh store over the same durable file at a point the
  test chose, or kill a real process at a moment the test does not control.
- **Randomness** in Ivy's jitter and secrets, the runtime's peer shuffle and
  identifier generation.
- **Dependencies.** Ivy, Tally, VolumeBroker and cashew are separate repositories
  pinned by release. Any seam inside them is a change in that repository first.

A seam is acceptable only when production behaviour through it is unchanged:
the production binding reads the real clock, opens the real socket and writes
the real disk. A seam that lets test code decide something production decides
differently turns the simulation into a test of itself.

## Relation to the existing tiers

Simulation is a new tier, not a replacement for the stack. Each existing tier
answers a question simulation cannot, and simulation answers one they cannot.

| Tier | Keeps owning | Relation to simulation |
|---|---|---|
| Reducer and unit tests (`CandidateAcquirerTests`, `AdmissionDecisionTests`) | Exact contracts of small state machines | Unchanged. The reducers run inside simulated nodes as they are. |
| Component tests with latches and blocking sources (`ChainProcessTests`, `ChainServiceTests`, `NodeStoreTests`) | One named interleaving, pinned forever | Complemented. Simulation searches for interleavings; a failing seed, once understood, can become a pinned component test. Purpose-built DEBUG ordering hooks become less necessary for discovery. |
| Real-network integration (`NetworkTrustTests`) | Ivy sessions, framing, authentication and delegate delivery over real sockets | Complemented. Simulation replaces the transport, so it cannot vouch for it. |
| Black-box E2E with real binaries (`LatticeNodeE2ETests`, `LatticeCtlE2ETests`, release smoke) | The shipped artifact: daemon startup, configuration, HTTP, real disk, real processes | Complemented. These stay the gate for the thing users run. Their role as the main place ordering bugs surface, and the need to absorb those bugs with scaled deadlines, retries and opt-in gates, moves to simulation. |
| Sanitizers and strict concurrency | Memory safety and true data races | Complemented. Simulation serializes execution, so it cannot see this class, and these tools cannot see logical interleavings. |
| Wire and read-router fuzzing | Hostile single inputs at the unauthenticated surfaces | Complemented. Fuzzing varies one message; simulation varies sequences, timing and faults. Both keep the same seed-and-replay discipline. |
| Lattice's `LatticeSim` and determinism goldens | Consensus rules and host-independent results | Complemented. The reference model for invariant 1 has the same shape as the frozen model the north star requires, and it may be shared rather than duplicated. |
| Reproducible builds | The binary is what the source says | Supports simulation. A seed replays only on the same build, and reproducible builds make "the same build" checkable. |
| Testnet and fleet operation | Real hardware, real latency, real operators | Complemented. Simulation reaches their failure modes before the fleet does, and cannot replace the fleet as the final judge. |

What simulation replaces is narrow and specific: **timing as the discovery
mechanism for ordering, crash, partition, skew and peer-misbehaviour bugs.** A
nondeterministic failure becomes a seed to replay instead of a quarantine to
maintain, and a convergence scenario becomes a fault schedule that runs in
simulated time instead of a CPU-bound wait that has to be scaled for CI.

## Boundaries

- **Consensus is untouched.** Simulation checks the node against Lattice's rules;
  it adds no rule, constant or threshold. Simulation parameters such as fault
  rates, partition lengths and convergence bounds are test choices, never
  protocol values.
- **Simulated nodes run production logic.** Everything above the seams is the
  code that ships. A simulation that reimplements node behaviour tests its own
  reimplementation.
- **Seams are consequence-free in production.** The production binding of every
  seam is the real clock, socket, disk and generator. No seam may give test
  code a decision that production makes differently, and no DEBUG-only path may
  be required to reach a state the simulation checks.
- **Adversaries act only through the environment.** Lying peers, lost writes and
  skewed clocks are applied to what a node receives or reads. Nothing edits a
  node's stores or in-memory state, the same rule the E2E tier already follows.
- **Proof of work stays real.** A simulated block is admitted because its hash
  beats its target, not because the simulation says so. Targets can be cheap,
  but they must not be the maximum target: the exclusion test (2f51a5f4) notes
  that its forgery passes only because the harness mines at the maximum target,
  and a maximum target can mask work-accounting defects. Nonce search order
  comes from the seed.
- **A passing seed is evidence, not proof.** Coverage is bounded by the fault
  model, the workload and the invariants. A property that is not written down is
  not checked, however many seeds pass.
- **Replay is the property that cannot be traded.** A source of nondeterminism
  left in the simulated world costs more than the coverage it seems to add,
  because it turns every failure back into a log to read.
