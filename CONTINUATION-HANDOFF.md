# Authority Elimination / Parent Continuity Handoff

Last updated: 2026-07-27

## Status

This work is **not finished**.

This is a reviewable checkpoint, not a finished implementation.

The core authority-elimination implementation is published on the existing
draft PR, Lattice 26.0.8 is released, and the parent/child bootstrap regression
now passes. However, the full node suite has not run against this checkpoint,
and the last adversarial review found four implementation issues plus a
load-bearing E2E coverage gap. Resolve those findings in follow-up commits
before marking the PR ready for review or deployment.

## Repositories and pull requests

### lattice-node

- Path: `/Users/anonymous/src/lattice-node`
- Branch: `codex/foundational-architecture`
- Remote PR: [adalinxx/lattice-node#36](https://github.com/adalinxx/lattice-node/pull/36)
- Previous pushed HEAD: `f12f503c` (`Prove replica state after restart`)
- The authority-elimination checkpoint is the commit containing this document.
- Checkpoint diff: 27 implementation files, approximately 1,061 insertions and
  2,073 deletions, plus the north-star and handoff documents
- Dependency pin: exact Lattice `26.0.8`, revision `8022f565...`
- PR #36 is still a draft.
- CI for the checkpoint must be checked after its push; the previously observed
  green run belonged to `f12f503c`.

### Lattice

- Path: `/Users/anonymous/src/Lattice`
- Branch: `codex/foundational-architecture-alignment`
- Remote PR: [adalinxx/Lattice#5](https://github.com/adalinxx/Lattice/pull/5)
- HEAD: `8022f56` (`Return retryable child bootstrap evidence`)
- Tag: `26.0.8`
- Branch and tag are pushed.
- PR #5 CI is green at `8022f56`.
- The only local item is untracked `AGENTS.md`; it belongs to the user and must
  not be staged, edited, or deleted.

## North star

Read these first:

1. `/Users/anonymous/src/lattice-node/AGENTS.md`
2. `/Users/anonymous/src/lattice-node/AUTHORITY-ELIMINATION-KIT.md`
3. This handoff
4. The complete local diff in both repositories

The governing rule is:

> Parent genesis and parent-state continuity facts are gates only for child
> block submission/admission.

Therefore, those facts must not determine:

- content acquisition,
- proof or work verification,
- inherited-work relay,
- structural-evidence persistence,
- locally configured candidate retention,
- fork choice or canonicity.

Related invariants:

- Share availability; never share a verdict.
- Facts are unsigned, exact, session-bound, and supplied only by the immediate
  parent connection.
- A peer may provide content-addressed evidence because the bytes are locally
  verifiable, but it cannot assert that a parent accepted a transition.
- Work is counted once by grind identity.
- Work validity is independent of carrier block validity, canonicity, and
  connectivity.
- A carrier that is disconnected, target-missing, or otherwise inadmissible may
  still relay structurally verified work.
- Only a connected, locally accepted parent block may issue a parent genesis or
  continuity fact.
- Parent continuity means the new parent state is reachable through a valid
  same-chain sequence from the previous child block's parent state. It is not
  restricted to a direct parent block.
- Each hierarchy hop is immediate-parent scoped; the same rule composes for
  child, grandchild, and deeper chains.
- Ivy/VolumeBroker is the content-addressed availability layer. Evidence travels
  as complete, verifiable Volumes; no peer authority is attached to it.

Do not reintroduce:

- parent signatures,
- authority certificates,
- shared `validated` claims,
- recursive parent verdicts,
- consensus-dependent inherited work,
- a second local CID-level CAS beside VolumeBroker.

## What has been implemented locally

### Lattice releases

The relevant pushed sequence is:

- `9cf5e68`, tag `26.0.6`: separate carrier relay from chain admission
- `5ae6783`, tag `26.0.7`: bound parent continuity and expose relay verification
- `8022f56`, tag `26.0.8`: return retryable child-bootstrap evidence

Lattice now exposes verified carrier contribution independently from admission.
Parent continuity uses connected same-chain ancestry and has equal/direct fast
paths plus a reverse target-state search.

The 26.0.8 fix is important: child bootstrap previously threw
`crossChainEvidenceRequired`, discarding the verified carrier link and giving
lattice-node no structured requirement to query. Bootstrap now returns
`.rejected(failure, parentCarrierLink:)`, matching normal admission. This is
what fixed the real restarted-parent/child-bootstrap E2E failure.

### lattice-node

The local diff broadly does the following:

- Deletes signature/certificate authority:
  - `ParentFactCertificates.swift`
  - `ParentProcessKey.swift`
  - corresponding certificate tests
- Replaces certificates with exact parent fact request/response messages.
- Binds pending requests to the current immediate-parent session.
- Keeps content-addressed carrier evidence portable and independently
  verifiable.
- Persists relay evidence for disconnected/pre-genesis successors.
- Requeues an active candidate when a parent session disappears.
- Separates verified carrier work from admission outcome.
- Removes the obsolete `is_portable` persistence distinction; evidence is
  inherently portable.
- Removes stale authority-oriented documentation and updates the protocol,
  operations, modular pipeline, trust model, and testing docs.
- Pins Lattice exactly to 26.0.8.
- Removes all temporary debug logging used to diagnose bootstrap.

The reduction is intentional: the current node diff deletes roughly twice as
many lines as it adds.

## Validation completed

### Lattice 26.0.8

Command:

```sh
cd /Users/anonymous/src/Lattice
swift test
```

Result:

- 731 tests
- 0 failures
- approximately 170 seconds

The focused bootstrap regression also passed:

```sh
swift test \
  --filter ChainLocalAdmissionTests/testPublicBootstrapRequiresVerifiedGenesisAndStorage
```

### lattice-node

At Lattice 26.0.8, 151 focused architecture tests passed:

- `CandidateAcquirerTests`
- `ChainProcessTests`
- `NetworkTrust*Tests` (five suites over `NetworkTrustTestCase`)
- `NodeStoreTests`
- `PortableEvidenceProtocolTests`

After pinning Lattice 26.0.8, these realistic E2Es passed:

```text
testChildBootstrapsFromRestartedParentAndAdvancesInLiveRound
testFreshChildBootstrapsFromDurableParentSideBranchAfterReorg
testIntermediateTargetMissStillCarriesGrandchildWork
testNestedHardGenesisConstrainsRootSearchAndActivates
testSamePathReplicaRelaysHigherWorkAcrossRestartAndLateJoin
```

The first test had failed before 26.0.8 and is the regression proof for the
bootstrap retry bug.

What has **not** been run:

- the complete lattice-node suite against the current working tree,
- CI for the authority-elimination checkpoint.

## Unresolved adversarial findings

These came from the final read-only semantics review. Treat them as release
blockers unless deeper analysis disproves them.

### 1. P1: no-op state indexing can make continuity queries unbounded

Locations:

- `/Users/anonymous/src/Lattice/Sources/Lattice/Lattice/Chain.swift:649`
- `/Users/anonymous/src/Lattice/Sources/Lattice/Lattice/Chain.swift:977`
- `/Users/anonymous/src/Lattice/Sources/Lattice/Lattice/Chain.swift:1909`

`blocksByPostState` currently indexes every block, including the common
`prevState == postState` case. A popular unchanged state may therefore map to
millions of blocks. Each exact continuity query copies/sorts that set and walks
ancestry; concurrent authenticated child queries amplify the cost.

Recommended minimal correction:

- Index only state-entry transitions where `prevState != postState`.
- Keep the existing reflexive `from == to` fast path.

Why this is correctness-preserving: for a non-reflexive query `S -> T`, every
valid path must first enter `T` on an edge whose pre-state differs from its
post-state. A `T -> T` block is never a necessary reverse-search starting point.
Keep repeated non-self entries into `T` across forks.

This requires a new Lattice commit, full Lattice tests, a new tag (expected
`26.0.9`), and a lattice-node pin update.

### 2. P1: genesis-fact existence still gates acquisition/relay

Locations:

- `/Users/anonymous/src/lattice-node/Sources/LatticeNode/Architecture/NodeNetworkRuntime.swift:3299`
- `/Users/anonymous/src/lattice-node/Sources/LatticeNode/Architecture/NodeStore.swift:1801`

The runtime refuses/recycles a direct-child hierarchy session unless
`process.hasIssuedChildDirectory(directory)` succeeds, and the store returns no
outgoing child-evidence summaries without the same fact.

That makes a genesis fact control hierarchy connection/evidence enumeration,
contradicting the explicit “submission gate only” invariant.

Remove the fact as an availability/relay gate. Preserve chain namespace and
session isolation using the exact routed chain path/session, not a parent
admission verdict. The genesis fact should be consumed only when deciding
whether to admit the child genesis block.

### 3. P1: missing facts may still influence complete candidate persistence

Locations:

- `/Users/anonymous/src/Lattice/Sources/Lattice/Lattice/ChainLocalAdmission.swift:639`
- `/Users/anonymous/src/Lattice/Sources/Lattice/Lattice/ChainLocalAdmission.swift:933`
- `/Users/anonymous/src/lattice-node/Sources/LatticeNode/Architecture/ChainProcess.swift:689`

Missing parent evidence ends preflight before the complete validation Volume is
cached. lattice-node retains sparse carrier evidence, but not necessarily the
complete acquired candidate Volume.

The intended resolution follows the stated invariant:

- Acquisition may remain transient.
- If local node retention policy says to persist the acquired candidate, persist
  it before/independently of the parent-fact admission gate.
- Never force every node to archive every valid block.
- Parent facts may affect insertion/admission only; they must not override the
  node's own retention policy.

Add a test that distinguishes transient acquisition from configured durable
candidate retention while a parent fact is missing.

### 4. P2: duplicate parent query can defeat the per-peer concurrency guard

Location:

- `/Users/anonymous/src/lattice-node/Sources/LatticeNode/Architecture/NodeNetworkRuntime.swift:3018`

On a duplicate query or global-capacity rejection, the guard's failure path
unconditionally removes `peer.key` from `activeParentStateQueryPeers`, even
though this invocation did not insert it. A third request can then enter while
the first is still active.

Minimal correction:

1. Decode the request.
2. Check the global cap.
3. Insert the peer marker.
4. Remove the marker only in the `defer` owned by the invocation that inserted
   it.

Add a deterministic concurrency-limit test.

### 5. P1 test gap: no realistic non-equal continuity flow

Current tests cover serialization, graph reachability, nested genesis,
target-miss relay, disconnected-valid relay/promotion, reorg recovery, and late
join. They do not drive a non-equal parent-state continuity query through the
real node runtime.

Required realistic coverage:

- transitive continuity succeeds across more than one parent block,
- sideways/fork continuity is rejected,
- equal state requires no network query,
- response from an old parent session is ignored,
- no-response timeout leaves the candidate retryable,
- parent disconnect during a pending query requeues the candidate,
- parent and child restart around a pending/fulfilled continuity fact,
- three levels prove that each child queries only its immediate parent,
- an invalid carrier still relays independently verified work.

Use only real node-facing behavior in E2Es where practical: start/stop nodes,
connect peers, submit blocks/transactions, serve/fetch Volumes, and observe tips
or durable state. Keep malformed-wire and scheduler races as focused integration
tests rather than forcing them into subprocess E2Es.

## Recommended continuation order

1. Re-read the north star and trace each unresolved finding end to end.
2. Fix Lattice's no-op transition index.
3. Add focused Lattice correctness and performance-shape tests.
4. Run all 731+ Lattice tests.
5. Commit/push Lattice, tag the next patch release, and wait for PR #5 CI.
6. Update lattice-node's exact Lattice pin.
7. Fix the per-peer query guard.
8. Remove genesis-fact gating from hierarchy acquisition/relay.
9. Make candidate persistence obey only local retention policy.
10. Add the missing runtime/E2E continuity tests.
11. Rerun the focused architecture tests first.
12. Rerun the realistic parent/child E2Es.
13. Run the entire lattice-node suite.
14. Run at least two fresh read-only adversarial reviews:
    - semantic/security/performance invariants,
    - simplicity/code quality/test realism.
15. Resolve every concrete finding and repeat affected/full tests.
16. Inspect `git diff --check`, stale authority terminology, debug output, and
    both repository statuses.
17. Commit and push the follow-up corrections to the existing lattice-node
    branch after the above gates pass.
18. Verify PR #36 CI for each new head rather than relying on older green
    checks.

## Useful commands

```sh
# Inspect node work
cd /Users/anonymous/src/lattice-node
git status --short
git diff --check
git diff --stat
rg -n 'DEBUG |certificate|authority|ParentProcessKey|is_portable' \
  Sources Tests docs AUTHORITY-ELIMINATION-KIT.md

# Focused node architecture tests
swift test --filter \
  'CandidateAcquirerTests|ChainProcessTests|NetworkTrust|NodeStoreTests|PortableEvidenceProtocolTests'

# High-value parent/child E2Es
swift test --filter \
  'ParentChildE2ETests/(testChildBootstrapsFromRestartedParentAndAdvancesInLiveRound|testFreshChildBootstrapsFromDurableParentSideBranchAfterReorg|testIntermediateTargetMissStillCarriesGrandchildWork|testNestedHardGenesisConstrainsRootSearchAndActivates|testSamePathReplicaRelaysHigherWorkAcrossRestartAndLateJoin)'

# Complete node suite
swift test

# Lattice
cd /Users/anonymous/src/Lattice
git status --short
git diff --check
swift test

# PR state
gh pr view 5 --repo adalinxx/Lattice
gh pr view 36 --repo adalinxx/lattice-node
```

## Working-tree safety

- Do not reset away or rewrite the authority-elimination checkpoint; continue
  from it with reviewable follow-up commits.
- Do not stage `/Users/anonymous/src/Lattice/AGENTS.md`.
- Use explicit `git add` paths in Lattice.
- `AUTHORITY-ELIMINATION-KIT.md` and this handoff are intentionally part of the
  checkpoint.
- Do not treat an older PR #36 CI run as validation of a newer head.
