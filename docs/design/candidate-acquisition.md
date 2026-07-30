# Candidate Acquisition

## Goal

`CandidateAcquirer` is the per-chain black box between networking/storage and
consensus admission. It accumulates verifiable facts until it can produce one
complete, immutable admission input.

Acquisition must be independent of event arrival order. Evidence arriving
before content, content arriving during admission, reconnects, recursive
predecessor recovery, and backpressure must all converge to the same eventual
acquisition graph. Intermediate admission attempts may differ because the node
acts on facts as soon as they arrive.

## Boundary

The acquirer owns:

- block Volume availability;
- live exact Volume providers;
- authenticated evidence packages, distinct by root CID;
- known same-chain predecessor dependencies;
- bounded acquisition retries;
- admission attempt revisions and stale-completion rejection.

The acquirer does not own:

- evidence authority or signature verification;
- work totals or parent-state reachability;
- fork choice or hierarchical GHOST;
- transaction-pool processing;
- child-candidate construction;
- peer reputation policy;
- accepted-block or proof publication.

Evidence is authenticated before entering the acquirer. Consensus remains the
only authority that decides whether a complete candidate is accepted.

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
9. Admission completions remain authoritative for their exact active attempt
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
├── active admission revisions
└── bounded retry/frontier state
```

Every event merges a fact and invokes one idempotent `advance` operation.
`advance` schedules a complete attempt when it has a content route and the
required evidence. A missing predecessor creates an independent acquisition
record for that predecessor and parks the descendant until consensus connects
the edge. Queues schedule work; they are not semantic state.

## Contract

The acquirer accepts:

- a block Volume announcement and exact provider;
- an authenticated evidence package;
- provider connection and disconnection;
- a recovered durable predecessor obligation;
- a fetch completion;
- an admission completion;
- a bounded retry tick.

It produces a complete admission value containing:

- an opaque ticket and revision;
- the block header;
- an optional authenticated child package;
- a root-scoped content source;
- a bounded root-scoped Cashew content source.

The admission result and resulting content attribution are returned to the
acquirer. The acquirer interprets only their scheduling consequences:
accepted, missing predecessor, missing content, missing evidence, retry later,
or invalid content.

## Transport and storage

The acquirer depends on a narrow Volume-fetching protocol rather than Ivy
directly. The production adapter tries live exact providers, then advertised
public pins/provider discovery. Complete Volumes are CID-validated before
VolumeBroker stores them.

Malformed or incomplete responses remain attributable to their serving peer.
The acquirer then retries another provider or discovery route. Attribution is
returned to the runtime; Tally policy remains outside the module.

## Concurrency

The runtime actor owns the synchronous reducer and therefore its semantic
state. Lazy content resolution and admission execute outside the reducer. Each
operation carries an exact active-attempt ticket. Concurrent facts merge into
the record and may schedule follow-up work, but do not invalidate an admission
that may already have staged durable consensus state.

This gives three rules:

1. facts merge synchronously inside the actor;
2. expensive work runs asynchronously outside the actor;
3. results mutate state only when their active-attempt ticket and runtime
   generation remain current.

## Implementation plan

### 1. Freeze observable behavior

Add deterministic characterization tests for:

- evidence before provider;
- provider before evidence;
- provider arriving during admission;
- recursive `D -> P -> Q` predecessor recovery;
- multiple evidence roots for one block;
- frontier backpressure;
- malformed or incomplete Volumes followed by reacquisition;
- disconnect and restart at each suspended state.

### 2. Define the black-box contract

Introduce admission tickets, immutable admission inputs/results, provider
identities, and the narrow Volume-fetching protocol. The acquisition core must
not import or reference concrete Ivy types.

### 3. Implement the state reducer

Implement the per-chain actor and its idempotent event reducer. Prove bounded
state, root-specific evidence preservation, iterative dependency traversal,
and stale revision rejection with deterministic tests.

### 4. Add asynchronous execution

Run Volume fetches and consensus admission through injected ports. Feed their
revision-bound results back through the reducer.

### 5. Build production adapters

Adapt Ivy sessions and provider discovery to the Volume-fetching protocol.
Use VolumeBroker for all verified local materialization and retention.

### 6. Integrate the runtime

Route block announcements, accepted-leaf inventory, portable evidence, parent
evidence, provider disconnects, and recovered predecessor obligations into the
acquirer. Inject `ChainService` admission without moving consensus into the
module.

### 7. Delete legacy orchestration

Remove candidate semantic state from `NodeNetworkRuntime`, including its
candidate inbox, queued/active/waiting candidates, descendant wait maps, route
sharing, and acquisition retry tasks. Retain only bounded network ingress and
transport-request state.

### 8. Verify

Run reducer permutation tests, real VolumeBroker/component tests, real-Ivy
tests, daemon multichain E2Es, `swift build`, `swift test`, and
`git diff --check`.

### 9. Review and simplify

Adversarially review authority boundaries, arrival-order independence,
backpressure, crash safety, attribution, memory bounds, and unnecessary
abstractions. Resolve concrete counterexamples and repeat until no findings
remain. The extraction must materially reduce `NodeNetworkRuntime`.

## Acceptance criteria

- No candidate obligation is lost through ordering or backpressure.
- Multiple roots committing to one block remain distinct.
- Any valid Volume can be reused across machines.
- Inherited work remains completely orthogonal to acquisition.
- The runtime contains no candidate-acquisition state machine.
- Acquisition can be tested as an independent black box.
- Full realistic multichain tests pass without inflated timing allowances.

Reservation reconciliation is a separate per-peer
desired/in-flight/acknowledged state machine and is not part of this module.
