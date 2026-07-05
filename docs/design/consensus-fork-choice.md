# Consensus & Fork Choice — node realization

**The consensus model is defined once, in the Lattice library — not here.** The
block model, generalized proof-of-work, the `trueCumWork` work metric, the
fork-choice rule, its security argument, and its O(depth) evaluation all live in
the consensus library:

- **Normative:** `Lattice` → `docs/spec.md` §9
- **Design of record (rationale):** `Lattice` → `docs/consensus-fork-choice.md`

This document covers only **how the node realizes** that model — the wiring that
is the node's responsibility, not the consensus rules themselves.

## What the node must preserve (load-bearing)

Two properties from the model carry over verbatim; the node must hold them
regardless of how it stores or transports anything:

1. **Fork choice is a single `trueCumWork` max** — one metric, no secondary
   positional key. A block's weight is its own-chain `subtreeWeight` plus the
   verified proof contributions that secure it from outside the chain; the
   heaviest fork wins, an exact tie holds the incumbent. The node never
   reintroduces a `(parentIndex, work)` two-tier key.
2. **One acceptance chokepoint, on every path.** `trueCumWork` is summed only over
   blocks that passed acceptance, and the *same* validity gate must run on every
   path that installs chain state — gossip/extend **and** sync/replace alike. The
   recurring consensus-bug class is a sync/replace path skipping what the
   gossip/extend path enforces; one chokepoint closes it.

## Node wiring

- **Inherited-weight provider.** `trueCumWork`'s inherited term is *derived from
  verified proof contributions, never from parent-chain canonicity*. When a
  parent carrier proves it committed a child block, the node records each
  content-addressed securing block contribution and installs
  `ChainState.setInheritedWeightProvider` over that verified contribution store.
  A later duplicate carrier is still a proof fact: if it is persisted for
  restart/sync, the same idempotent contribution must be applied live so fork
  choice is identical before and after restart.
- **Proof availability, not parent canonicity.** Parent blocks are data sources
  and proof carriers. A child node may fetch a parent block, header, state
  Volume, or proof from the parent process, from a peer, or from local CAS; the
  source does not make the data authoritative. Authority comes from
  content-addressing, PoW, `ChildBlockProof`, and state-root proofs. If the
  parent later reorganizes, that does not erase the historical fact that a
  fetched block committed a child block or transformed one parent state root into
  another. The child chain should react only to newly verified proof
  contributions and to its own fork choice, not to the parent's current canonical
  tip.
- **Proof-carrying child sync.** A child block is accepted only with a path-bound,
  root-anchored `ChildBlockProof` that the securing parent committed it
  (`parent.children ∋ child`) — never a self-hash fallback. This is what lets the
  node attribute inherited work without trusting a peer-supplied number.
- **Child-only carriers (direct-child edge).** A securing carrier need not be
  canonical, and — when it **is** the PoW root (the direct-child case — proof
  path length 1) — need not clear its own target. A shared grind that clears the
  child's easy target but not the root's hard target yields a **child-only
  carrier**: never a canonical Nexus block, yet a valid carrier for the child.
  `parentBlockWorkVerified` admits it by the child-proof predicate
  (`childTarget >= carrierHash`, a path-bound `ChildBlockProof`, parent-state
  anchor), resolved from the proof's **own sealed entries** — never by standalone
  root PoW. It contributes **zero** inherited root weight (the `inherited(B)`
  zero-credit rule), so admission cannot inflate fork choice; it only lets the
  child advance. Gating a direct-child carrier on standalone root PoW permanently
  wedges a pure parent-stream follower.
- **Per-process topology.** In production the chain tree spans OS processes (Nexus
  in the root process; each child via `--subscribe-p2p`); the node wires a dedicated
  parent link per child and extracts/validates child blocks from the parent's
  `children`. See [chain addressing](chain-addressing.md),
  [fractal structure](fractal-structure.md), and the
  [process trust model](process-trust-model.md) — the spawn tree is how a child
  obtains its complete root→target GHOST view from a parent it can authorize.

## Why this model

The parent-canonicality model seems tempting because a parent chain already has a
fork choice, but it is the wrong authority boundary for a recursive chain tree.
It couples a child's state and liveness to unrelated parent-side reorganizations,
forces parent processes to remember child views, and makes behavior depend on
which node currently believes which parent tip is canonical. That breaks the
per-process/fractal model: a child is its own chain, not a mutable view owned by
its parent.

The proof-availability model keeps the boundary clean:

- **Validation stays cryptographic.** A fetched object is trusted only if its CID
  re-hashes, its PoW/root proof verifies, and its state proof is anchored to the
  claimed state root. A peer or parent process can provide bytes, not authority.
- **Children remain independent.** Parent canonicity matters to the parent for
  its own mining, mempool, and local fork choice. It does not by itself roll back
  child state, remove child proof history, or rewrite child fork choice.
- **The rule recurses.** A grandchild treats its parent the same way its parent
  treats the root: subscribe for proof-carrying blocks, verify the sparse path,
  fold verified work contributions, then relay its own accepted blocks.
- **Restart and live behavior match.** Persisted proof facts are replayed into
  the same inherited-work store used live, so a restart cannot discover a
  different fork choice merely because the node had previously treated duplicate
  parent carriers as "availability only."
- **Availability is allowed to be redundant.** Multiple peers may serve the same
  parent block/state root, and multiple parent carriers may secure the same child
  block. Deduplication is by content/proof contribution ID, not by trust in a
  canonical parent branch.

This is the same separation used throughout the node: storage and transport make
committed content available; validation decides whether that content can affect
state or fork choice.

## References

- **Lattice library** — `docs/spec.md` §9 (normative) and `docs/consensus-fork-choice.md` (design of record). The consensus algorithm is defined there, once.
- [Fractal structure](fractal-structure.md) — the organizing principle this realizes.
