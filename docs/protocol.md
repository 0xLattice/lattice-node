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
genesis and parent-state continuity facts and serves the run reports of spec
§9.10 for the directories it hosts; it cannot declare the child valid or
choose the child's tip. A run report names a quantity, and only a quantity:
the child binds it — its own directory, the block THIS chain's verified
carrier proof says that committer commits (a report naming any other block is
refused), one of the committer's grinds already credited there — and derives
the credit itself, `runWork − ownWork`,
under an identity keyed by the committer and directory, applied only as a
strict increase and never revoked. The quantity is the configured immediate
parent's word: the same trust the child already extends to that process for
state continuity, which gates minting outright, so no new trust class is
introduced. Every child block anchors its
`parentState` directly to the PARENT CHAIN'S GENESIS — not to its predecessor:
the state must be reachable from the empty state through the parent's connected,
EXECUTED same-chain graph, which is to say it is a state real parent history
actually produced.

Anchoring to the predecessor instead would make this an induction, and the
induction has no base. The weighed tier never runs these checks, so a weighed
predecessor proves nothing about its own `parentState`; a block could match its
unchecked predecessor and be admitted on no evidence at all. Every block
therefore proves its own anchor, at every height, block 1 included — there is no
height-1 exemption, and none is needed, because the executed-from-genesis
frontier answers the question without walking the chain.

Execution is required because a parent attests that it PRODUCED a state, and the
weighed tier records a DECLARED post-state without running it — attesting an
unexecuted claim would let a forged `receiptState` settle a withdrawal that was
never paid.

Because that anchor is the only continuity question the protocol defines, it is
also the only continuity question a parent answers. (A parent also serves run
reports for the directories it hosts: it pushes the changed run of each served
directory's nearest committer after every accepted admission and after every
credit it is itself handed by its own parent — so a run flows down every
level without a re-ask — for each run a child could actually credit (its
`runWork` exceeds its `ownWork`), once per value it reaches; and it serves
the runs of the committers a child names: a child asks for a block's
committers when it admits a block they carried, and for its recent committers
after every evidence catch-up round, so a push it could not yet bind or one
it missed while away is recovered without waiting for the next parent block.
Those report work; they answer nothing about continuity or validity.) A
request naming any
other `from` is
malformed, not merely unusual: no correct child can produce one, and serving it
would mean running a general ancestry walk on the consensus actor on a peer's
behalf. Refusing the shape is not a budget — the question the protocol actually
asks is still answered in full, and identically on every node — which is why
this path needs neither a visit ceiling nor a serving rate limit: answering it
walks no chain and is independent of height. A truncated answer would have been
worse than a refusal: a refused question is retried,
while a truncated one is silently wrong and splits honest nodes by local policy.

