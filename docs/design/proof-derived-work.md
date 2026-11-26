# Proof-derived child work

> **Status:** Current description.
> **Purpose:** How a child chain's work and its parent-state continuity fit
> together across Lattice and `lattice-node`: what the node verifies, what
> it takes from its co-hosted parent level, how it syncs child levels, and
> the invariants both keep. The consensus rules themselves are normative in
> the [Lattice specification](https://github.com/0xLattice/Lattice/blob/59.3.0/docs/spec.md)
> ([§5.3](https://github.com/0xLattice/Lattice/blob/59.3.0/docs/spec.md#53-child-chain-block-validation),
> [§9.1](https://github.com/0xLattice/Lattice/blob/59.3.0/docs/spec.md#91-verified-work-contributions),
> [§9.5](https://github.com/0xLattice/Lattice/blob/59.3.0/docs/spec.md#95-cross-chain-evidence-independence),
> [§9.10](https://github.com/0xLattice/Lattice/blob/59.3.0/docs/spec.md#910-parent-attributed-run-work)).

## Motivation

Child security is the physical work that commits to a child block, directly
or indirectly.

- A grind's directory proof commits to the child explicitly.
- A later parent block that descends from that carrier without
  re-committing commits to it indirectly, and its work counts too, once,
  through run attribution (spec §9.10).
- Parent canonicity never counts: runs follow parent pointers, not the
  parent's canonical chain.

Every accepted child block therefore receives ordinary, immutable work
facts: proof-derived contributions for its grinds, and one attributed-run
contribution per carrier. Once imported, normal same-chain GHOST is
sufficient.

There is no live inherited-work projection: nothing pushes a snapshot of
the parent's weight, with revisions and completion markers, into a separate
inherited branch of GHOST. This preserves Lattice's central property:
content-addressed data is portable and verifiable, while each chain remains
sovereign over validity, storage policy and fork choice.

## Three graphs, three questions

Never use one graph as evidence for another:

1. The directory-commitment graph proves which block a grind explicitly
   commits to and how much real work that grind contributes.
2. The immediate parent's accepted state-transition graph proves that a
   child's parent-state reference moves forward along a connected, valid
   parent history.
3. The child's accepted-block graph routes imported work through same-chain
   GHOST.

Directory descent is not parent-chain descent. A root may descend through
several child directories in one proof. A later block in the parent's own
chain adds child work only through the run of its nearest committing
ancestor, by parent pointer (spec §9.10); a parent block with no ancestor
committing into the directory adds none.

## Securing-work rule

The spec defines when a work proof is valid (§5.3 steps 1 to 4) and how
much it credits (§9.1). In summary, and without replacing those sections:

- The proof binds every supplied block to its CID bytes, resolves the
  sparse directory path uniquely to the exact terminal child, binds
  `child.parentState` to `carrier.prevState` at every vertical hop, and its
  root hash must beat the terminal child's target.
- One grind credits one quantity at one child location, priced by the
  root-most block on the path whose target the root hash beats, raised if
  greater by the terminal child's own target.
- Repeated evidence for the same grind and location keeps the strongest
  verified value. Conflicting claims for one grind and location are
  rejected. Different grinds sum.

What follows from the rule for the node:

- **Work validity is orthogonal to block validity.** The blocks on the
  directory path do not need to be valid, imported, connected or canonical
  on their own chains: proof of work is a physical fact, not a
  parent-consensus claim.
- **Work counts only once the child is connected.** A proof cannot affect
  fork choice until its terminal child is accepted and connected in that
  child's chain.
- **One grind, one location per chain.** One mined root CID identifies one
  physical grind. It has one terminal block location per chain and may be
  projected across exact hierarchy edges. Repeated observations of that
  root do not create additional work.
- **Ancestors are supported, not relocated.** Same-chain predecessor
  connectivity makes a later grind support its ancestors within that
  chain's GHOST calculation; it does not move the grind's terminal location
  onto an ancestor.
- **CID spellings are normalized** at the content-addressing boundary
  before they become work keys. Alternate multibase text for the same CID
  therefore cannot create a second identity. This encoding rule is distinct
  from branch canonicity: every accepted branch's eligible work still
  counts whether or not that branch is the current canonical projection.
- **No node-local work floor exists.** Any filter on work that can reach
  fork choice would be consensus-relevant, so the chain's own target is the
  only work gate.
- **`parentState` is not a backlink.** It commits the carrier's
  `prevState`. It is not a parent-block backlink and is never inverted to
  discover ancestry.

### The binding gates work, not only import

The terminal directory carrier binds
`child.parentState == carrier.prevState`. The binding is enforced inside
`ChildBlockProof.verifySecuringWork`, which returns `.protocolInvalid`
before any `VerifiedWorkContribution` is minted, so a failure withholds the
work contribution and the import together. Work crediting and the vertical
binding are therefore one check.

That binding is not an anchor: the carrier need not be a valid parent
block, so both sides of the comparison may be chosen by one party. What
establishes that the child's `parentState` is a state the parent
legitimately reached is continuity
([Parent-state continuity](#parent-state-continuity)).

### Attributed runs

The second source of a child location's weight is the attributed run (spec
§9.10). The co-hosted parent level partitions its connected graph into
runs, one per commitment into the child's directory, and serves
`(carrier, directory, childBlock, grinds, runWork, ownWork, revision)`.

The child:

1. binds the report: its own directory, this child block, one of the
   carrier's grinds already credited there;
2. credits `runWork − ownWork` under
   `AttributedRunIdentity(carrier, directory)`, a contribution separate
   from any grind and keyed by the carrier;
3. ratchets it on its own value: idempotent, monotone, refused rather than
   saturated, never revoked.

The quantity is the co-hosted parent level's word, the trust the child
already extends to it for state continuity. The location and binding are
checked locally, and a verified path can replace the reported one with no
consensus change. The identity's encoded key is named `committerBlockHash`.

Run attribution is not an inherited-work feed: there is no snapshot and no
projection. Proof-derived and attributed-run contributions alike become
ordinary `VerifiedWorkContribution` facts at a child location. An
attributed run is summed like any other contribution, under its own
identity, and is never a projection of the parent's weight.

## Parent-state continuity

The rule is spec §5.3 step 6. Every child block's `parentState` is checked
on its own, at every height including block 1 and the genesis:

- When the field is not the empty state, the child requires a
  `ParentStateContinuityLink` from its predecessor's `parentState` (from
  the empty state for a child genesis) to that exact CID. Its co-hosted
  immediate parent answers true only when its executed-from-genesis set
  produced the named state, at or below a block that produced the
  predecessor's.
- A weighed-only post-state claim is insufficient.
- Parent canonicity does not alter a state that was actually executed on
  any valid branch.
- A non-genesis block may commit the empty state, and then needs no fact,
  only while its predecessor does too. Dropping back to the empty state
  from a real anchor is invalid.
- A child genesis naming the empty state is invalid: genesis must anchor to
  a real state produced by its parent.

### How the node answers it

Each chain level durably records validation facts for executed blocks. That
recovered executed set answers continuity; no second delta database or
header replay protocol exists.

1. `BodyPipeline.parentFact` reads the block's `parentState` and its
   predecessor's from their headers and names the fact the block needs:
   `ParentStateContinuityLink(parentPath, predecessor's parentState,
   parentState)`.
2. The co-hosted parent level answers from its executed set
   (`ParentContinuity.hasContinuity`).
3. A missing state is retryable unavailability while the parent is still
   advancing: the block waits and is retried when its parent level executes
   more history.

The fact is in-process and non-portable. A weighed but unexecuted parent
block issues no fact.

### Why this is enough

Grandparent validity follows by induction. A parent block cannot enter the
parent level's durable graph until that level has applied the same rule
against its immediate parent. The child never receives the grandparent
tree, header path or verdict. Nexus terminates the induction.

Child genesis needs no deployment verdict. The host builds it from the
configured spec and the carrier's entering parent state. A valid mined
root-to-child proof supplies its work, and the child level validates and
chooses it like any other child root.

Arbitrary peers may supply any required content-addressed Volume. They
never supply a validity verdict. A node hosts every child with its whole
ancestry and answers parent facts from its own co-hosted parent level, so
it validates its own parent chains recursively to Nexus; there is no remote
parent whose answer could differ between child nodes. The facts are local
reads, unsigned and non-portable: a portable certificate is exactly the
light-client artifact this design forbids.

## Data and process boundaries

- `ChildBlockProof` is the canonical securing-work evidence. Header pages
  carry a bounded set of proofs inline with each child header.
- Each chain derives validity from content-addressed Volumes it acquires
  and verifies. Ivy and VolumeBroker move complete Volumes; there is no
  second validation CAS.
- Cross-chain continuity reads only the co-hosted immediate parent's
  recovered validated graph; child genesis needs no deployment
  acknowledgement.
- The host records weighed headers, child indexes and credited proofs in
  `state.db`, in the transaction of their facts. They are local scheduling
  and serving state, not portable authority.
- Proofs learned from peers or produced by local merged mining are verified
  before credit. A node can later serve the exact saved proof with the
  child header.
- The proofs one step takes from peers (a page of headers) are checked
  together in one job off the step, as geth's `VerifyHeaders` checks a
  batch of headers off its import loop, and the job's answers are applied
  in one step: one persist and one commit for the page. The job reads from
  the store a weighed block it needs; the core reads nothing. A proof that
  fails disconnects its sender; the page's other proofs that verify still
  credit, since each verdict is its proof's own, not its sender's.
- Gossip, sync, acquisition and persistence may run asynchronously. Chain
  insertion and fork choice consume only complete, durable import batches.
- Stream cursors advance in the same tree-wide transaction as the facts
  they cover, so a crash cannot skip imported evidence.
- Candidate content is retained with issued mining work; a submitted grind
  transfers the roots only for levels whose targets it actually meets.

Child proofs in a check share one operator byte budget across all sources,
with no per-peer bound ([Push-only derived grinds](#push-only-derived-grinds)).
A flood of valid but cheap pages is bounded only by network ingress: it
costs the checks, never a verdict. A valid proof for a child that has not
yet arrived is not punishable; lying about advertised availability or
returning malformed bytes is.

## Top-down weighing

A child block's work comes from its parent level: its grinds' carriers are
parent blocks or shares on them (§9.5), and its runs are parent blocks
after its carrier (§9.10). All of that is in what the parent level has
weighed; none of it is in what the parent has executed. So a child level is
synced top-down by weight: it reads its peers' streams, and so weighs any
header from them, only once its parent level has weighed a whole log.

### The latch

That is the parent's `headersSynced` latch: the log of a peer running that
level read to its end with every header in it applied, and the level
holding a weighed block, as headers-first sync reads headers to the end
before it asks for what hangs from them.

- It is the first half of `synced`, which also asks that the act-on tip be
  the heaviest tip whose bodies may be had and gates a peer's transactions.
- A parent that has read a log to its end and is still fetching or
  executing bodies has latched `headersSynced` and not `synced`, and its
  children are open: weight never waits on execution, a chain's own or its
  parent's.
- What a child block's execution needs of its parent, the state its parent
  block produced, it waits for block by block, and the parent executing
  that block wakes it.
- The latch is one-way: once it is set, the child follows live, and a new
  parent block never pauses it.
- A grandchild waits for its child level's latch in turn. Nexus is not
  gated.

### Before and after the latch

Until its parent has weighed a whole log, a child level asks its peers for
nothing: no stream page and no header, and a page pushed to it is not
taken. Its stream cursors stay where they were. After any step in which the
parent is latched, however it latched, a level that held its peers back
reads every peer's stream from its cursor. Its own mined grinds and the
blocks submitted on this node still weigh: a mined grind weighs every level
it reaches in one step.

### Prior art

The nearest prior art is Polkadot's parachains: a parachain node follows
its relay chain, taking as best and final the parachain blocks relay blocks
include. Here the gate is coarser, one latch per level instead of a check
per block, since a child block's weight is read from its parent level (its
grinds' carriers and its runs), which a level that has not yet weighed a
whole log does not hold.

With the gate open while the parent still executes, the levels' working
sets are held at once, each within its own bounds: its pending headers, its
headers awaiting proof, its proofs in a check, and a body window of fetched
blocks. Execution keeps its own rule: a child block executes once its
parent state is held and continuous
([Parent-state continuity](#parent-state-continuity)).

## Push-only derived grinds

A parent block can commit a child block `C` at `children[X]` by CID alone,
for example when its miner carries a `child/X` = `C@P` transaction (spec
§6.3) without hosting `X`. No `ChildBlockProof` for `C` leaves that miner,
so the grind's work at `C` has no proof on the wire. Whoever holds `C`'s
bytes, with the co-hosted parent level, derives the grind's proof from its
own trees (`ChildBlockProof.extending`, shared with the mined-carrier
path), credits it as a verified proof, and relays it with `C`'s header, so
peers credit the same grinds from the gossiped proof. Nodes never fetch `C`
over the network, and a derivation reads nothing from peers.

### When a proofless header is taken

A child header with no proofs is taken only when it is wanted. One that a
connected parent block commits is wanted: the parent level's committers
index (`ChainTree.committers(of:directory:)`) spans forks and is never
pruned, so a proofless `C` committed on any branch is accepted. An
uncommitted one is dropped.

### What triggers a derivation

1. **Carrier weigh.** For each parent block weighed in a step that commits
   into a hosted directory, the child level derives the grinds it has not
   credited at the committed block, if it holds that block, awaits a proof
   for it or has it pending. A block it does not know is neither derived
   nor fetched.
2. **Arrival.** A child block that enters the level to await a proof, by
   gossip or a local submit, has the grinds of each of its committers
   derived.

A derivation is pure over this node's own content and its answer is always
applied; credit is idempotent. It does not wait on peer proofs that are in
a check, so neither a bogus front-run proof nor a peer that leaves can keep
`C` from being credited.

### Derived or checked, per block

The rule is the same at every level with a parent, whatever its depth, and
is decided per block:

- A block a weighed parent block commits has its work derived, with no
  peer check at all.
- Any other block's work is its peers' proofs, checked.

A peer's proof of a grind a derivation credits is not checked: one whose
root is a grind of a weighed parent block committing `C`, while `C`'s
derivation is in flight or is issued in the same step (`C` just arrived).
Both are the same path from the same root, so they verify alike, and
checking both would be double work.

A peer's proof is checked when no derivation will answer for it: the parent
committed `C` by no weighed block, or `C`'s derivation already ran and
credited nothing for content it could not read (the proof is then checked
when it is sent again).

How many blocks are derivable is a property of the chains, not of depth: a
parent that commits its child every block makes the child all derived, one
that rarely does leaves it to peer proofs.

A derived proof that fails blames no one. A header with a derivation in
flight is never evicted. Nothing about a derivation is persisted: a
restored child level treats every block it restores as arrived, so its
committers are derived again.

### The author pushes until `C` is weighed

`C` enters a node only by gossip or by a local submit
([`POST /child-blocks`](../rpc-api.md)). The node keeps
no record of authored blocks. A submit dropped before its carrier is
weighed, or lost to a restart, an unhost or an eviction, is pushed again;
`lattice child commit` does this until the submit answers `tree`
([Child chains](../child-chains.md#committing-a-child-block-yourself)).

### Budgets

- Proofs in a check share one operator budget,
  `ChildProofConfig.maxQueuedBytes` (default 16 MiB), over all sources. A
  proof past it is dropped without blame and nothing is evicted; the block
  is looked up again, so its hole is asked again once the checks drain.
- There is no bound on the number of checks: a page's proofs are one job.
- Headers awaiting a proof share the global `maxAwaiting`, which evicts the
  oldest with no proof in a check and no derivation in flight.
- There are no per-peer or per-source caps: peers are cheap to make, so
  such a cap protects nothing.

Security comes from proof-of-work and verification: a proofless header is
taken only when wanted, and a peer-sent proof that fails is a proof-of-work
failure that disconnects its sender.

## What the design leaves out

There is no generic forest, accumulator, light-client protocol, quorum,
second CAS, or second fork-choice implementation. No wire topic carries
securing or inherited work, and no store keeps inherited-work snapshots,
parent-work facts or cursors, or parent-work readiness. A §9.10 run report,
handed in-process from a parent level to a hosted child, carries a report
the child binds and derives into a work fact, never a weight snapshot.

## Properties

1. A verified observation of a root whose hash clears the terminal child's
   target credits exactly the quantity of spec §9.1; an observation that
   does not clear the terminal target yields no contribution at all (no
   work fact, and the block is not imported); a location holds the
   strongest such observation.
2. No root is counted twice at one chain-local location.
3. No branch gains weight without equivalent physical work.
4. Honest nodes converge after connectivity returns.
5. Results are invariant to arrival order and restart.

Lattice checks the fork-choice side of these against an independent
reference: `ForkChoiceOracle`, written from the specification alone and
sharing nothing with the production descent, weight index or arithmetic,
must agree with the production fork choice on the golden, differential and
replay fixtures. Its
[consensus simulator](https://github.com/0xLattice/Lattice/blob/59.3.0/docs/consensus-simulator.md)
quantifies the deterministic tie-break and no-finality tradeoffs under
deep-reorg, selfish-mining and balancing strategies (see the
[adversarial report](https://github.com/0xLattice/Lattice/blob/59.3.0/docs/consensus/adversarial-report.md)).
