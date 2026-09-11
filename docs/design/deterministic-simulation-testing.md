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

## What is checked

## Determinism in Swift

## Relation to the existing tiers

## Boundaries
