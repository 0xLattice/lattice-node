# Deterministic Simulation Testing

> **Status: proposed concept.** The normative consensus rules belong in
> Lattice's specification. This document states the testing problem those rules
> leave open in `lattice-node` and the concept that would close it.

## Problem

The node is tested well at every boundary it owns:

- Reducers are driven by explicit events.
- Components are driven by latches and blocking content sources.
- The network layer is tested over real Ivy sessions on loopback.
- The shipped binaries run in black-box multi-process E2Es. These can cut a real
  link through a transparent TCP fault proxy and suspend a process with
  `SIGSTOP`.

CI adds:

- strict concurrency checking;
- ThreadSanitizer, plus ASan and UBSan over the hierarchy regressions;
- reproducible release builds;
- seeded fuzzing of the wire decoders (`WireProtocolFuzzTests`);
- an edge-case matrix over every parametered public read route
  (`DaemonHTTPTests`).

The stated test bar in [testing](../testing.md) is boundary-focused rather than
timing-focused. Tests assert explicit latches, persisted facts, or recorded
requests.

That bar is right, and it leaves one class of failure without a home: failures
that depend on **which of several legal orders actually happened**.

- They are not data races, so sanitizers and strict concurrency do not flag them.
- They are not malformed inputs, so fuzzing does not reach them.
- A component test catches one only after someone has imagined the exact
  interleaving and built a latch for it.
- The E2E tier reaches them only by accident, through real scheduling on a
  loaded runner. That is the one place a failure cannot be reproduced.

This repository's history records that class repeatedly.

### Timing absorbed by the E2E tier

- `E2E_TIME_SCALE` multiplies every E2E wait. It is set to 3 in the E2E jobs of
  `.github/workflows/test.yml` (`test-macos`, `test-linux`, `operator-cli-e2e`)
  and in both release artifact builds in `release.yml`. The harness comment is
  candid that scaling "lengthens only genuinely failing runs". That is also why a
  slow run and a stuck run look the same until the deadline.
- Four swap E2E steps now retry until accepted. In each case the test raced
  state that correctly lags on the node:
  - the grandchild withdrawal (bc9ca52b);
  - the child-receipt submit (5de5dd5c);
  - the full-swap withdrawal (1f61087a);
  - every other dependent submit (af33bd6b).

  These retries are correct client behaviour, not node defects. The node
  "correctly fail-closed 400s a withdrawal it cannot yet prove" (bc9ca52b), and a
  client must retry against lagging state. What they show is how the lag was
  found: "on slow runners it raced the carrier", surfacing as "four failures
  across unrelated PRs". It was not found as an ordering someone could choose
  and explore.
- The deep churn tests are opt-in behind `LATTICE_E2E_DEEP_CHURN`
  (`ParentChildE2ETests`).
  - The deep one is gated for cost (7aadea0d).
  - The shallow twin is gated because it "wedge[s] on a shallow-gap content
    live-lock ... for 10–20 minutes when they do". Its gating commit (1a18bb44)
    reports it failing 4/4 recent runs across two modes, including on the
    committed pre-fix state. The live-lock reproduces, but each reproduction
    costs a 10–20 minute wedge on a real runner. It was identified from a node
    log, and the scenario left the merge path rather than staying a gate.
- Test ports are probed below the ephemeral range. A released reservation can be
  handed to a concurrent outbound connection as its source port, killing the
  daemon with `EADDRINUSE` (`E2EPorts`).
- A coordinator test documents the "did not finish within 20 seconds" flake,
  which only appeared under sustained instant-block mining on Linux
  (`MiningCoordinatorTests`).
- A convergence assertion compares both nodes live rather than against a
  snapshot. The reason given is that "an equal-work same-height sibling
  (candidate relay races mint them) can deterministically replace the tip on
  BOTH nodes" (`ParentChildE2ETests`).

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

Reaching such an ordering in a test takes a purpose-built hook:

- 43431f87 added a DEBUG `resolveValidateEvidenceForTesting` seam so its
  evidence-wait paths could be driven.
- A related race is exercised by a DEBUG `demoteValidatedForTesting` call placed
  "behind the probe's back" (`ChainServiceTests`). In that race, a validated-tip
  probe could write back a floor that a concurrent eviction had demoted.

