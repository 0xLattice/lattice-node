# Proof-Derived Child Work

The normative consensus rules belong in Lattice's specification. This document
explains how a child chain's work and its parent-state continuity fit together
across Lattice and lattice-node, and the invariants both keep.

## Motivation

Child security is the physical work that commits to a child block, directly or
indirectly. A grind's directory proof commits to the child explicitly. A later
parent block that descends from that carrier without re-committing commits
to it indirectly, and its work counts too — once, through run attribution
(spec §9.10). What never counts is parent canonicity: runs follow parent
pointers, not the parent's canonical chain. Every accepted child block
therefore receives ordinary, immutable work facts: proof-derived contributions
for its grinds, and one attributed-run contribution per carrier. Once
imported, normal same-chain GHOST is sufficient.

There is no live inherited-work projection: nothing pushes a snapshot of the
parent's weight, with revisions and completion markers, into a separate
inherited branch of GHOST. Run attribution is not such a feed: there is no
snapshot and no projection. The child binds each report to its own directory, the
named child block, and a grind already credited there; derives the credit
itself; and stages it as an ordinary durable work fact under its own identity,
`AttributedRunIdentity(carrier, directory)`. It also preserves
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
3. The child's accepted-block graph routes imported work through same-chain GHOST.

Directory descent is not parent-chain descent. A root may descend through
several child directories in one proof. A later block in the parent's own chain
adds child work only through the run of its nearest committing ancestor, by
parent pointer (spec §9.10); a parent block with no ancestor committing into
the directory adds none.

## Securing-work rule

A work proof is valid when all of the following hold:

- Every supplied block is bound to its canonical CID bytes.
- The root's proof-of-work hash is computed from those bytes.
- The sparse directory path resolves uniquely to the exact terminal child.
- Every vertical hop binds `child.parentState` to `carrier.prevState`.
- The root hash beats the terminal child's target.
- The proof uses one canonical root CID as its grind identity.

The blocks on the directory path do not need to be valid, imported, connected,
or canonical on their own chains. Work validity is deliberately orthogonal to
block validity.

The contribution of one root to one child location is `workForTarget` of the
ROOT-MOST content-bound block on the committed directory path whose target the
root hash beats, raised if greater by the terminal child's own target. Position
picks the pricer; the child overrides only a pricer easier than itself. It is
NOT a maximum over every beaten target (Lattice 35.0.1, spec §9.5). The
terminal child's target must be beaten. Repeated evidence for the same grind
and child location keeps the
strongest verified value; that per-location ratchet is a different rule from
the along-the-path selection. Conflicting
claims for one grind and chain-local location are rejected. Different grind
identities sum. A proof cannot affect fork choice until its terminal child is
accepted and connected in that child's chain.

The second source of a child location's weight is the attributed run (spec
§9.10). The co-hosted parent level partitions its connected graph
into runs, one per commitment into the child's directory, and serves
`(carrier, directory, childBlock, grinds, runWork, ownWork, revision)`. The
child binds the report — its own directory, this child block, one of the
carrier's grinds already credited there — and credits `runWork − ownWork`
under `AttributedRunIdentity(carrier, directory)`: a contribution separate
from any grind, keyed by the carrier, ratcheting on its own value
(idempotent, monotone, refused rather than saturated, never revoked). The
quantity is the co-hosted parent level's word, the trust the child already
extends to it for state continuity; the location and binding are checked locally,
and a verified path can replace the reported one with no consensus change.
The identity's encoded key deliberately keeps the old name `committerBlockHash`,
so durable facts are byte-identical across the carrier rename.

Proof-derived and attributed-run contributions alike become ordinary
`VerifiedWorkContribution` facts at a child location. There is no inherited
branch in GHOST: an attributed run is summed like any other contribution,
under its own identity, and is never a projection of the parent's weight.

## Parent-state continuity

Every child block anchors its `parentState` independently. When the field is
not the empty state, the child requires a `ParentStateContinuityLink` from the
empty state to that exact CID, and its co-hosted immediate parent answers true
only when some block in the parent's executed-from-genesis set produced it.
A weighed-only post-state claim is insufficient. Parent canonicity does not
alter a state that was actually executed on any valid branch.

A non-genesis block that commits no parent state may use the empty state and
needs no fact. A child genesis naming the empty state is invalid: genesis must
anchor to a real state produced by its parent.

