# Body acquisition

> **Status:** Current description.
> **Purpose:** How the node gets from a weighed header to an executed block:
> which bodies it asks for, whom it asks, how it waits, and the invariants
> of that path. The reasons for weighing before executing are in
> [Deferred execution](weight-first-acquisition.md).

## Ownership

| Part | Owns |
|---|---|
| `HeaderSync` | Acquiring and verifying headers. |
| `BodyPipeline` | Deterministic scheduling: which weighed-but-unexecuted block CIDs to fetch next. |
| The shared content layer | Provider discovery, fetching, CID verification and provider suppression. |
| `NodeRuntime` | Executing those effects and returning plain events to the core. |
| Lattice | Deciding whether a complete block is valid, and recording the resulting consensus facts. |

`BodyPipeline` holds only scheduling state:

- bodies requested from the content layer;
- bodies that arrived and are ready to connect;
- the single connect job currently running: up to `connectBatch` ready
  blocks, each the previous one's child;
- retry backoff for temporarily unavailable content; and
- child blocks waiting for a co-hosted parent-state fact: a child block is
  ready only once the parent state it names is in its parent level's
  executed set, checked before any connect is issued.

## Flow

```text
verified header -> fork choice -> bounded body window
                                 -> fetch Volume by block CID
                                 -> connect the next ready blocks in parent order
                                    (one job, up to connectBatch, heaviest first
                                    at a fork, each reading the state the one
                                    before it produced from memory)
                                 -> store their bodies in one transaction in the chain's Volume store,
                                    then their states and facts in one step's persist
                                 -> publish the new read snapshot
```

## Which bodies are asked for

The node acts on the heaviest executed tip: from genesis, at each fork the
heaviest child (its whole header subtree) that is executed. A heavier
header chain whose bodies are not served must not hold the node, and
nothing tells it that a body will never come. So it asks for two sets:

1. **The look-ahead** along the heaviest header chain, bounded by the body
   window's count.
2. **Every block the act-on tip would step into once executed:** each child
   of the tip and, at a fork above it, each child heavier than the executed
   one taken. These fork children are each a proof-of-work header and are
   all asked for; the body window does not bound them.

Whichever arrives is executed; a heavier one that arrives later is executed
and followed then. A block whose body is not held keeps its weight and gets
no verdict. Losing headers retain their verified work and can become
selected later without having consumed state-execution work in advance.

## Whom a body is asked of

A body is asked of the peers that announced it, as Bitcoin asks for a
block:

1. For a child chain, that chain's hosts: the peers whose hello names it,
   or its rendezvous. These are the peers that store a chain's bodies.
2. Then the connected peers this node knows a provider record of for the
   block or the Volume (an operator's pin announces its root).

It is never asked of anyone else or through a DHT walk. With none of them
connected no peer is asked.

## Waiting

A missing body is an availability wait, never peer blame.

- A body not obtained, or whose connect lacks content, waits a backoff that
  doubles per attempt up to five minutes, and stays wanted.
- The wait ends at once when the body may now be had: a block built on it
  is weighed or its body arrives (its author held it), or a host of the
  chain connects (Bitswap's resend on each new connection).
- An execution or a moved window does not end it: neither says who holds a
  body.
- A child block that lacks a parent-state continuity fact remains ready and
  is retried when the co-hosted parent advances.

## Invariants

1. Headers are weighed before body execution and fork choice does not
   depend on body arrival order.
2. Bodies connect in parent order, each after its parent is executed.
3. Every requested, arrived, parked or parent-waiting block is in the
   look-ahead along the best chain, which the configured body window
   bounds, or is an alternative at a fork on the chain the node acts on,
   whose number only the proof of work in their headers bounds.
4. Complete Volumes are CID-verified and stored through the shared content
   layer.
5. Worker tasks never mutate consensus state. Their results return as
   events to the serial runtime loop.
6. Content and header evidence are durable before the tree-wide fact
   transaction that names them, and state is published only after that
   transaction commits.

## Child proofs are separate

Child work proof acquisition is a separate concern
([Proof-derived child work](proof-derived-work.md)). A child header carries
bounded inline `ChildBlockProof` values; the durable local evidence index
holds only proofs this node already credited, to serve them. Peers supply
verifiable bytes, never a validity verdict or remote parent-state authority.
