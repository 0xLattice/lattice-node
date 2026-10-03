# Lattice Node Protocol Boundary

The Lattice library is the normative owner of validation, state transitions,
work accounting, and fork choice. Its `spec.md`, `foundational-architecture.md`,
`consensus-fork-choice.md`, and `philosophy.md` define protocol behavior. This
document records how `lattice-node` realizes that boundary.

## Chain identity

A process hosts one Nexus-rooted tree. Every level has one absolute
Nexus-inclusive path:

```text
Nexus
Nexus/Payments
Nexus/Payments/Receipts
```

The root and operator-selected descendants run as independent consensus levels
inside one `NodeCore`. Paths are immutable setup and signed transaction replay
protection; the shared overlay and HTTP surface use them for routing. Each
level validates its own sparse route and chooses its own canonical projection.

The pinned Nexus genesis CID is:

```text
bafyreigv5sprcqkq52sonreff7yh6bgg5lgaekvzceiddnkckzb2vzguem
```

It contains the deterministic premine transaction for public key
`ed01fe416588df6e7fa5213c0d3e430f504bb5203172120c86b874826b55f53bdb7d`.
On an empty store, the node constructs it locally, recomputes its CID, and
uses it only for configured root bootstrap. The CID is a trust anchor, never a
peer-admission signature permit. Every transaction in any genesis has empty
signers and signatures. Nexus is admitted only at the configured CID. A child
root is built from its configured spec and the parent's entering state, then
admitted only with a valid mined directory proof. Ordinary post-genesis
transactions remain signature-strict.

This genesis is a storage cutover. Existing node data is not migrated; remove
the old chain directory before starting this version.

## Transactions

HTTP messages carry concrete transaction bodies with their
signatures. A cashew header alone is not a complete transaction payload.
`lattice-node` binds the concrete body back to its CID before admission, then
Lattice validates the transaction for its signed absolute path, which the host
must serve.

Lattice accepts only the domain-separated `lattice-tx-v1` envelope signature;
a signature over the bare body CID is invalid. One body therefore has exactly
one valid signature form per key.

A block pays its reward and fees to its `rewardRecipient`, a header field the
proof of work covers; a block with none burns them. The recipient is only an
address: process identity is never converted into wallet identity, and the
node never receives a private key.

## Work and hierarchy evidence

One mined root CID identifies one physical grind. It has one terminal block
location per chain and may be projected across exact hierarchy edges. Repeated
observations of that root do not create additional work.

Same-chain predecessor connectivity makes a later grind support its ancestors
within that chain's GHOST calculation; it does not move the grind's terminal
location onto an ancestor. The sparse directory proof itself identifies the
root grind and its unique terminal location in each traversed chain.

CID spellings are normalized at the content-addressing boundary before they
become work keys. Alternate multibase text for the same CID therefore cannot
create a second identity. This encoding rule is distinct from branch
canonicity: every accepted branch's eligible work still counts whether or not
that branch is the current canonical projection.

A child candidate is delivered with a sparse proof from the mined root to that
exact child. Lattice verifies the directory path and derives target-qualified
work directly from the proof. The carrier block need not itself be valid,
accepted, connected, or canonical: proof-of-work is a physical fact, not a
parent-consensus claim. Work influences fork choice only after the child block
is accepted and connected. No node-local work floor exists: any filter on work
that can reach fork choice would be consensus-relevant, so the chain's own
target is the only work gate.

Parent canonicity never affects work. A node hosts a child only with every
ancestor, and the child reads two narrow facts from its co-hosted parent: the
set of states produced by fully executed parent blocks, and attributed runs
for its directory under spec §9.10. The parent cannot declare the child valid
or choose its tip.

Every child block anchors its `parentState` directly to the parent chain's
executed-from-genesis set. The continuity link therefore runs from the empty
state to the named state; it is not a link from the child's predecessor. A
weighed but unexecuted parent block issues no fact. A child block whose required
state is not yet present parks and is retried when its parent level executes
more history. Child genesis follows the same anchor rule.