The terminal directory carrier binds `child.parentState == carrier.prevState`.
That binding is not an anchor and never was: the carrier need not be a valid
parent block, so both sides of the comparison may be chosen by one party. What
establishes that the child's `parentState` is a state the parent legitimately
reached is continuity, proved at every height including block 1 (spec §5.3
step 6, which carries no height-1 exemption).

The binding still gates **work**, not only import: it is enforced inside
`ChildBlockProof.verifySecuringWork`, which returns `.protocolInvalid` before
any `VerifiedWorkContribution` is minted, so a failure withholds the work
contribution and the import together. Work crediting and the vertical
binding are therefore one check.

Each chain level durably records validation facts for executed blocks. That
recovered executed set answers continuity; no second delta database or header
replay protocol exists. The child constructs
`ParentStateContinuityLink(parentPath, empty, parentState)` locally for the
import attempt. The fact is in-process and non-portable. A missing state is
retryable unavailability while the parent is still advancing.

Grandparent validity follows by induction. A parent block cannot enter the
parent level's durable graph until that level has applied the same rule
against its immediate parent. The child never receives the grandparent tree,
header path, or verdict. Nexus terminates the induction.

Child genesis needs no deployment verdict. The host builds it from the
configured spec and the carrier's entering parent state. A valid mined
root-to-child proof supplies its work, and the child level validates and
chooses it like any other child root.

Arbitrary peers may supply any required content-addressed Volume. They never
supply a validity verdict. A node hosts every child with its whole ancestry
and answers parent facts from its own co-hosted parent level, so it validates
its own parent chains recursively to Nexus; there is no remote parent whose
answer could differ between child nodes. The facts are local reads, unsigned
and non-portable: a portable certificate is exactly the light-client artifact
this design forbids.

## Data and process boundaries

- `ChildBlockProof` is the canonical securing-work evidence. Header pages carry
  a bounded set of proofs inline with each child header.
- Each chain derives validity from content-addressed Volumes it acquires and
  verifies. Ivy and VolumeBroker move complete Volumes; there is no second
  validation CAS.
- Cross-chain continuity reads only the co-hosted immediate parent's recovered
  validated graph; child genesis needs no deployment acknowledgement.
- The host records weighed headers, child indexes, and credited proofs in
  `state.db`, in the transaction of their facts. They are local scheduling and
  serving state, not portable authority.
- Proofs learned from peers or produced by local merged mining are verified
  before credit. A node can later serve the exact saved proof with the child
  header or find it through its local evidence index.
- Gossip, sync, acquisition, and persistence may run asynchronously.
  Chain insertion and fork choice consume only complete, durable import
  batches.
- Stream cursors advance in the same tree-wide transaction as the facts they
  cover, so a crash cannot skip imported evidence.
- Candidate content is retained with issued mining work; a submitted grind
  transfers the roots only for levels whose targets it actually meets.

Unknown-child proofs are bounded per peer and globally. Triggered sync is
rate- and concurrency-limited. A valid proof for a child that has not yet
arrived is not punishable; lying about advertised availability or returning
malformed bytes is.

## What the design leaves out

There is no generic forest, accumulator, light-client protocol, quorum, second
CAS, or second fork-choice implementation. No wire topic carries securing or
inherited work, and no store keeps inherited-work snapshots, parent-work facts
or cursors, or parent-work readiness. A §9.10 run report, handed in-process
from a parent level to a hosted child, carries a report the child binds and
derives into a work fact, never a weight snapshot.

## Properties

1. A verified observation of a root whose root hash clears the terminal
   child's target credits exactly `workForTarget` of the root-most target it
   cleared along that proof, raised if greater by the terminal child's own
   (never a max over every cleared target; Lattice 35.0.1, spec §9.5); an
   observation that does not clear the terminal target yields no contribution
   at all — no work fact, and the block is not imported; a location holds the
   strongest such observation.
2. No root is counted twice at one chain-local location.
3. No branch gains weight without equivalent physical work.
4. Honest nodes converge after connectivity returns.
5. Results are invariant to arrival order and restart.

Lattice checks the fork-choice side of these against an independent reference:
`ForkChoiceOracle`, written from the specification alone and sharing nothing
with the production descent, weight index, or arithmetic, must agree with
`ChainState` on the golden, differential, and replay fixtures. Its
`LatticeSim` harness quantifies the deterministic tie-break and no-finality
tradeoffs under deep-reorg, selfish-mining, and balancing strategies (see the
[adversarial report](https://github.com/adalinxx/Lattice/blob/43.1.0/docs/consensus/adversarial-report.md)).
