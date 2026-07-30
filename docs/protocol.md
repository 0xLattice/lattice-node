# Lattice Node Protocol Boundary

The Lattice library is the normative owner of validation, state transitions,
work accounting, and fork choice. Its `spec.md`, `foundational-architecture.md`,
`consensus-fork-choice.md`, and `philosophy.md` define protocol behavior. This
document records how `lattice-node` realizes that boundary.

## Chain identity

A process owns exactly one absolute Nexus-inclusive path:

```text
Nexus
Nexus/Payments
Nexus/Payments/Receipts
```

The path is immutable setup, not transaction-selected routing state. A process
never embeds child runtimes. Nested child commitments are data; each child
process validates its own sparse route and chooses its own canonical projection.

The pinned Nexus genesis CID is:

```text
bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq
```

It contains the deterministic premine transaction for public key
`ed01fe416588df6e7fa5213c0d3e430f504bb5203172120c86b874826b55f53bdb7d`.
On an empty store, the node constructs it locally, recomputes its CID, and
uses it only for configured root bootstrap. The CID is a trust anchor, never a
peer-admission signature permit. Every transaction in any genesis has empty
signers and signatures; an exact configured Nexus CID or parent `GenesisAction`
CID authorizes that genesis. Ordinary post-genesis transactions, including
transactions carrying `GenesisAction`s, remain signature-strict.

This genesis is a storage cutover. Existing node data is not migrated; remove
the old chain directory before starting this version.

## Transactions

HTTP and hierarchy messages carry concrete transaction bodies with their
signatures. A cashew header alone is not a complete transaction payload.
`lattice-node` binds the concrete body back to its CID before admission, then
Lattice validates the transaction for the process's absolute path.

Lattice accepts both the current domain-separated transaction preimage and the
historical body-CID preimage. Mixed multisignature envelopes are valid when each
individual signature verifies under one accepted form. This compatibility does
not weaken body, signer, nonce, or path validation.

Mining rewards are ordinary externally signed transactions. Process identity is
never converted into wallet identity, and the node does not receive a reward
private key.

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

Parent canonicity never affects work. An authenticated parent process may issue
genesis and parent-state continuity facts; it cannot declare the child valid,
assign work, or choose the child's tip. Continuity is transitive: for consecutive
child blocks, the new parent-state CID must equal or be reachable through the
parent's connected accepted same-chain graph from the predecessor's parent-state
CID. A restarted child can recompute fork choice entirely from durable accepted
blocks and proof-derived work. When admission needs a new genesis or continuity
fact, the child asks its authenticated immediate-parent process. A positive
answer is an unsigned acknowledgement bound to that live session and exact
request; peers cannot relay it.

`parentState` commits the carrier's `prevState`. It is not a parent-block
backlink and is never inverted to discover ancestry.

## Admission and durability

All ingress follows one sequence:

```text
acquire
  -> verify
  -> store sparse validation content and complete selected volumes
  -> retain required roots
  -> atomically stage one immutable Lattice batch
  -> apply that exact batch
  -> project one chain
```

The stage callback is the durability boundary. Success means the complete batch
is durable; failure exposes none of it. Live execution and recovery both apply
the same staged facts. Publication, proof replay, and other post-commit network
effects cannot rewrite an already durable admission result.

Each path stores operational metadata and Volume-root references in `state.db`,
and every content-addressed byte in `volumes.db`. VolumeBroker is the only
durable local CID-to-bytes store. The node owns acquisition, authentication,
retention, routing, and operational projections. Lattice owns accepted
consensus facts and never uses storage presence or peer identity as validity.

## Network planes

The node uses two Ivy sessions:

- the public same-chain overlay exchanges announcements and same-path content;
- the private hierarchy plane connects one configured immediate parent with its
  direct children and carries contextual candidates, exact parent-fact queries,
  and root-bound proof facts.

Both planes currently require node protocol version 4. Parent-fact
request/response semantics are versioned, so mixed-version peers refuse the
session and must be upgraded together.

Peer content exchange is Volume-native. An announcer names one complete Volume
by its root CID and must serve that Volume from the exact authenticated session
that made the claim. Each connection must complete a compatible hello before it
may request a Volume, including a same-key replacement connection. Entry CIDs,
bounded framing, and atomic publication are transport/storage details; node
protocol messages never request arbitrary CID selections.
During a candidate round, the parent may serve the ephemeral provisional
carrier only as that request's root and only for the lifetime of the round.

Candidate replies are offers, not miner-work durability. After staging a
template, the parent sends each exact child advertiser the complete sorted set
of candidate CIDs referenced by all remaining live templates. The child first
applies the same replacement recursively to its direct children, then commits
its local issued set and acknowledges. The parent returns the new work only
after every required acknowledgement. The set is bounded by the 16-entry
template book; an empty set releases all offers and issued reservations.
Requests and acknowledgements are accepted only on the authenticated direct
parent/child session for the exact child path. Removal delivery is serialized
but asynchronous because over-retention is safe and a child must never stall
parent consensus. A removal may name committed candidates as handoffs; the
child atomically installs their durable admission-handoff ownership before
replacing the issued set, and applies the same transition recursively to
committed descendants. Parent-proof acquisition is a separate retryable path.
Expired idle work may remain over-retained until the next template, submission,
invalidation, or reconnect boundary; this is bounded and never makes expired
work valid.