Each hook pins one ordering that someone already suspected.

### The retired smoke harness

The JavaScript smoke harness removed in 17e5e8e9 carried the same lesson in its
comments:

- Its progress-aware wait existed because fixed deadlines are "the single most
  common cause of flaky integration tests".
- Its runner capped workers at the core count because CPU contention starving
  block production was "the verified flake cause".
- It respawned nodes that crashed before RPC came up, attributing that to "a
  transient resource race".
- A SIGKILL-mid-reorg scenario was deliberately written so its assertions "hold
  no matter exactly when the SIGKILL lands relative to the reorg". That made it
  robust, and it also meant the mid-reorg window was a target it could aim at
  but not hit on demand.
- A proof-backfill scenario declined to require a baseline because
  "merged-mining live proof persistence is timing-flaky".

An earlier lineage of this repository went further. The current main does not
descend from it (for example d40f8eaa). That lineage quarantined scenarios behind
`SMOKE_RUN_TASKALLOC_BUG` and `SMOKE_RUN_DEEPSWAP_BUG`, and its investigation
notes are the clearest statement of the problem:

- **Deep swap stall.** It was "non-deterministic: which cycle dies, and the
  failure manifestation, vary across runs". It was pursued through five
  successive disproven hypotheses.
- **Task-allocator crash.** It came back clean under ASan and TSan. The notes
  give the reason: the task allocator is a custom bump allocator, so "ASan can't
  instrument it and TSan can't model it". Sanitizer slowdown also closed the race
  window.
- **Two-node convergence flake.** It passed about 3 runs in 8 on that lineage's
  unmodified main (248258d). One of its causes was the node adopting an
  equal-work peer tip, against the tie rule then in force that an exact tie holds
  the incumbent. Lattice spec §9.4 has since replaced that rule with a
  deterministic smaller-segment-base-CID tie-break.

### What is missing

None of these failures lacked a test tier. They lacked **control**:

- the ability to choose an interleaving, a crash point, a partition, a clock
  offset or a misbehaving peer;
- the ability to explore many of them cheaply;
- the ability to rerun the one that failed, exactly.

Without control, the repository pays for this class three times:

- in scaled deadlines that hide it;
- in opt-in gates that remove it from the merge path;
- in investigations that begin from a log.

## Concept

**A simulation run is a pure function of its seed.**

- One run hosts one or many nodes, each made of its real chain processes.
- The nodes are connected through simulated versions of everything a node does
  not decide for itself.
- The seed chooses every outcome the production system leaves to its
  environment.
- The same seed on the same build produces the same run, event for event.

### What the seed controls

- **Scheduling.** Which piece of work proceeds next, at every point where
  production code could legally be interleaved with other work. This includes
  when every suspended task resumes.
- **Network delivery.** Whether a message arrives, when, in what order relative
  to others, how many times, and whether a connection survives.
- **Disk.** Whether a write completes, how long it takes, what survives a crash,
  and whether the device reports an error or runs out of space.
- **Time.** What each node's clock reads. Simulated time advances only when the
  run chooses to advance it. Hours of retry windows, request timeouts and
  template lifetimes pass in the time it takes to run the code between them.
- **Randomness.** Every value a node would otherwise draw from the system:
  jitter, shuffles, nonces, session identifiers, nonce search order.

Anything not on this list and not deterministic by construction is a hole in the
simulation. A hole does not merely lower coverage. It breaks replay, which is the
property everything else depends on.

### Faults

Faults are drawn from the seed and applied to the simulated environment, never
by editing node state:

- **Partition and heal.** Partitions can be arbitrary and asymmetric. One can
  separate a child process from its configured immediate parent while leaving
  overlay peers reachable.
- **Delay, reorder, drop and duplicate** on every channel, including the
  hierarchy plane.
- **Crash and restart at arbitrary points.** This includes between any two
  durable writes, and at any suspension point of an admission, eviction or
  evidence flow. A restarted node sees only what its simulated disk durably held.
- **Disk failure.** Write errors, a full device, slow writes, and loss of
  anything not yet durable at the moment of a crash.
