# Composable Node Architecture

The consensus details of proof-derived work and parent-state continuity live in
[proof-derived child work](proof-derived-work.md).

## Mental model

One process owns one chain. Shared transport routes messages by absolute chain
path, while each chain has an isolated Ivy namespace, Tally scope, accepted
graph, mempool, and Volume pruning policy.

The node composes six orthogonal capabilities:

1. **Gossip and sync** discover accepted block CIDs and transaction Volume roots.
2. **Acquisition** resolves the complete Volumes needed by one candidate.
3. **Validation** asks Lattice for a typed, immutable import result.
4. **Persistence** atomically records semantic facts and retains selected
   Volumes through VolumeBroker.
5. **Insertion** updates the accepted same-chain graph with proof-derived work.
6. **Consensus** recomputes hierarchical GHOST from the accepted graph; its
   chosen tip is derived state and is never a separate source of truth.

These are capabilities, not a mandatory universal pipeline. Restart replays
durable facts directly. Transaction gossip uses discovery, acquisition,
validation, and mempool retention without touching consensus. Parent evidence
uses hierarchy routing and validation without importing parent state.

## Orchestration state

The network actor owns transport ordering, but independent semantic state
machines remain small reducers:

- `BlockFetcher` owns candidate/provider/dependency scheduling.
- `ParentEvidenceFlow` owns session-local evidence ordering, backpressure, and
  reservation fencing.
- `RangeSync` owns the single forward-apply range-sync slot and the bounds
  that shape its paging.

These reducers perform neither Ivy I/O nor Lattice consensus. The parent
evidence inbox row and scan watermark intentionally remain one NodeStore
transaction: splitting that durability boundary would permit a crash to skip
evidence.

Child candidates need no reducer, because nothing is reserved. Each child
pushes its candidate whenever one of its inputs changes; the parent keeps only
the latest candidate per child peer, and a template takes every held candidate
whose parent state is the current tip's post-state. The child keeps what it
built in its own budgeted offer store, oldest offer evicted first. When the
configured parent's evidence names one of those candidates carried, its row
becomes a handoff: newer offers no longer evict it, a separate handoff budget
bounds it, and the carried block's import takes over its roots.

While the parent's tip context names a carried child block that this chain has
not imported, the child holds its candidate offers, since a candidate built
then would only be that block's sibling. The hold ends when the block is
imported, when an import decides against it, or when an evidence scan round
sent for it ends without it. Only the configured parent's state can keep the
hold; nothing an overlay peer announces or relays does.

## Content boundary

Ivy and VolumeBroker form the IPFS-like boundary for Lattice:

- peers advertise and request complete Volume roots, not loose CIDs;
- temporary Volumes may live only in a bounded `MemoryBroker`;
- selected content is retained through VolumeBroker;
- malformed or incomplete content is attributed to the exact supplier, then
  reacquired from another advertised provider;
- validation bytes have no second local CAS.

Content availability and consensus evidence are independent. Any peer may serve
content-addressed bytes. Only the configured immediate-parent session may answer
an exact genesis or parent-state continuity query. The unsigned answer is
non-portable; ordinary peers can provide the underlying Volumes but never the
parent's verdict.

## Import boundary

Acquisition produces an immutable candidate attempt containing:

- the candidate block Volume;
- the sparse root-to-child proof Volume;
- any locally constructed genesis or continuity fact acknowledged by the
  authenticated immediate-parent session;
- exact provider attribution.

Lattice then verifies:

- the sparse directory path and target-derived work;
- local block validity and state transition;
- same-chain predecessor connectivity;
- genesis authorization for a child root;
- transitive immediate-parent state continuity when the parent-state CID
  changes.

The proof itself establishes physical work. A carrier does not have to be valid,
accepted, connected, or canonical. The derived work fact becomes fork-choice
input only when its child block is accepted and connected.

## Atomic mutation

`ChainProcess` serializes the small semantic commit:

```text
preflight
  -> reserve exact BlockImportBatch
  -> persist batch in state.db
  -> apply the same batch to ChainState
  -> publish the resulting effects asynchronously
```

The batch contains accepted graph facts, state snapshots, hierarchy facts, and
one exact proof-derived `ChainWorkFact`. Crash recovery replays those facts and
recomputes the same tip. Network cursors, provider caches, and canonical choice
are rebuildable projections.

## Hierarchy boundary

The parent learns nothing from its children. It:

- commits child data in ordinary block state;
- serves complete committed Volumes;
- answers whether one parent state is transitively reachable from another in
  its connected accepted graph;
- acknowledges an exact continuity or genesis query from that graph;
- maintains run state for the directories it hosts and serves each
  carrier's run report to that directory's children (spec §9.10).

It does not ingest child consensus, child payloads, child provider state, or
child weights. A grandchild repeats the same immediate-parent rule; no ancestor
proof protocol or descendant-tree export exists.

## Failure semantics

| Failure | Result |
|---|---|
| Provider timeout or partial Volume | Retry another exact advertiser; no blame for absence |
| Malformed or wrong complete Volume | Penalize the supplier and retry discovery |
| Missing predecessor | Park the candidate and acquire that predecessor |
| Missing parent continuity fact | Ask the configured immediate parent; timeout remains retryable |
| Invalid proof or state transition | Reject that candidate |
| Crash after durable batch | Replay facts and recompute fork choice |
| Parent offline after facts are known | Keep verified history and consensus active |

## Non-negotiable invariants

- One physical grind is counted once.
- Different root grinds sum.
- Canonicity never changes weight.
- Work affects a chain only after the corresponding block is connected.
- Parent continuity is reflexive or transitively forward, never merely
  "different" and never restricted to a direct step.
- Volume identity is the storage and network boundary.
- Pruning depth and serving policy are local and non-consensus.
- No minimum-work import floor exists. Any filter on work that can reach
  fork choice is consensus-relevant — two nodes with different floors could
  select different tips — so the node ships none: the chain's own target is
  the only work gate.
