# Composable hosted-tree architecture

The consensus details of proof-derived work and parent-state continuity live in
[proof-derived child work](proof-derived-work.md).

## Mental model

One process owns one Nexus-rooted tree. Each hosted path has isolated consensus
state, fork choice, sync state, and mempool inside a shared `NodeCore`. The host
provides one Ivy overlay, one content layer, and one durable journal.

The node composes six capabilities:

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

These are capabilities, not one mandatory pipeline. Restart replays durable
facts directly. Transaction gossip uses acquisition, validation, and mempool
retention without touching fork choice. Parent continuity and run attribution
are in-process reads between co-hosted levels.

## Orchestration state

One serial runtime loop owns `NodeCore.step`. Network inputs, completed worker
jobs, timers, and RPC writes become events. Effects execute in a fixed order:
persist, publish, then network and background work. A failed persist is
fail-stop, so no later effect can expose a step that was not durable.

Per-level reducers remain small:

- header sync owns pending headers, range paging, and proof waits;
- body acquisition owns candidate/provider/dependency scheduling;
- mining owns mempool state and epoch-fenced template jobs.

Worker tasks never mutate the core. They return events to the serial loop, and
stale epoch work is discarded before it runs.

## Content boundary

Ivy and VolumeBroker form the content-addressed boundary:

- peers advertise and request complete Volume roots, not loose CIDs;
- selected content is retained in the one durable content store;
- malformed complete content is attributed to its exact supplier;
- incomplete or unavailable content is retried without a validity verdict;
- validation bytes have no second local CAS.

Content availability and consensus evidence remain distinct. Any compatible
peer can serve bytes. Only the co-hosted parent level can supply a parent-state
continuity fact, and that fact is not serialized or portable.

## Import boundary

Acquisition yields the candidate block, its directory proof when it is a child,
and the content needed for state execution. Lattice verifies work, linkage,
state transition, same-chain connectivity, and parent-state continuity. A
carrier need not be accepted on its own chain for its physical work to be real;
the derived work affects child fork choice only after the child block is
accepted and connected.

## Atomic mutation

One core turn can touch several levels:

```text
preflight
  -> create one NodeBatch keyed by path
  -> retain content and header evidence
  -> commit all facts and cursors in one state.db transaction
  -> publish every resulting level snapshot
```

Success means the complete tree step is durable. Failure exposes none of the
fact rows. Recovery replays the same path-keyed batches and recomputes the same
tips. Provider caches and canonical projections are rebuildable.

## Hierarchy boundary

The parent does not choose child consensus. It exposes validated state
continuity and attributed runs for directories it hosts. The child validates
its own content-bound proof and applies those facts to its own graph.

Child genesis is built from an operator-configured spec and the carrier's
entering state; it needs no deployment transaction. A nested child waits until
its parent has executed a block of its own, because that produces the distinct
parent state its genesis must name.

The result is one operational unit with independent consensus decisions:
recursive commitments, one shared host, and one atomic durability boundary.