- **Clock skew and drift** per node. This includes a node whose clock runs ahead
  of honest block timestamps and one that runs behind them.
- **Slow and lying peers.** Peers that:
  - stall, or withhold bodies or evidence;
  - serve bytes that do not match their CID;
  - advertise content they do not hold;
  - announce heights and tips they cannot back;
  - relay valid but irrelevant data.

  A peer is adversarial through what it sends, never through access to another
  node's internals.

A fault schedule is part of the run, not a separate script. The same seed
decides both the workload (transactions, mined blocks, child deployments,
joins) and the faults interleaved with it.

### Invariants are checked continuously

Checking only at the end asks whether the system recovered. Checking after every
step asks whether it was ever wrong.

Safety properties are evaluated at every observable step, on every node, and
against a reference model fed the same facts. A transient violation that later
heals is still a failure. A node that briefly served an invalid head, or promised
bytes it had lost, did so to real peers.

Liveness properties are checked differently. Under partial synchrony, a slow
peer and a stuck peer are indistinguishable at any single instant
([bulk sync](bulk-sync-stream.md)). So a run:

1. stops injecting faults at a seed-chosen point;
2. lets simulated time pass;
3. then requires convergence within a bound stated in simulated time.

A liveness failure is a quiet network in which progress should be possible and
does not happen.

### Replay

A failure reports its seed and the build it ran on.

- Rerunning that seed replays the run exactly, with any amount of tracing added.
  Tracing observes the run without changing its choices.
- A replayed failure can be reduced by removing faults and workload from its
  schedule while it still fails.
- The reduced schedule can be kept as a fixed regression.

The repository's wire fuzzers already hold this discipline for single inputs. A
`WireProtocolFuzzTests` failure records the generator state it started from, so
that "it replays exactly". Simulation applies the same discipline to whole runs.

## What is checked

Invariants come from the specification and the design documents, not from the
simulation. Where a rule is normative in Lattice, the simulation checks the
node's observable behaviour against it; it does not restate it.

### Safety

