# Block Fetching

## Goal

`BlockFetcher` is the per-chain black box between networking/storage and
block import. It accumulates verifiable facts until it can produce one
complete, immutable import input.

Acquisition must be independent of event arrival order. Evidence arriving
before content, content arriving during import, reconnects, recursive
predecessor recovery, and backpressure must all converge to the same eventual
acquisition graph. Intermediate import attempts may differ because the node
acts on facts as soon as they arrive.

## Boundary

The fetcher owns:

- block Volume availability;
- live exact Volume providers;
- authenticated evidence packages, distinct by root CID;
- known same-chain predecessor dependencies;
- bounded acquisition retries;
- import attempt revisions and stale-completion rejection.

The fetcher does not own:

- evidence authority or signature verification;
- work totals or parent-state reachability;
- fork choice or hierarchical GHOST;
- transaction-pool processing;
- child-candidate construction;
- peer reputation policy;
- accepted-block or proof publication.

Evidence is authenticated before entering the fetcher. Consensus remains the
only authority that decides whether a complete candidate is accepted. The
fetcher references no Ivy type, and the network runtime keeps no
candidate-acquisition state machine of its own beyond the fetcher it drives.

## Invariants

1. Content and providers are shared by block CID.
2. Parent evidence remains distinct by root CID.
3. A provider supplies verifiable data, never authority.
4. A package supplies authority context, never data availability.
5. A provider advertisement is scoped to its exact Volume CID. Discover a
   predecessor as its own Volume; never manufacture a provider record for it
   from a descendant advertisement.
6. Verified bytes are materialized only through `VolumeBroker`.
7. Missing-predecessor traversal is iterative and bounded.
8. A retry obligation is not discarded until its replacement work is safely
   scheduled or the obligation is explicitly invalidated.
9. Import completions remain authoritative for their exact active attempt
   even when providers or evidence arrive concurrently. Only a runtime reset
   makes a completion stale.
10. Every retained collection has an explicit bound.

## Model

Each block CID has one acquisition record:

```text
BlockRecord
├── verified content state
├── live exact Volume providers
├── evidence attempts keyed by root CID
├── known predecessor CID
├── active import revisions
└── bounded retry/frontier state
```

Every event merges a fact and invokes one idempotent `advance` operation.
`advance` schedules a complete attempt when it has a content route and the
required evidence. A missing predecessor creates an independent acquisition
record for that predecessor and parks the descendant until consensus connects
the edge. Queues schedule work; they are not semantic state.

## Contract

The fetcher accepts:

- a block Volume announcement and exact provider, whether from a live
  announcement, a range-sync page, or a frontier pull;
- an authenticated evidence package;
- provider connection and disconnection;
- parent evidence and portable evidence;
- a recovered durable predecessor obligation;
- a fetch completion;
- an import completion;
- a bounded retry tick.

It produces a complete import value containing:

- an opaque ticket and revision;
- the block header;
- an optional authenticated child package;
- a root-scoped content source;
- a bounded root-scoped Cashew content source.

The import result and resulting content attribution are returned to the
fetcher. The fetcher interprets only their scheduling consequences:
accepted, missing predecessor, missing content, missing evidence, retry later,
or invalid content.

## Transport and storage

The fetcher depends on a narrow Volume-fetching protocol rather than Ivy
directly. The production adapter tries live exact providers, then advertised
public pins/provider discovery. Complete Volumes are CID-validated before
VolumeBroker stores them.

Malformed or incomplete responses remain attributable to their serving peer.
The fetcher then retries another provider or discovery route. Attribution is
returned to the runtime; Tally policy remains outside the module.

## Concurrency

The runtime actor owns the synchronous reducer and therefore its semantic
state. Lazy content resolution and import execute outside the reducer. Each
operation carries an exact active-attempt ticket. Concurrent facts merge into
the record and may schedule follow-up work, but do not invalidate an import
that may already have staged durable consensus state.

This gives three rules:

1. facts merge synchronously inside the actor;
2. expensive work runs asynchronously outside the actor;
3. results mutate state only when their active-attempt ticket and runtime
   generation remain current.
