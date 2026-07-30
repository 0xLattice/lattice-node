# Correctness invariants

## NODE-SEMANTICS-001 — every admission outcome has one node meaning

`canonicalized`, `acceptedSide`, `carrier`, `duplicate`, `unavailable`,
`temporarilyInvalid`, `invalid`, `localFailure`, and `storageFailed` remain
distinct at the node boundary.

## NODE-SEMANTICS-002 — side validity is not canonicity

`acceptedSide` is valid admission but never publishes a canonical tip.

## NODE-SEMANTICS-003 — availability is retriable, not punishable

`unavailable` is retried when availability changes and cannot penalize the supplying peer.

## NODE-SEMANTICS-004 — local durability is not peer behavior

`localFailure` and `storageFailed` are local observations and cannot penalize a
peer.

## NODE-SEMANTICS-005 — only obtained invalid evidence is punishable

Only a complete `invalid` same-chain candidate may be attributed to its
supplier. Authenticated parent evidence establishes parent facts; it never
vouches for a child transition.

Established by: `AdmissionDecisionTests`.

## NODE-STORAGE-001 — peers and persistence exchange complete Volumes

Peer-facing content requests name one complete Volume root. Entry-level CIDs
are internal resolution details, and no Volume becomes locally visible until
its exact membership and CID bytes validate.

A complete Volume may span several bounded Ivy frames. Chunks from different
requests, authenticated sessions, or runtime generations never combine, and
partial assembly is never application-visible.

## NODE-STORAGE-002 — a durable fact never outruns its content

Live publication orders complete Volume storage, merge retention, then the
SQLite semantic reference. Admission and issued-hierarchy retention grow
merge-only while live. Prepared proof eviction serializes its store, SQLite
capacity mutation, and exact retained-set advance through one gate. Contextual
child offers use a separate durable bounded LRU: new roots are pinned before
the index changes and offer eviction never touches issued ownership. An exact,
authenticated parent snapshot recursively reserves descendants and atomically
replaces the issued set before acknowledgement. Removal acknowledgements never
gate parent progress. The authenticated removal update names committed
candidates as handoffs; the child atomically acquires durable handoff ownership
before releasing their issued ownership, recursively through the hierarchy.
Proof acquisition is independent. Admission then transfers the roots before
the handoff is released. Failed or idle cleanup can safely over-retain until an
exact snapshot or startup rebuild reconciles ownership before garbage
collection. Canonicity never changes retention or validity; accepted, shared,
and independently retained roots remain owned.

The bounded in-memory child-intent set has its own exact VolumeBroker scope.
An intent becomes visible only after its complete content-bound closure is
stored and retained; replacement, anchoring, and staleness release roots only
after the remaining exact set is installed. Restart clears this scope because
child intents are not consensus recovery facts.

## NODE-MEMPOOL-001 — the mempool is tip-relative, not consensus

The mempool may retain, order, relay, replace, or retry transactions, but only
Lattice validation against an explicit canonical state can make a transaction
executable or include it in a block.

Local submissions commit a complete transaction Volume before their SQLite
reference and survive restart. Every live pool root also has one process-owner
VolumeBroker pin, updated by pool mutation deltas and removed with the pool
entry. Startup clears that owner before restoring only the durable local roots,
so peer submissions remain serveable while pooled but never become recovery
authority.
