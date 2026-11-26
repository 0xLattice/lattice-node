# Composable hosted-tree capabilities

> **Status:** Current description.
> **Purpose:** The six capabilities the node composes to take in blocks and
> transactions, and the boundaries between them. The components that carry
> them out are in [Node architecture](../architecture.md); the consensus
> details of child work and parent-state continuity are in
> [Proof-derived child work](proof-derived-work.md).

## Six capabilities

One process owns one Nexus-rooted tree. Each hosted path has isolated
consensus state, fork choice, sync state and mempool inside a shared
`NodeCore`. The host provides one Ivy overlay, one content layer and one
durable journal. On top of them the node composes:

1. **Gossip and sync** discover accepted block CIDs and transaction Volume
   roots, routed by absolute chain path.
2. **Acquisition** resolves the complete Volumes needed by a candidate.
3. **Validation** asks Lattice for typed immutable facts.
4. **Persistence** retains content, then atomically records every affected
   level and cursor in one `NodeBatch` transaction.
5. **Insertion** updates each accepted same-chain graph with proof-derived
   work.
6. **Consensus** recomputes hierarchical GHOST; the chosen tip is derived
   state, never another source of truth.

These are capabilities, not one mandatory pipeline:

- Restart replays durable facts directly.
- Transaction gossip uses acquisition, validation and mempool retention
  without touching fork choice.
- Parent continuity and run attribution are in-process reads between
  co-hosted levels.

## Orchestration

One serial runtime loop owns `NodeCore.step`, and effects execute in a
fixed order: persist, publish, then network and background work
([Production runtime](../architecture.md#production-runtime)).

Per-level reducers remain small:

- header sync owns pending headers, range paging and proof waits;
- body acquisition owns candidate, provider and dependency scheduling
  ([Body acquisition](block-fetching.md));
- mining owns mempool state and the preflight and template jobs, each
  naming the tip it reads.

Worker tasks never mutate the core. They return events to the serial loop.
A pooled transaction's recheck whose tip is no longer the mining tip is
discarded before it runs. A verdict or template on a tip is a fact about
that tip, so nothing else is discarded or refused because the tip moved.

## Content boundary

Ivy and VolumeBroker form the content-addressed boundary:

- peers advertise and request complete Volume roots, not loose CIDs;
- selected content is retained in the durable Volume store of its chain;
- malformed complete content is attributed to its exact supplier;
- incomplete or unavailable content is retried without a validity verdict;
- validation bytes have no second local CAS.

Content availability and consensus evidence remain distinct. Any compatible
peer can serve bytes. Only the co-hosted parent level can supply a
parent-state continuity fact, and that fact is not serialized or portable.

## Import boundary

Acquisition yields the candidate block, its directory proof when it is a
child, and the content needed for state execution. Lattice verifies work,
linkage, state transition, same-chain connectivity and parent-state
continuity. A carrier need not be accepted on its own chain for its
physical work to be real; the derived work affects child fork choice only
after the child block is accepted and connected.

## Atomic mutation

One core turn can touch several levels:

```text
preflight
  -> create one NodeBatch keyed by path
  -> retain content and header evidence
  -> commit all facts and cursors in one state.db transaction
  -> publish every resulting level snapshot
```

Success means the complete tree step is durable. Failure exposes none of
the fact rows. Recovery replays the same path-keyed batches and recomputes
the same tips. Provider caches and canonical projections are rebuildable.
The write order and recovery are detailed in
[Storage and recovery](../architecture.md#storage-and-recovery).

## Hierarchy boundary

The parent does not choose child consensus. It exposes validated state
continuity and attributed runs for directories it hosts. The child
validates its own content-bound proof and applies those facts to its own
graph ([Process trust model](process-trust-model.md)).

Child genesis is built from an operator-configured spec and the carrier's
entering state; it needs no deployment transaction. A nested child waits
until its parent has executed a block of its own, because that produces the
distinct parent state its genesis must name.

The result is one operational unit with independent consensus decisions:
recursive commitments, one shared host, and one atomic durability boundary.
