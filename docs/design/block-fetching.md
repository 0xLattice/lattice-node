# Body Acquisition

This document describes the implemented boundary between weighed headers and
full block execution. The historical `BlockFetcher` state machine no longer
exists; acquisition is split deliberately between `BodyPipeline`, the runtime,
and the shared content layer.

## Ownership

`HeaderSync` acquires and verifies headers. Once fork choice has selected a
best chain, `BodyPipeline` names the next bounded window of
weighed-but-unexecuted block CIDs. It owns only deterministic scheduling state:

- bodies requested from the content layer;
- bodies that arrived and are ready to connect;
- the single connect job currently running;
- retry backoff for temporarily unavailable content; and
- child blocks waiting for a co-hosted parent-state fact.

Provider discovery, fetching, CID verification, and provider suppression live
in the shared content layer. `NodeRuntime` executes those effects and returns
plain events to the core. Lattice alone decides whether a complete block is
valid and records the resulting consensus facts.

## Flow

```text
verified header -> fork choice -> bounded body window
                                 -> fetch Volume by block CID
                                 -> connect next block in parent order
                                 -> persist facts and referenced content
                                 -> publish the new read snapshot
```

The node acts on the heaviest executed tip: from genesis, at each fork the
heaviest child (its whole header subtree) that is executed. It executes the
heaviest header chain, each block it mined itself, and, where the heavier
child at a fork was tried and cannot be executed now (every peer asked lacks
its body, its connect awaits a parent fact, or its content is unresolvable),
the next-heaviest sibling. That heavier child keeps its weight, gets no
verdict, stays wanted, and is executed and followed once it can be. Losing
headers retain their verified work
and can become selected later without having consumed state-execution work in
advance. A missing body is an availability wait, never peer blame. If a
connect attempt lacks content, the block is retried with bounded exponential
backoff. If a child block lacks a parent-state continuity fact, it remains
ready and is retried when the co-hosted parent advances.

## Invariants

1. Headers are weighed before body execution and fork choice does not depend
   on body arrival order.
2. Bodies connect one at a time, in parent order, along the current best chain.
3. Every requested, arrived, parked, or parent-waiting set is bounded by the
   configured body window.
4. Complete Volumes are CID-verified and materialized through the one shared
   content store.
5. Worker tasks never mutate consensus state. Their results return as events
   to the serial runtime loop.
6. Content and header evidence are durable before the tree-wide fact
   transaction that names them, and state is published only after that
   transaction commits.

Child work proof acquisition is a separate concern. A child header carries
bounded inline `ChildBlockProof` values, while `ChildProofSync` can consult the
durable local evidence index for proofs this node already learned. Peers supply
verifiable bytes, never a validity verdict or remote parent-state authority.