A restarted child recomputes fork choice entirely from its durable fact log:
accepted blocks, proof-derived work, and the attributed work-only batches it
credited from parent run reports. A block its parent carried is a network
block: admitted weighed on the verified proof — in fork choice with its work
at once, executed when the chain would step into it — never held back for a
continuity fact or a rule not yet met. Its carriage is relayed at once,
with the acceptance, as for a carrier this chain refused: deeper chains are owed the proof of carriage whatever this
chain makes of the block, and the proofs this chain composes for its own
children follow from that relay. Only the parent-process facts it issues —
the genesis links a child's first block anchors to — wait for its
validation, since a child must not anchor to state this chain has not
executed. Until an admission DECIDES it
(accepted, a duplicate, or refused for a reason no retry would change: the
grind missed this chain's target, the block or its evidence is invalid, the
node could not verify it), its evidence stays in the parent-evidence inbox,
the one durable record of a block still to be admitted, replayed on every
restart. Decided is exactly what the node never retries: a deferral persists
nothing, and a decision consumes the entry whether or not it leaves relay
evidence behind. So no stop or crash between a deferral and its retry can
lose a parent-carried block, no refusal can hold an inbox slot for good,
and a child never stays on a branch its parent chain has left for want of
one. It asks its parent for a committer's run when it admits a block that
committer carried and after each evidence round, the fallback for a push it
missed; a credit it already holds never depends on the parent being
reachable again.
When admission needs a new genesis or continuity
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
  root-bound proof facts, and parent run reports
  (`lattice.hierarchy.parent-run-report.v1`, pushed by the parent whenever a
  served run changes; `lattice.hierarchy.parent-run-report.request.v1`, a
  child's request for the runs of the committers it names). A parent that does
  not know the topic drops it unread and the child keeps the credit it already
  holds, so parents roll before children.

Both planes currently require node protocol version 4. Parent-fact
request/response semantics are versioned, so mixed-version peers refuse the
session and must be upgraded together.

Two overlay request topics are legacy-served only: the accepted-leaves page
and the portable-attachment index. A node keeps answering both so an older
peer still syncs from it, but no longer sends either — header-graph range sync
(common-ancestor negotiation plus forward pages), live announcements and the
predecessor walk replaced the accepted-leaves descent, and per-block locate
requests replaced the index walk. The four message types, both server
handlers and the accepted-leaf page store are scheduled for deletion the
release after the fleet upgrades past this one.

Peer content exchange is Volume-native. An announcer names one complete Volume
by its root CID and must serve that Volume from the exact authenticated session
that made the claim. Each connection must complete a compatible hello before it
may request a Volume, including a same-key replacement connection. Entry CIDs,
bounded framing, and atomic publication are transport/storage details; node
protocol messages never request arbitrary CID selections.
A parent pushes its template context to each authenticated direct child
whenever it changes — its validated tip block and the miner's reward plan and
minimum work for the child's subtree — and the child pushes back its current
candidate for that tip whenever one of its inputs changes. Both messages
carry a sequence that is monotonic per session; a lower one is dropped. The
parent holds the latest candidate per child peer — a candidate it already
holds, or an older one, is dropped from the frame's head without decoding
the block — and a template carries every held candidate built on
its current tip's post-state, except a sibling of a child block this chain
already carried (a candidate on the same child parent) that the child
offered before this chain told it of the carry: that block already weighs
at the child, and an uninformed sibling would only reorg the child's tip to
the heavier carrier. A sibling the child offers after being told is
carried; it is then the child's own choice. Nothing is requested at
template time and no child can stall parent consensus. A child builds no
candidate while its validate walk is stepping, while its validated tip is
behind its weighed tip and the walk can still step (the request arms the
walk), or while a candidate it built that the parent's evidence has named
is ready for or in its admission; it offers when the walk or the admission
decides, on the tip it reached, and it rebuilds only when an input of the
candidate changed.
Candidates are
offers, not miner-work durability: the child keeps a candidate's content by
its own bounded budget, oldest offer first, until the carried block's
admission owns the roots or the budget sheds it, and a candidate named in the
parent's evidence is a handoff the budget never sheds. Parent-proof
acquisition is a separate retryable path. Pushes and candidates are accepted
only on the authenticated direct parent/child session for the exact child
path.

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
same-chain advertisers. A parent
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
an exact `(directory, child CID, empty parent state)` tuple recorded by a
`GenesisAction` in an accepted parent block; a self-contained child genesis
commits to the empty parent state. For a non-genesis candidate, equal parent-state
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

There is no template mode. A transaction carrying a `GenesisAction` is selected
like any other pooled transaction. A child genesis is self-contained, so a
template never carries one; merged-mining templates attach only ongoing
direct-child candidates supplied by their processes.

## HTTP surface

The unauthenticated adapter is loopback-only:

```text
GET  /health
GET  /v1/status
POST /v1/transactions
POST /v1/mining/templates
POST /v1/mining/work
```

See [RPC API](rpc-api.md) for DTOs and [Architecture](architecture.md) for
component ownership.