1. **Fork choice matches a straightforward reference.** Take the facts a node
   holds: weighed blocks, verified grind locations and recorded exclusions.
   - The node's fork-choice head over those facts must equal the head a plain
     GHOST reference model selects from the same facts, with excluded subtrees
     removed.
   - The reference ranks by greatest effective `trueCumWork` and breaks exact
     ties by the smaller segment-base CID.
   - The result does not depend on arrival or replay order.

   This is the ranking head, which spec §9.9 allows to be merely weighed. The
   validated head the node acts on is checked by invariant 7. The north star's
   frozen reference model has no validation tier or exclusions, so it is the
   reference only where neither applies.

   Sources: Lattice spec §9.2, §9.4, §9.9 and §12.5 (items 4–6, 10); Lattice
   [consensus-fork-choice](https://github.com/adalinxx/Lattice/blob/30.4.0/docs/consensus-fork-choice.md);
   the exact reference gate in the
   [work-proof collapse north star](work-proof-collapse-north-star.md).
2. **One grind is counted once per location.**
   - No root contributes more than its strongest target-derived bound at one
     chain-local location.
   - A conflicting location is rejected atomically.
   - Distinct grinds sum.
   - Replay never multiplies weight.

   Sources: spec §9.1 and §12.5 (items 3–4); north star gate items 1–2;
   [composable node architecture](modular-admission-pipeline.md).
3. **Work counts only where the rules place it.**
   - Work verified along a proof path does not depend on the validity,
     admission, connectivity or canonicity of the intermediate carriers.
   - Effective weight contains only connected, accepted same-chain locations
     derived from verified proof bytes, outside any subtree excluded as proven
     invalid.
   - Parent canonicity alone never changes child weight.

   Sources: spec §9.5, §9.9 and §12.5 (items 2, 5, 7).
4. **Durability precedes visibility.** No graph mutation, canonical publication
   or served reference is observable before the batch behind it is durable. A
   storage failure leaves the accepted graph unchanged. Sources: spec §9.3 and
   §9.8; NODE-STORAGE-002 in [correctness invariants](../correctness-invariants.md);
   the atomic mutation section of the composable node architecture.
5. **A reference never outlives its bytes.** After any crash, including one
   during eviction, no index, cursor or advertisement promises content the node
   no longer holds. Sources: NODE-STORAGE-002; the recovery invariant in
   [operator finality](operator-finality.md).
6. **Availability never becomes invalidity.** A timeout, withheld body, missing
   evidence or offline parent is retried. It is never recorded as a verdict,
   never excludes a block, and never penalizes the supplier. Only a completed
   deterministic check records invalidity. Sources: spec §9.9;
   [deferred execution](weight-first-acquisition.md) "Availability never judges";
   NODE-SEMANTICS-003 to 005; the absence rule in operator finality.
7. **Nothing is acted on from unvalidated weight.** Templates, served state,
   issued continuity facts and asserted heads come only from the validated tier.
   Unvalidated weight is never pivotal to a decision the node acts on. Sources:
   spec §9.9; the pivotality rule in deferred execution; the data-availability
   linchpin in bulk sync, which that document names "the one part to model
   adversarially first".
8. **Exclusion is durable and replayed identically.** An excluded subtree stays
   excluded across restart. Later work beneath it never resurrects it, and it
   remains held and served. Sources: spec §9.9; "Exclusion is chain-local and
   never touches exported work" in deferred execution.
9. **Restart changes nothing without new facts.**
   - After recovery, a node's head is the head fork choice selects over its
     durable facts.
   - A crash between durable staging and in-memory application may leave the
     recovered head different from the pre-crash in-memory head, and that is
     correct.
   - A recovered head that differs from the one its durable facts determine is
     not correct.
   - A retention setting never changes the selected head.

   Sources: spec §9.8; "Eviction is weight-preserving" in operator finality.
10. **Chain structure holds.**
    - The tip exists and is on the main chain.
    - The main chain is a connected path from one genesis root.
    - A canonical delta's added and removed sets are disjoint.
    - Consecutive blocks satisfy state continuity.
    - A non-genesis child's parent-state reference only stays put or moves
      transitively forward through the immediate parent's graph.

    Sources: spec §12.1, §12.3 and §12.5 (item 8).
11. **Clock skew changes when, never whether.** A block from a node's future is
    deferred until that node's clock reaches it, and is never permanently
    rejected. Skew never changes which blocks are valid. Sources: spec §5.1 and
    §5.2 (`validationContext.now`).
12. **Deferral is invisible to decisions.** A deferred-execution node and a node
    that validated every block it obtained act identically on the same bytes.
    The simulation can run both side by side as a differential oracle. Source:
    "Acted-on decisions are uniform over obtained bytes" in deferred execution.
13. **Authority stays where it belongs.**
    - Continuity and genesis authority originates only in the authenticated
      immediate parent's validated graph.
    - The immutable fact may reach a node over any route, but no peer can
      originate one.
    - No content reaches state before its CID and evidence verify.

    Sources: the [process trust model](process-trust-model.md); spec §9.5.
14. **State stays bounded.** Every retained collection respects its bound at
    every step, under any fault schedule. Source: invariant 10 in
    [candidate acquisition](candidate-acquisition.md).

### Liveness, after faults stop

15. **Honest nodes converge.** Once connectivity returns and the network is
    quiet, honest nodes holding the same facts select the same tip. This holds
    whatever the arrival order and whether or not they restarted. Sources: north
    star gate items 7–8.
16. **No candidate is lost through ordering or backpressure.** Once faults stop,
    every candidate still advertised by a reachable honest peer is eventually
    admitted, rejected by a completed check, or acquired again. The property is
    re-acquisition, not retention of every attempt:
    - a runtime reset makes an in-flight completion stale (candidate acquisition
      invariant 9);
    - a bounded retry budget may reclaim an unresolvable park (1a18bb44).

    Sources: invariants 8–9 and the acceptance criteria in candidate acquisition.

The north star lists these adversarial scenarios:

- withholding and batched release;
- old-block targeting;
- balanced forks;
- subscription subsets;
- sibling co-commitment;
- eclipse and delay;
- equal-work ties;
- invalid carriers;
- reordering, duplication and restart.

In this model they are fault schedules rather than separate tests.

## Determinism in Swift

Deterministic simulation is easiest in a system designed for it from the first
line. `lattice-node` was not, and Swift makes several of the missing properties
hard to recover. This section states what is achievable and what is not.

### Why Swift resists it

- **The runtime chooses the order of ready work.** Actor jobs, nonisolated async
  functions, detached tasks and task-group children all run on a shared
  cooperative thread pool, in an order user code does not choose. Two runs of the
  same test on the same machine can interleave differently. A loaded runner
  interleaves differently again.
- **Actors are reentrant.** Every `await` inside an actor is a point at which
  another message may run and change the state the suspended code resumes with.
  The node defends against this by hand:
  - `ChainProcess` queues admission and eviction because "actors are reentrant".
  - `ChainService` keeps "one externally observable order" because it "calls
    other actors and is therefore reentrant".

  The review-found bugs above are this hazard at places the defence did not
  cover. Strict concurrency checking rules out data races in checked Swift code.
  It does not cover the `@unchecked Sendable` types in `IvyContentBridge`,
  `NodeNetworkRuntime` and `NodeSQLite`, or C and SwiftNIO code. It never rules
  out an unlucky order of legal steps.
- **Timers are scheduling.** A `Task.sleep` or clock deadline resumes when the
  runtime re-enqueues the sleeping task after its delay. Choosing the next job
  and deciding what time it is are therefore one decision, not two. Control over
  the order of ready work that does not also cover those delayed wakeups leaves
  every timeout and retry outside the seed.
- **Continuations cross threads.** A continuation can be resumed from a thread
  Swift Concurrency does not own: a SwiftNIO event loop, a Dispatch queue, or a
  `Process` termination handler. That hands work back at a moment chosen outside
  the executor. Ivy's content exchange suspends on checked continuations, so
  whatever resumes them decides when that work re-enters. A run with no escaping
  task still loses replay at each such resumption unless the resuming side is
  simulated too.
- **Time comes from the system.**
  - The network runtime, template book and runtime caches read
    `ContinuousClock.now` or `Date()` directly.
  - The runtime waits with `Task.sleep` in roughly two dozen places.
  - Tally's admission bookkeeping and VolumeBroker's `MemoryBroker` also read the
    clock directly.
  - Even the test helper `TestBlockClock` in `NetworkTrustTests` is anchored to
    real wall time, because admission compares block timestamps with the real
    clock.
- **The network is real sockets.** Ivy builds SwiftNIO client, server and
  datagram bootstraps over the operating system's sockets. SwiftNIO event loops
  run on their own threads, outside Swift Concurrency's executor entirely.
- **Disk is real SQLite and a real broker.** `NodeStore` opens its database
  directly, and `ChainProcess` holds a concrete `DiskBroker`. Durability timing
  and crash behaviour belong to the operating system.
- **Randomness is ambient.**
  - Ivy draws reconnect jitter and session secrets from the system generator.
  - The runtime shuffles hierarchy peers.
  - The stores mint `UUID`s.

### What is and is not achievable

Full determinism of the unmodified production binary is not achievable. The
achievable target is narrower and still valuable: **every piece of node logic
above a small set of seams runs deterministically, and everything below those
seams is simulated rather than real.**

Scheduling determinism is a requirement, not a mechanism: **the seed must
determine the order of all interleavable work belonging to the simulated nodes,
including every resumption after a suspension, a timer or a continuation.**
Running work one job at a time is not enough on its own, because a fixed serial
order explores a single interleaving.

The options differ in where they put the effort:

- confine simulated work to executors a test controls;
- move more logic into synchronous reducers, so that less of it is interleavable
  at all.

Each must account for every path by which work could escape it. Choosing among
them is an open question for this design.

Some consequences follow and should be accepted openly:

- **Simulation does not find true parallel data races.** A run whose
  interleavings come from the seed rather than from hardware parallelism does
  not reproduce corruption by simultaneous access. The task-allocator crash in
  the earlier lineage likely would not reproduce, if its cause was a parallel
  race. Its cause was never isolated. ThreadSanitizer, ASan and strict
  concurrency remain the tools for that class. Simulation is the tool for the
  class they cannot see.
- **Simulation does not see thread-pool starvation.** `NodeStore` is an actor
  that calls SQLite synchronously. Under real load, a blocking call holds a
  cooperative-pool thread for its duration and starves other work. In simulation
  no time passes during a synchronous call, so this class stays with the tiers
  that run real load.
- **Simulation does not test what it replaces.** These stay outside the simulated
  world, and the real-network and multi-process tiers keep owning them:
  - Ivy's socket handling and SwiftNIO;
  - SQLite's durability;
  - the operating system's scheduler;
  - compiler or runtime defects.

### Seams that already exist

The codebase already has boundaries a simulated environment could attach to,
because boundary-focused testing needed the same things:

- **Content.** Admission takes a cashew `ContentSource` (`InMemoryContentSource`,
  `FetcherContentSource`, `OverlayContentSource`). Component tests already
  substitute blocking, counting and recording sources. Ivy's content exchange is
  served through the `IvyContentSource` protocol, with test sources in
  `NetworkTrustTests`.
- **Service ports.** `ChainService` receives its network effects as injected
  closures:
  - `validateBodySource` and `validateEvidenceSource`;
  - the child-candidate provider and reconciler;
  - the block, transaction and proof publishers.

  Its validate-walk retry interval is a parameter. `NodeNetworkHandlers` is the
  same kind of boundary between the runtime and the service.
- **Pure reducers.** `CandidateAcquirer`, `ParentEvidenceFlow` and
  `ChildCandidateOwnership` are synchronous state machines that perform neither
  Ivy I/O nor consensus ([composable node architecture](modular-admission-pipeline.md)).
  `CandidateAcquirer` already takes time as an explicit `now:` argument, and its
  tests advance time by hand. These are already deterministic.
- **Validation time.** Lattice's admission accepts an explicit
  `ValidationContext` carrying the clock reading for one attempt, as spec §9.3
  requires. The node does not pass one today, so it takes the wall-clock default.
  The seam exists but stops at the node boundary.
- **Peer delivery.** The node receives transport events through the
  `IvyDelegate` protocol, and tests already install recording delegates.
- **Storage.** The retained-root path is written against VolumeBroker's broker
  protocols. This lets `NodeStoreTests` interpose a `BlockingVolumeBroker`.
- **Precedent for seeded runs.** Lattice's `LatticeSim` drives the real
  `ChainState` fork choice from a seed and requires "the same trace
  byte-for-byte" ([consensus simulator](https://github.com/adalinxx/Lattice/blob/30.4.0/docs/consensus-simulator.md)).
  The wire fuzzers use a portable seeded generator rather than the system one.

### Where no seam exists

- **Scheduling.** Nothing today lets a test choose the order in which node work
  runs or resumes.
- **Outbound transport.** The runtime constructs its two Ivy instances itself,
  and Ivy's sockets have no in-memory substitute. Receiving is a seam. Sending,
  connecting and disconnecting are not.
- **Runtime and mining time.** Deadlines, retry sleeps, template lifetimes and
  task-local budgets read the system clock directly.
- **Durable storage faults.** Nothing can fail, delay or lose a `NodeStore` write
  or a `DiskBroker` store on demand, or crash a process between two of them.
  Crash tests today either open a fresh store over the same durable file at a
  point the test chose, or kill a real process at a moment the test does not
  control.
- **Randomness** in Ivy's jitter and secrets, the runtime's peer shuffle, and
  identifier generation.
- **Dependencies.** Ivy, Tally, VolumeBroker and cashew are separate
  repositories, pinned by release. Any seam inside them is a change in that
  repository first. Some seams exist there but cannot be reached from the node.
  For example, Ivy's internal `PeerHealthMonitor` actor accepts injected `now`
  and nonce functions.

A seam is acceptable only when production behaviour through it is unchanged: the
production binding reads the real clock, opens the real socket and writes the
real disk. A seam that lets test code decide something production decides
differently turns the simulation into a test of itself.

## Relation to the existing tiers

Simulation is a new tier, not a replacement for the stack. Each existing tier
answers a question simulation cannot, and simulation answers one they cannot.

| Tier | Keeps owning | Relation to simulation |
|---|---|---|
| Reducer and unit tests (`CandidateAcquirerTests`, `AdmissionDecisionTests`) | Exact contracts of small state machines | Unchanged. The reducers run inside simulated nodes as they are. |
| Component tests with latches and blocking sources (`ChainProcessTests`, `ChainServiceTests`, `NodeStoreTests`) | One named interleaving, pinned forever | Complemented. Simulation searches for interleavings. A failing seed, once understood, can become a pinned component test. Purpose-built DEBUG ordering hooks become less necessary for discovery. |
| Real-network integration (`NetworkTrustTests`) | Ivy sessions, framing, authentication and delegate delivery over real sockets | Complemented. Simulation replaces the transport, so it cannot vouch for it. |
| Black-box E2E with real binaries (`LatticeNodeE2ETests`, `LatticeCtlE2ETests`, release smoke) | The shipped artifact: daemon startup, configuration, HTTP, real disk, real processes, real load | Complemented. These stay the gate for the thing users run. Two things move to simulation: their role as the main place ordering bugs surface, and the scaled deadlines and opt-in gates used to absorb those bugs. |
| Sanitizers and strict concurrency | Memory safety and true data races | Complemented. A simulation driven by the seed rather than by hardware parallelism cannot see this class, and these tools cannot see logical interleavings. |
| Wire fuzzing and the read-router edge-case matrix | Hostile single inputs at the unauthenticated surfaces | Complemented. They vary one input; simulation varies sequences, timing and faults. Simulation keeps the wire fuzzers' seed-and-replay discipline. |
| Lattice's `LatticeSim` and determinism goldens | Consensus rules and host-independent results | Complemented. Where no validation tier or exclusion is involved, the reference model for invariant 1 has the same shape as the frozen model the north star requires. It may be shared rather than duplicated. |
| Reproducible builds | The binary is what the source says | Supports simulation. A seed replays only on the same build, and reproducible builds make "the same build" checkable. |
| Testnet and fleet operation | Real hardware, real latency, real operators | Complemented. Simulation reaches their failure modes before the fleet does. It cannot replace the fleet as the final judge. |

What simulation replaces is narrow and specific: **timing as the discovery
mechanism for ordering, crash, partition, skew and peer-misbehaviour bugs.**

- A nondeterministic failure becomes a seed to replay, instead of a quarantine to
  maintain.
- A convergence scenario becomes a fault schedule that runs in simulated time,
  instead of a CPU-bound wait that has to be scaled for CI.

## Boundaries

- **Consensus is untouched.** Simulation checks the node against Lattice's rules;
  it adds no rule, constant or threshold. Simulation parameters, such as fault
  rates, partition lengths and convergence bounds, are test choices, never
  protocol values.
- **Simulated nodes run production logic.** Everything above the seams is the
  code that ships. A simulation that reimplements node behaviour tests its own
  reimplementation.
- **Seams are consequence-free in production.** The production binding of every
  seam is the real clock, socket, disk and generator. No seam may give test code
  a decision that production makes differently. No DEBUG-only path may be
  required to reach a state the simulation checks.
- **Adversaries act only through the environment.** Lying peers, lost writes and
  skewed clocks are applied to what a node receives or reads. Nothing edits a
  node's stores or in-memory state, which is the rule the E2E tier already
  follows.
- **Proof of work stays real.** A simulated block is admitted because its hash
  beats its target, not because the simulation says so.
  - Targets can be cheap, but they must not all be the maximum target. At the
    maximum target every hash is a hit, so the target-miss path in spec §9.3 is
    never exercised.
  - The exclusion test (2f51a5f4) states that its forgery passes only because the
    harness mines at the maximum target. It asserts that precondition rather than
    assuming it.
  - Nonce search order comes from the seed.
- **A passing seed is evidence, not proof.** Coverage is bounded by the fault
  model, the workload and the invariants. A property that is not written down is
  not checked, however many seeds pass.
- **Replay is the property that cannot be traded.** A source of nondeterminism
  left in the simulated world costs more than the coverage it seems to add,
  because it turns every failure back into a log to read.