Each candidate-root content session uses the node's `NodeResourcePolicy` for
archive bytes, Volume count, and member count. `ChainSpec.maxBlockSize` remains
chain-selected validity for that chain's complete block Volume boundary
(excluding the spec and materialized state Volumes). Unknown specs and parent
witnesses receive separate node-local byte checks before decoding. Exceeding a
local ceiling declines or defers acquisition without proving the candidate
invalid or punishing its advertiser.

Hierarchy authorization comes from the configured immediate-parent key or a
durable parent-issued child directory/genesis relationship, not a process key
choosing a branch. CAS bytes are non-secret availability and grant no validity:
the consumer verifies every CID and the exact Lattice evidence it reads.

### Child-evidence availability

The root-independent direct edge is derived from an ordinary child-evidence
Volume. Its canonical one-entry manifest commits only the child CID and proof
envelope; no duplicate direct-edge Volume exists.
Child-chain validation Volumes are acquired from the child chain's exact
same-chain advertisers. For a parent-created genesis, the exact configured
parent is the preferred source because it created and retains the complete
Volume roots; any exact same-chain advertiser may supply the same CID-verified
Volumes as an availability fallback. A parent
persists the edge when it issues the child commitment; a child persists the
incoming edge when it validates that commitment. Children never return edge
inventories or topology to parents.

On the same-chain overlay, a child advertises a child-evidence Volume whose
envelope contains only the complete structural work proof. Parent validity
verdicts are never serialized into the Volume. Nexus neither requests nor
accepts portable attachments.

Both inventories are cursor-bound and name one exact Volume at a time. Ivy
streams each complete Volume as an ordered, bounded sequence of frames;
the receiver applies the one-entry evidence archive bound before allocating
that stream. Refusing a globally valid archive because it exceeds this local
application bound, or because receive capacity is temporarily full, is
reputation-neutral and retried; malformed framing remains punishable.
Ivy owns request deadlines and session fencing,
while the node caps concurrent acquisition and recycles a silent or malformed
session. Exact-announcer binding provides accountability and prevents one peer
from making the node search the wider network for arbitrary roots; it is not a
source of content validity.

Parent-to-child evidence uses the same shape: each index or live summary names
the parent's stable sync-source ID, monotone evidence ordinal, child CID,
physical root CID, and complete attachment Volume CID. An index walk fixes its
`through` ordinal on the first page and advances by durable `next` cursors, so
new evidence cannot reshuffle the walk. A changed source ID restarts at zero.
The child fetches the Volume directly from the exact parent session, validates
it, and durably retains it in a pre-admission inbox before advancing its scan
cursor. Live summaries use the same inbox without advancing that cursor.
Admission transfers ownership to ordinary chain recovery before releasing the
inbox root. Multiple roots for one child are separate summaries. No proof-root
pagination or evidence request/response layer exists beneath this inventory.

For child genesis, the configured immediate parent positively acknowledges only
an exact `(directory, child CID, deployment prevState)` tuple derived from an
accepted parent block. For a non-genesis candidate, equal parent-state
references need no request; otherwise the parent positively acknowledges only
an exact transitive reachability pair from its recovered validated graph.
Responses are unsigned, bound to the current authenticated session and pending
request, and never portable. Parent canonicity does not affect reachability.

Child work is derived directly from the candidate's content-addressed directory
proof. A carrier need not be admitted or valid on its own chain: the root grind
must be real, beat the terminal target, and commit uniquely to the child along
the directory path. Once the child is accepted and connected, that contribution
is ordinary chain-local GHOST input. There is no live parent-work stream or
consensus-readiness handshake.

### Transaction pool

The mempool is operationally first-class but never consensus authority.
Transactions are same-chain Volumes: peers advertise a transaction Volume root,
the receiver pulls it from that exact session, resolves the transaction, and
re-materializes the canonical typed Volume locally. Unrelated peer-supplied
members are never retained or relayed. Lattice then validates the transaction
against the current state, and the node relays only a newly admitted root.
Parent-child hierarchy sessions never merge mempools.

The pool separates executable, future-nonce, and temporarily unavailable
transactions by signer nonce. Template selection advances a dependency
frontier across every signer, choosing the highest-fee eligible transaction
without copying state validity out of Lattice. The pool applies
bounded replacement, expiry, and low-value eviction, caps non-ready work per
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
selection, contextual child candidates, target calculation, admission,
durability, and publication. It never runs a nonce-search loop.

`lattice-mining-coordinator` fetches work, allocates disjoint ranges, detects a
changed tip, and submits `workID + nonce`. `lattice-miner` only searches one
immutable serialized block/range assignment.

The miner-facing API is:

```text
POST /v1/mining/templates
POST /v1/mining/work
```

Template requests may contain externally signed reward transactions keyed by
absolute chain path. The node partitions those rewards through the hierarchy
request and issues only the final parent template.

The request mode defaults to `normal`, which excludes every transaction that
contains a `GenesisAction`. `deployment` selects one fully backed local or
descendant deployment subtree per round and propagates its hardest target to
Nexus. This separation prevents unavailable child content from poisoning
ordinary mining.

## HTTP surface

The unauthenticated adapter is loopback-only:

```text
GET  /health
GET  /v1/status
POST /v1/transactions
POST /v1/mining/templates
POST /v1/mining/work
POST /v1/children/intents
```

See [RPC API](rpc-api.md) for DTOs and [Architecture](architecture.md) for
component ownership.