A run report names a quantity only. The child binds it to its own directory,
the block named by a verified carrier proof, and a grind already credited at
that location. It derives `runWork - ownWork` under an identity keyed by the
carrier and directory, accepts only strict increases, and never revokes it.

A locally submitted grind is one `NodeCore` step. The root and every carried
block whose target the hash meets contribute to one path-keyed `NodeBatch`;
all affected facts and cursors commit together before any new snapshot is
published. A remotely learned carried block follows the same acquisition and
proof path on the shared overlay. A missing proof is requested with the child
header from a peer that streamed it; no peer can provide the parent-state
verdict.

`parentState` commits the carrier's `prevState`. It is not a parent-block
backlink and is never inverted to discover ancestry.

## Import and durability

All ingress follows one sequence:

```text
acquire
  -> verify
  -> produce one path-keyed NodeBatch
  -> retain complete selected volumes and header evidence
  -> atomically commit every affected level and cursor
  -> publish the resulting level snapshots
```

The transaction is the durability boundary. Success means the complete tree
batch is durable; failure publishes none of it and stops the runtime. Live
execution and recovery consume the same immutable facts. Path-keyed facts,
indexes, and cursors share `state.db`; content lives in `volumes.db`; incomplete
header boundaries and child proofs live in `header-evidence.db`.

## Network plane

The process has one Ivy network plane. Sync messages carry an absolute path,
and a peer session serves every level both hosts. The overlay exchanges
transaction announcements, path-scoped sync messages, and content.

Provider discovery is keyed only by chain genesis: the node periodically
announces Nexus and each active hosted child genesis. It does not publish a
provider record per block or state. When verified Nexus progress stalls, it
retries disconnected bootstrap peers and a bounded set of providers found for
the Nexus genesis.

Parent facts, run reports and merged-mining candidates never cross a network
plane: they pass in-process between co-hosted levels.

The overlay currently requires node protocol version 6; mixed-version peers
refuse the session.

A level's weigh log streams header and proof entries by position. Stream pages
carry IDs only. `getData` and `getAncestors` return bounded header entries that
contain the canonical block bytes, an optional child index, the credited
`ChildBlockProof` values for that block, and a genesis spec when needed. The
receiver verifies every header and proof before adding it to its own log.
A child index larger than the node's `maxChildIndexBytes` (default 1 MiB) or
a proof larger than `maxProofBytes` (default 64 KiB) is unavailable on that
node, like content it cannot fetch: never judged, never blamed. These are local
resource limits, not consensus rules.
Durable sync cursors are written in the same tree-wide transaction as the
facts they pass.

Verified child proofs are indexed locally by chain path, child CID, and grind
root in `header-evidence.db`. The index is recovery and serving evidence, not a
second network or consensus authority. A restart refuses unreadable or
misindexed proof rows. When serving a child header, the node attaches the
proofs it has already verified; a receiver missing a streamed proof requests
the corresponding header entry from the peer that advertised it.

Peer content exchange is Volume-native. An announcer names one complete Volume
by its root CID and must serve that Volume from the exact authenticated session
that made the claim. Each connection must complete a compatible hello before it
may request a Volume, including a same-key replacement connection. Entry CIDs,
bounded framing, and atomic publication are transport/storage details; node
protocol messages never request arbitrary CID selections.
Merged-mining candidates pass in-process. One template job reads an immutable
epoch copy of every hosted level and recursively builds at most one candidate
per directory. A child with an executed tip builds on that tip; a child with
no root builds a genesis from its configured spec and the carrier's entering
state; a root that is weighed but not yet executed waits. Nested genesis waits
until its parent has executed a block of its own. A sibling built before a
child imports another carried block is ordinary fork input: the child's fork
choice settles it just as it settles stale blocks in conventional merged
mining. Candidate content is retained with the issued work and becomes durable
only if the submitted grind actually secures that level.

