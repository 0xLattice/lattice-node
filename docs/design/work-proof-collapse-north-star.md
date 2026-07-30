# Work-Proof Collapse North Star

Status: implemented north star. The normative consensus rules belong in
Lattice's specification; this document fixes the motivation, invariants,
delivery order, and verification gate for the coordinated Lattice and
lattice-node changes.

## Motivation

Child security is the physical work that explicitly commits to a child block.
It does not grow merely because a later parent block descends from a carrier.
Every accepted child block therefore receives ordinary, immutable work facts
derived from content-addressed proofs. Once admitted, normal same-chain GHOST
is sufficient.

This removes the exceptional live inherited-work projection. It also preserves
Lattice's central property: content-addressed data is portable and verifiable,
while each chain remains sovereign over validity, storage policy, and fork
choice.

## Three graphs, three questions

Never use one graph as evidence for another:

1. The directory-commitment graph proves which block a grind explicitly
   commits to and how much real work that grind contributes.
2. The immediate parent's accepted state-transition graph proves that a
   child's parent-state reference moves forward along a connected, valid
   parent history.
3. The child's accepted-block graph routes admitted work through segment GHOST.

Directory descent is not parent-chain descent. A root may descend through
several child directories in one proof. A later block in the parent's own chain
adds no child work unless it explicitly commits to the child.

## Securing-work rule

A work proof is valid when all of the following hold:

- Every supplied block is bound to its canonical CID bytes.
- The root's proof-of-work hash is computed from those bytes.
- The sparse directory path resolves uniquely to the exact terminal child.
- Every vertical hop binds `child.parentState` to `carrier.prevState`.
- The root hash beats the terminal child's target.
- The proof uses one canonical root CID as its grind identity.

The blocks on the directory path do not need to be valid, admitted, connected,
or canonical on their own chains. Work validity is deliberately orthogonal to
block validity.

The contribution of one root to one child location is:

```
max(workForTarget(block.target))
```

over every content-bound block on the committed directory path whose target is
beaten by the root hash. The terminal child's target must be beaten. Repeated
evidence for the same grind and child location keeps the maximum. Conflicting
claims for one grind and chain-local location are rejected. Different grind
identities sum. A proof cannot affect fork choice until its terminal child is
accepted and connected in that child's chain.

Proof-derived contributions become ordinary `VerifiedWorkContribution` facts.
There is no inherited branch in GHOST.

## Parent-state continuity

For a non-genesis child candidate `C` with same-chain predecessor `P`:

```
old = P.parentState
new = C.parentState
```

Continuity succeeds when `old == new`, or when the immediate parent's accepted
state-transition graph contains a connected path:

```
P1.prevState == old
Pi.parent == CID(Pi-1)
Pi.prevState == Pi-1.postState
Pk.postState == new
```

This is reflexive, transitive reachability, not direct adjacency. A connected,
state-valid noncanonical parent branch is sufficient; parent canonicity does
not alter the fact. Backward, sideways, unrelated, or disconnected movement is
invalid. Repeated state roots use existential reachability rather than a
hidden arrival-dependent anchor.

The terminal directory carrier must separately bind
`child.parentState == carrier.prevState`. The carrier itself need not be a
valid parent block: its entering state must simply be a state the parent
legitimately reached.

Each chain process already durably records every connected block only after
semantic validation. That recovered `ChainBlockFact` graph is the transition
store; no second delta database or header replay protocol exists.

Equal-state movement needs no fact. Otherwise the child sends the exact
`(old, new)` pair over its authenticated immediate-parent session. The parent
answers positively only when its own recovered graph contains the forward path.
The child then constructs the non-Codable
`ParentStateContinuityLink(parentPath, old, new)` locally for this admission
attempt. The acknowledgement is unsigned, session-bound, and not portable.
Silence or timeout means retryable unavailability.

Grandparent validity follows by induction. A parent block cannot enter the
parent process's durable graph until that process has applied the same rule
against its immediate parent. The child never receives the grandparent tree,
header path, or verdict. Nexus terminates the induction.

Child genesis uses the same narrow boundary. The parent answers only when an
accepted parent block contains the exact `GenesisAction(directory, childCID)`.
The fact also binds `deploymentBlock.prevState`, and the child requires
`childGenesis.parentState` to equal it. A structural carrier that was not
accepted on the parent chain can prove work but cannot authorize deployment.

Arbitrary peers may supply any required content-addressed Volume. They never
supply a validity verdict. A configured remote parent can lie, so production
deployments should run and validate their own chain processes recursively to
Nexus; otherwise that remote process is an explicit operational trust boundary.

This is a named residual, not an oversight: the ack is unsigned and
non-portable, so a Byzantine configured parent can equivocate — answering
"reachable" to one child node and staying silent to another — and split
followers of the same child chain with no cryptographic evidence of the
equivocation. An authenticated parent session proves identity, never honesty.
A portable equivocation certificate is exactly the light-client artifact this
design forbids; the protection is running your own parent recursively.

## Data and process boundaries

