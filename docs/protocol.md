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
bafyreick4k7a6bxz4huqx4wiu3z5yph4tnpl4zvq2pi6xv3ouribtvzs24
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

HTTP messages carry concrete transaction bodies with their
signatures. A cashew header alone is not a complete transaction payload.
`lattice-node` binds the concrete body back to its CID before admission, then
Lattice validates the transaction for the process's absolute path.

Lattice accepts both the current domain-separated transaction preimage and the
historical body-CID preimage. Mixed multisignature envelopes are valid when each
individual signature verifies under one accepted form. This compatibility does
not weaken body, signer, nonce, or path validation.

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

Parent canonicity never affects work. A node hosts a child chain only
together with every ancestor, one level per chain in one process, and a child
level reads its parent facts from its co-hosted parent level's own validated
state: the genesis the parent recorded for the child's directory, whether the
parent executed a block producing a state, and the run reports of spec §9.10
for the child's directory. The parent level cannot declare the child valid or
choose the child's tip. A run report names a quantity, and only a quantity:
the child binds it — its own directory, the block THIS chain's verified
carrier proof says that carrier commits (a report naming any other block is
refused), one of the carrier's grinds already credited there — and derives
the credit itself, `runWork − ownWork`,
under an identity keyed by the carrier and directory, applied only as a
strict increase and never revoked. The quantity is the node's own
computation over its own parent chain: the same parent level that answers
state continuity, which gates minting outright, so no new trust class is
introduced. Every child block anchors its
`parentState` directly to the PARENT CHAIN'S GENESIS — not to its predecessor:
the state must be reachable from the empty state through the parent's connected,
EXECUTED same-chain graph, which is to say it is a state real parent history
actually produced.

Anchoring to the predecessor instead would make this an induction, and the
induction has no base. The weighed tier never runs these checks, so a weighed
predecessor proves nothing about its own `parentState`; a block could match its
unchecked predecessor and be imported on no evidence at all. Every block
therefore proves its own anchor, at every height, block 1 included — there is no
height-1 exemption, and none is needed, because the executed-from-genesis
frontier answers the question without walking the chain.

Execution is required because a parent attests that it PRODUCED a state, and the
weighed tier records a DECLARED post-state without running it — attesting an
unexecuted claim would let a forged `receiptState` settle a withdrawal that was
never paid.

Because that anchor is the only continuity question the protocol defines, it is
also the only continuity question a parent level answers. (A parent level also
reports runs for the directories it hosts: it pushes the changed run of each served
directory's nearest carrier after every accepted import and after every
credit it is itself handed by its own parent — so a run flows down every
level without a re-read — for each run a child could actually credit (its
`runWork` exceeds its `ownWork`), once per value it reaches, into the
co-hosted child's ordered mailbox; and a child reads the runs of carriers
from its co-hosted parent level itself: a block's carriers when it imports a
block they carried, and its recent carriers when it starts, so a push it
could not yet bind or one it missed while stopped is recovered without
waiting for the next parent block. Those report work; they answer nothing
about continuity or validity.) A
requirement naming any other `from` is malformed, not merely unusual: no
correct child can produce one, and answering it would mean running a general
ancestry walk on the parent's consensus actor. Refusing the shape is not a
budget — the question the protocol actually asks is still answered in full,
and identically on every node — which is why the answer needs no visit
ceiling: it walks no chain and is independent of height. A truncated answer
would have been worse than a refusal: a refused question is retried, while a
truncated one is silently wrong and splits honest nodes by local policy.

