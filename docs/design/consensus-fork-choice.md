# Consensus and fork-choice ownership

> **Status:** Current description.
> **Purpose:** Where the line runs between Lattice, which defines consensus,
> and `lattice-node`, which operates around it; and what a node syncing
> from nothing has to trust.

Consensus is defined by Lattice, not by `lattice-node`. The rules are the
[protocol specification](https://github.com/0xLattice/Lattice/blob/59.3.1/docs/spec.md)
and the
[work and fork-choice rationale](https://github.com/0xLattice/Lattice/blob/59.3.1/docs/consensus-fork-choice.md).
This page restates none of them.

| Rule | Owned by |
|---|---|
| How much work one grind credits at a child block | [Spec §9.5](https://github.com/0xLattice/Lattice/blob/59.3.1/docs/spec.md#95-cross-chain-evidence-independence) |
| Parent-attributed run work | [Spec §9.10](https://github.com/0xLattice/Lattice/blob/59.3.1/docs/spec.md#910-parent-attributed-run-work) |
| The tie-break between blocks of equal work | [Spec §9.4](https://github.com/0xLattice/Lattice/blob/59.3.1/docs/spec.md#94-fork-choice-and-reorganization) |
| Weighed and validated tiers, exclusion | [Spec §9.9](https://github.com/0xLattice/Lattice/blob/59.3.1/docs/spec.md#99-deferred-execution-weighed-and-validated-tiers) |
| How the node applies them to a child chain | [Proof-derived child work](proof-derived-work.md) |

## What the node owns

The node owns only the operational boundary around those rules:

- route facts between co-hosted parent and child levels;
- acquire the exact sparse evidence Lattice requests;
- persist accepted fact batches before exposing their effects;
- retain and replay the same immutable facts after restart;
- derive each unique grind's work from its content-addressed child proof;
  and
- project the one canonical chain delta returned by Lattice.

## What the node must not do

- Implement a second fork-choice metric.
- Recursively choose descendant tips.
- Send parent canonical-tip commands across the hierarchy plane.
- Accept a work total as fork-choice input.

The one report the node accepts about work it did not verify is the run
report of spec §9.10, and only from its configured immediate parent. How it
binds and credits that report is in
[Proof-derived child work](proof-derived-work.md#securing-work-rule).

## A parent fork does not choose for the child

A parent fork that omits a hosted child (commits nothing into its
directory) changes no child fork choice. Its blocks join the run of their
nearest carrier above the fork, so their work is attributed at that
carrier's child block, a common ancestor of every child fork below it, and
to neither fork.

The child work carried by the losing parent fork is not revoked: work
weighs, validity selects, and the parent is not authoritative over which
child fork is canonical.

Likewise, a withdrawal anchored on a losing parent fork is valid: an anchor
needs parent-state continuity, not canonicity, and consensus fork choice
alone settles it. There is no standard confirmation depth.

The omission is pinned by `CrossLevelForkChoiceTests`; the withdrawal by
Lattice's `CrossChainReorgReplayEdgeTests`.

## Sync trust boundary

Cold sync pays two independent costs, and only one is cheap.

### Fork choice needs no checkpoint

Which tip is heaviest depends only on work facts and the shape of the block
graph. Work facts are self-verifying from content-addressed bytes and
deduplicated per root-CID grind. Weighing a block needs only its header and
its *claimed* state CIDs, never the materialized state.

Cumulative proof of work is *objective*, so a fresh node determines the
heaviest tip with **no weak-subjectivity checkpoint**: the property a
proof-of-work chain has and a proof-of-stake chain cannot.
[Bitcoin-anchoring the genesis](bitcoin-anchored-genesis.md) fixes *which*
genesis out-of-band, which is the one thing raw proof of work can't
self-anchor. Together they give a trustless, checkpoint-free fork-choice
start.

### State validity is re-executed

That `postStateCID == STF(prevState, txs)` is *not* attested by work. A
heavier chain can commit a wrong post-state, and content addressing proves
only that the producer *committed* those bytes, never that the transition
was *honest*. So canonical state is **re-executed from genesis by design**.

There is no `assumevalid`: the only trustless anchor a fresh node possesses
is genesis (segment-anchored catch-up trusts a node's *own* last-validated
context, which a fresh node lacks). This is the trust model, not a missing
optimization. "Why can't we just assumevalid?" has no trustless answer short
of succinct validity proofs, which would be a consensus change.

### What bounds the cost

Content addressing bounds the *working set*, not just integrity: canonical
re-execution fetches sparse state slices verified against each block's
`prevStateCID`, so it never materializes the full historical state. That is
strictly cheaper than an account-trie chain, though CPU over canonical
transactions stays inherent.

Abandoned forks are not executed: their blocks are weighed from headers,
and state is executed only for blocks the node acts on (spec §9.9;
[Deferred execution](weight-first-acquisition.md)). The requirement that
makes this safe stands: a heaviest-but-*invalid* path is always demoted to
the heaviest *valid* one.