- `ChildBlockProof` and its canonical proof-only
  `ChildValidationPackageEnvelope` carry securing-work evidence.
- `ChildEvidenceVolume` remains the one canonical Volume boundary. Ivy and
  VolumeBroker move Volumes, not loose CIDs or a second local CAS.
- Each chain derives validity from its own acquired Volumes. Cross-chain
  continuity and deployment use only an exact positive acknowledgement from
  the authenticated immediate-parent process's recovered validated graph.
- Temporary acquired Volumes may be resolved in memory and discarded. Durable
  facts retain every Volume needed to replay or regenerate their verification.
- Proofs are regenerated from retained root, intermediate carrier, children
  trie, and terminal closure when that full closure exists; otherwise they are
  reacquired through normal advertised-Volume discovery.
- Gossip, sync, acquisition, and persistence may run asynchronously.
  Chain insertion and fork choice consume only complete, durable admission
  batches.
- A child advances its parent-evidence scan cursor only through evidence it
  has admitted or durably retained. Its node-local inbox capacity applies
  backpressure without eviction, cursor advance, or peer punishment.
- Committing a reserved child candidate atomically transfers that exact
  candidate from reservation to durable handoff ownership. Other outstanding
  templates cannot reserve the handed-off candidate in the same update.

Unknown-child proofs are bounded per peer and globally. Triggered sync is
rate- and concurrency-limited. A valid proof for a child that has not yet
arrived is not punishable; lying about advertised availability or returning
malformed bytes is.

## Reuse and deletion

Reuse:

- `ChildBlockProof`, `DirectChildHop`, proof composition
- `VerifiedChildEvidence`, `VerifiedWorkContribution`
- `WorkMeasure`, `WorkSum`, segment GHOST
- `ChildEvidenceVolume`, `ChildValidationPackageEnvelope`
- `CandidateAcquirer`, fixed-cut inventory, NodeStore atomic batches
- Ivy routing and VolumeBroker storage

Do not add a generic forest, accumulator, light-client protocol, quorum,
second CAS, or second fork-choice implementation.

Delete only after the gate below passes:

- securing/inherited-work request and push topics
- inherited-work snapshots, revisions, completion markers, and projections
- parent-work SQL facts and cursors
- parent-work readiness and `awaitingParent`
- the inherited-work branch in GHOST

## Verification gates

### Exact reference gate

The old trusted feed is not a valid oracle: it credited later parent work that
did not necessarily commit to the child, which is the behavior this design
removes. Compare the optimized implementation instead with a frozen reference
model containing only accepted child blocks, proof-derived grind locations,
connectivity, exact `WorkMeasure`, and straightforward GHOST. Exact measures
and selected tips must match across randomized mutation order and replay.

### Adversarial security gate

Freeze a reference model before running the optimized implementation. The
model contains only a child block tree, proof-derived grind locations,
connectivity, exact `WorkMeasure`, and straightforward GHOST.

Exercise withholding and batched release, old-block targeting, balanced forks,
subscription subsets, sibling co-commitment, eclipse and delay, equal-work
ties, invalid carriers, reordering, duplication, and restart.

The replacement passes only when:

1. No root contributes more than its strongest target-derived bound.
2. No root is counted twice at one chain-local location.
3. Optimized and reference totals and tips match exactly.
4. No branch gains weight without equivalent physical work.
5. The predeclared upper confidence bound for reorganization probability stays
   below the deployment safety target at the required confirmation margin.
6. No tested strategy beats the explicit-PoW-vote reference attacker outside
   statistical error.
7. Honest nodes converge after connectivity returns.
8. Results are invariant to arrival order and restart.

The threat envelope, parameter sweep, safety target, margin, sample count, and
confidence method must be committed before results are generated. Failure
keeps the trusted feed in place.

## Delivery order

1. Finish and verify the already-open validity, storage, transport, and CI
   corrections.
2. In Lattice, extract one shared proof traversal, add work-only verification,
   add the transitive parent-state continuity value, flatten contributions, and
   add reference/differential tests.
3. In lattice-node, add the proof-only Volume constructor, independent work and
   recursive ancestor-validity admission, source-agnostic path acquisition, and
   atomic durability.
4. Add same-chain proof distribution, bounded pending acquisition, replay, and
   exact comparison with the independent reference model.
5. Run the quantitative adversarial gate.
6. Delete the trusted feed and all orphaned projections, revisions,
   persistence, readiness, and fork-choice branches.
7. Run clean-build unit, integration, realistic multi-process, restart,
   sanitizer, coverage, and performance suites. Update dependency tags, exact
   pins, documentation, and the existing PRs with the verified results.

## Completion definition

The work is complete when a clean node can create and follow parent, child, and
grandchild chains; accept proof-derived work from any honest Volume provider;
enforce transitive immediate-parent state continuity through the exact parent
process boundary; reproduce the same tip and transition graph after restart;
recover from malformed or unavailable providers; resist bounded unknown-child
floods; match the reference model; pass the declared security gate; and run
with no inherited-work feed, portable validity certificate, recursive
child-side parent validator, or duplicate validated-delta store.