A restarted child recomputes fork choice entirely from its durable fact log:
accepted blocks, proof-derived work, and the attributed work-only batches it
credited from parent run reports. A block its parent carried is a network
block: imported weighed on the verified proof — in fork choice with its work
at once, executed when the chain would step into it — never held back for a
continuity fact or a rule not yet met. Its carrier evidence is recorded
with the acceptance, and the proofs this chain composes for its own
children follow from it. A carrier this chain refused, or one Lattice
returns relay-only, records nothing: this chain has no reader for it.
Only the parent facts it answers —
the genesis links a child's first block anchors to — wait for its
validation, since a child must not anchor to state this chain has not
executed. When this host mined the grind, the parent level hands the
carried block and its proof to the co-hosted child level in memory before
it imports and commits its own block: one grind is one subtree insert,
children first. A crash between the two loses only the parent block, as a
solo miner that crashes before broadcasting loses its block; a handoff is
not retried. A stopping host refuses template and work requests on every
level before it stops any, so no grind is handed to a stopping level. Any other
carried block arrives through ordinary acquisition: the child overlay
announces it or the predecessor walk reaches it, and a block reached without
its proof is looked up by CID in the overlay peers' child-evidence indexes.
When import needs a genesis or continuity fact the parent level does not
hold yet, the block parks on that fact and is readied again when the parent
level's tip moves; nothing is asked of a peer, and no answer crosses the
network.

`parentState` commits the carrier's `prevState`. It is not a parent-block
backlink and is never inverted to discover ancestry.

## Import and durability

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
effects cannot rewrite an already durable import result.

Each path stores operational metadata and Volume-root references in `state.db`,
and every content-addressed byte in `volumes.db`. VolumeBroker is the only
durable local CID-to-bytes store. The node owns acquisition, authentication,
pruning, routing, and operational projections. Lattice owns accepted
consensus facts and never uses storage presence or peer identity as validity.

## Network plane

Each chain has one Ivy network plane: the public same-chain overlay, which
exchanges announcements, same-path content, and child-evidence index roots.

Parent facts, run reports and merged-mining candidates never cross a network
plane: they pass in-process between co-hosted levels.

The overlay currently requires node protocol version 5; mixed-version peers
refuse the session.

One overlay request topic is answered in its full form so older peers still
sync from this node: the accepted-leaves page. A node sends the accepted-leaves
request only as a one-shot, cursor-less frontier pull, when a peer's announced
height is within the range-sync depth threshold of its own fetched tip; the
cursored descent it answers is never sent. Header-graph range sync
(common-ancestor negotiation plus forward pages), live announcements and the
predecessor walk carry sync.

Child-block proofs travel through each child node's child-evidence index: a
cashew dictionary keyed by child block CID whose values are the block's proof
set, keyed by grind (`rootCID`), each naming the `ChildEvidenceVolume` that
carries the proof. A proof enters the index only when it contributes work to
its block. Every trie node and every proof set is its own Volume, so the index
root is independent of insertion order and equal sets have equal roots. A node
pushes its root (`lattice.overlay.child-evidence.root.v1`, one CID) when a
session becomes ready and whenever the root changes; the receiver keeps each
peer's latest root. One serial worker then reads peers' roots as ordinary
Volumes through one budgeted session per peer: it looks up the blocks parked
on a missing proof (one proof each per pass; the rest arrive by the walk once
the block is admitted and indexed), and walks the peer's trie against its own, skipping equal
subtrees and descending only into blocks it holds, to fetch the proofs it
lacks. Each proof fetched is admitted as a weighed package seed. A proof that
does not bind its key and grind, or that contributes no work to a held block,
is blamed on the sole supplier of a complete fetch, whose session is recycled
and root dropped; content that is unavailable or incomplete is never blamed.
No local witness-size limit applies to a proof from a peer's index: one within
the protocol cap that weighs is admitted.

Peer content exchange is Volume-native. An announcer names one complete Volume
by its root CID and must serve that Volume from the exact authenticated session
that made the claim. Each connection must complete a compatible hello before it
may request a Volume, including a same-key replacement connection. Entry CIDs,
bounded framing, and atomic publication are transport/storage details; node
protocol messages never request arbitrary CID selections.
Merged-mining candidates pass in-process. Each hosted child level keeps one
pre-built candidate against a provisional carrier on its parent level's
validated tip, for the miner's recipients and minimum work for the child's
subtree. It rebuilds that candidate — one build at a time, a change during a
build running one more — when the parent's tip, its own state or the plan
changes, under its own lease only and reading its parent without taking the
parent's gate or lease. The parent's template path reads each hosted child's
latest candidate without waiting on the child: no parent path awaits a
child, so no child can stall parent consensus. A child learns of a carry
this host mined from the parent level's in-memory handoff, and of any other
from its overlay. A template carries
at most one candidate per directory, built on its current tip's post-state,
never the block the branch already carries for that directory (a
children-only carrier leaves the post-state, so that candidate still fits;
carried again it would only be credited once more). A sibling of the carried
block, built before the child imports it, is carried like any candidate: the
child's fork choice settles the siblings, as stale blocks settle in
conventional merged mining.
A child builds no candidate while its execution walk is stepping, or while its validated
tip is behind its weighed tip and the walk can still step; it builds again
when the walk decides, on the tip it reached, and it rebuilds only when an
input of the candidate changed.
Candidates are
not miner-work durability: the child keeps a candidate's content by its own
bounded budget, oldest first, until the carried block's import owns the
roots or the budget sheds it.

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

