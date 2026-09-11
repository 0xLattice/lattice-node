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

## Relation to the existing tiers

## Boundaries