Each candidate-root content session uses the node's `NodeResourcePolicy` for
archive bytes, Volume count, and member count. `ChainSpec.maxBlockSize` remains
chain-selected validity for that chain's complete block Volume boundary
(excluding the spec and materialized state Volumes). Unknown specs and parent
witnesses receive separate node-local byte checks before decoding. Exceeding a
local ceiling declines or defers acquisition without proving the candidate
invalid or punishing its advertiser.

Hierarchy authorization comes from the host, not from a process key choosing
a branch: a child level trusts only the parent level it is co-hosted with,
read in-process, and no network peer holds a parent or child role. CAS bytes are non-secret availability and grant no validity:
the consumer verifies every CID and the exact Lattice evidence it reads.

### Transaction pool

The mempool is operationally first-class but never consensus authority.
Transactions are same-chain Volumes: peers advertise a transaction Volume root,
the receiver pulls it from that exact session, resolves the transaction, and
re-materializes the canonical typed Volume locally. Unrelated peer-supplied
members are never retained or relayed. Lattice then validates the transaction
against the current state, and the node relays only a newly admitted root.
Co-hosted parent and child levels never merge mempools.

The pool separates executable, future-nonce, and temporarily unavailable
transactions by signer nonce. Template selection advances a dependency
frontier across every signer, choosing the highest-fee eligible transaction
without copying state validity out of Lattice. The pool applies
bounded replacement and low-value eviction (there is no time-based expiry),
caps non-ready work per
signer, and always evicts non-ready work before executable work regardless of
an unpaid declared fee. It revalidates after every canonical change.
Transactions confirmed on the new chain leave the pool;
ordinary transactions from removed blocks are reinserted when still valid.
Locally submitted transaction roots survive restart and are revalidated before
becoming visible again. Live pool roots use process-owner VolumeBroker pin
deltas and are unpinned on removal; startup clears that owner before restoring
only durable local submissions. Peer transactions are therefore serveable while
pooled but never become restart authority.

## External mining

The node constructs the final nonce-zero template and owns transaction
selection, contextual child candidates, target calculation, import,
durability, and publication. It never runs a nonce-search loop.

`lattice-mining-coordinator` fetches work, allocates disjoint ranges, detects a
changed tip, and submits `workID + nonce`. `lattice-miner` only searches one
immutable serialized block/range assignment.

The miner-facing API is:

```text
POST /mining/templates
POST /mining/work
```

Template requests may name one reward recipient per absolute chain path. The
node partitions those recipients through the hierarchy, carries a child's
block only when it pays the recipient named for that chain, and issues only
the final parent template.

There is no template mode or deployment transaction. A merged-mining template
may carry a child genesis when that hosted level has no root and has a
configured spec; later templates carry ordinary child candidates.

## HTTP surface

Two listeners serve two surfaces. The unauthenticated operator adapter binds
loopback only and refuses any other bind address; it carries the writes and
the operator-only reads:

```text
GET  /status              (with the template digest)
GET  /metrics
POST /transactions
POST /mining/templates
POST /mining/work
```

The public read listener (`--public-read-port`) binds all interfaces and
serves only the bounded, non-mutating read allowlist below; the same routes
are registered on the loopback listener so the two cannot drift. `/health`
is served from an ungated snapshot and omits the template digest.

```text
GET|HEAD /health
GET /transactions/:cid, /accounts/:owner
GET /api/block/latest, /api/block/:id, /api/block/:id/transactions,
    /api/block/:id/children, /api/transaction/:cid, /api/state/account/:addr,
    /api/mempool, /api/peers, /api/chain/info, /api/chain/spec,
    /api/chain/genesis
```

See [RPC API](rpc-api.md) for DTOs and [Architecture](architecture.md) for
component ownership.