### Child-evidence availability

The root-independent direct edge is derived from an ordinary child-evidence
Volume. Its canonical one-entry manifest commits only the child CID and proof
envelope; no duplicate direct-edge Volume exists.
Child-chain validation Volumes are acquired from the child chain's exact
same-chain advertisers. A parent
persists the edge when it issues the child commitment; a child persists the
incoming edge when it validates that commitment. Children never return edge
inventories or topology to parents.

On the same-chain overlay, a child advertises a child-evidence Volume whose
envelope contains only the complete structural work proof. Parent validity
verdicts are never serialized into the Volume. Nexus neither keeps nor reads a
child-evidence index.

Ivy streams each complete Volume as an ordered, bounded sequence of frames.
Refusing a globally valid archive because it exceeds a local
application bound, or because receive capacity is temporarily full, is
reputation-neutral and retried; malformed framing remains punishable.
Ivy owns request deadlines and session fencing,
while the node caps concurrent acquisition and recycles a silent or malformed
session. Exact-announcer binding provides accountability and prevents one peer
from making the node search the wider network for arbitrary roots; it is not a
source of content validity.

For child genesis, the parent level answers positively only for an exact
`(directory, child CID, empty parent state)` tuple recorded by a
`GenesisAction` in an accepted parent block; a self-contained child genesis
commits to the empty parent state. For a non-genesis block, equal parent-state
references need no fact; otherwise the parent level answers positively only
when it executed, from its genesis, a block producing the block's
`parentState`. Both are reads of the parent level's own state in the same
process: nothing is sent, signed, or portable. Parent canonicity does not
affect reachability.

Child work is derived directly from the candidate's content-addressed directory
proof. A carrier need not be imported or valid on its own chain: the root grind
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
POST /v1/mining/templates
POST /v1/mining/work
```

Template requests may name one reward recipient per absolute chain path. The
node partitions those recipients through the hierarchy, carries a child's
block only when it pays the recipient named for that chain, and issues only
the final parent template.

There is no template mode. A transaction carrying a `GenesisAction` is selected
like any other pooled transaction. A child genesis is self-contained, so a
template never carries one; merged-mining templates attach only ongoing
direct-child candidates supplied by their processes.

## HTTP surface

Two listeners serve two surfaces. The unauthenticated operator adapter binds
loopback only and refuses any other bind address; it carries the writes and
the operator-only reads:

```text
GET  /v1/status              (with the template digest; reconciling)
GET  /metrics
POST /v1/transactions
POST /v1/mining/templates
POST /v1/mining/work
```

The public read listener (`--public-read-port`) binds all interfaces and
serves only the bounded, non-mutating read allowlist below; the same routes
are registered on the loopback listener so the two cannot drift. `/health`
is served from an ungated snapshot and omits the template digest.

```text
GET|HEAD /health
GET /v1/blocks, /v1/blocks/:cid, /v1/transactions/:cid, /v1/accounts/:owner
GET /api/block/latest, /api/block/:id, /api/block/:id/transactions,
    /api/block/:id/children, /api/transaction/:cid, /api/state/account/:addr,
    /api/mempool, /api/peers, /api/chain/info, /api/chain/spec,
    /api/chain/genesis, /api/chain/children, /api/chain/endpoints
```

See [RPC API](rpc-api.md) for DTOs and [Architecture](architecture.md) for
component ownership.
