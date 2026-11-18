# Architecture

## One node, one hosted chain tree

One `lattice-node` process hosts a Nexus-rooted tree. Nexus is always the
runtime root; `hostedChildren` adds the child paths that this operator chooses
to serve. A nested child is valid only when every ancestor is hosted by the
same process.

```text
lattice-node
  Nexus
  Nexus/Alpha
  Nexus/Alpha/Beta
```

The process has one identity, one Ivy overlay, one RPC listener, one content
store, and one serial runtime loop. Each hosted path still has independent
consensus state, fork choice, sync state, mempool, and a path-keyed stream in
the node's fact journal.
Messages, transactions, reads, and mining work identify the path they concern.

## Dependency direction

The node is split into a deterministic core and an I/O shell:

```text
HTTP requests ─┐
Ivy messages ──┼─> NodeRuntime ─> NodeCore.step(event) ─> ordered effects
timers/jobs ───┘        │                                  │
                       │                                  ├─> NodeStorage
                       │                                  ├─> content fetch
                       │                                  └─> Ivy send
                       └─> published snapshots ─> ChainReads ─> HTTP responses
```

The dependency points inward. `LatticeNodeCore` knows consensus values and
plain events, but it does not know SQLite, Ivy, HTTP, files, clocks, or tasks.
`LatticeNode` owns adapters and executes the core's effects. The daemon only
maps HTTP requests and responses.

## Deterministic core

`ChainCore` is the state machine for one chain path. It owns:

- header synchronization and fork choice;
- body acquisition and execution scheduling;
- child-proof admission;
- the mempool and mining-template state;
- the immutable snapshot published to readers.

`NodeCore` owns one `ChainCore` per hosted path. Its synchronous `step` method
routes a `NodeEvent` to the right level, coordinates parent/child facts, and
returns ordered `NodeEffect` values. A mined subtree is handled in one node
step, so all contributing levels agree on what the submitted grind changed.

Time is an input to `step`; work such as execution and proof verification is
represented by a job effect whose result returns as another event. This makes
the same core usable by production and deterministic simulation.

The core source is grouped by responsibility:

```text
LatticeNodeCore/
  Chain/       ChainCore, selection, bodies, child proofs
  Host/        NodeCore and multi-level coordination
  Mempool/     transaction-pool policy
  Mining/      mining state and issued work
  Sync/        header sync and decoded sync messages
```

## Production runtime

`NodeRuntime` is the production shell around `NodeCore`. One serial task owns
the core and is the only code that calls `step`. Network messages, RPC writes,
timer firings, content arrivals, and worker results all enter that task as
plain inputs.

For each turn the runtime preserves the core's effect order:

1. Persist the `NodeBatch` and referenced content.
2. Publish the new per-level snapshots and read views.
3. Execute sends, fetches, jobs, timers, disconnects, and RPC replies.

Network ingress is bounded before it reaches the loop. Worker tasks never
mutate core state; they post their results back as events. A persistence
failure is fail-stop because publishing state that was not durably recorded
would make restart behavior disagree with the live process.

The production source is grouped by adapter boundary:

```text
LatticeNode/
  API/             read operations; the request/response models are LatticeNodeAPI
  Configuration/   immutable process configuration and genesis policy
  Content/         content-addressed decoding and Ivy content adapters
  Mining/          template assembly and multi-level mining plans
  Networking/      handshake, overlay frames, sync codec, Ivy delegate
  Observability/   metrics and sync tracing
  Runtime/         NodeRuntime and storage-backed effect execution
  Storage/         SQLite facts, indexes, boot recovery, and locks
```

## Storage and recovery

`NodeStorage` is the runtime's storage gateway. It owns one tree-wide
`NodeStore`, the shared `DiskBroker`, retained-root scopes, and the durable
local mempool journal. Facts, accepted-block indexes, and stream cursors carry
their absolute chain path.

Weighed header material and credited child proofs live in `state.db` beside
the facts that reference them. A sync header can arrive before the full block
Volume, so this data cannot be inserted into the immutable Volume store as
though it were a complete boundary.

```text
<storage>/
  state.db             facts, headers, child proofs, indexes, cursors, state diffs, local mempool
  volumes.db           shared materialized content and retained roots
  volume-bundles.db    cache: per block, the Volume roots served together
```

`volume-bundles.db` is a cache and no part of the recovery unit: nothing but
bundle serving reads it, a node runs without it, and it may be deleted while
the node is stopped.

Persistence is content-first: referenced Volumes become durable before the
fact transaction that names them. One admission's Volumes (a block's once
its execution found it valid or it was mined here, or the post-states of
one step) are one `volumes.db` transaction,
then retained. The complete `NodeBatch` then commits in one SQLite transaction
across every affected chain path, including each path's headers, child
proofs, and sync cursors. A crash cannot leave part of a block's content or a
parent-level half of a multi-level grind.

Content stays in `volumes.db` because a retention scope names it, and each
scope says why. A block's body (its own Volume and its transactions') is
named by that block on its chain, so a transaction two blocks carry stays
until both are let go of. What executions read and create (state, specs,
policy modules) and the Nexus genesis block are named by the chain. A body
is let go of when its block is found invalid, and, when the operator keeps
no bodies beyond the ones the node operates on (`blockBodies: none`), when
another block becomes its chain's tip. When the operator keeps recent
state (`state: recent`, or `none`, which is a window of one block), what a
step's executions stored is named by its chain and the height of the
step's newest block, retained in the transaction that stores it, and is let
go of, every such height in one transaction, once that height is a state
window or more below the chain's tip and, on `recent`, the counts (below)
have moved there. On `recent` each chain also has a counted
scope, the reference counting with delayed deletion of OpenEthereum's journal
database: the count of each node is the places it holds in the state of the
chain's act-on tip plus the places the blocks above a cursor, a window below
the tip, replaced, and the scope's marker names the cursor and the tip. The
counts move to the tip in one adjustment once it has climbed a window above
their own (at once when it is on another branch, and at a start or a
maintenance pass), so while they follow the tip the windows hold at most
two windows of executions; each move is computed from the facts
of the blocks entering and leaving the act-on chain and of the blocks the
cursor passes (each executed block's state diff, which `state.db` keeps for
the state window), under a compare-and-swap of the marker, so the counts, the
cursor and the tip are written together or not at all; the windows are let
go of only once the counts reached the tip. The store refuses to count a
node it does not hold, so what the counts name is held. Counts that cannot
follow (a reorganization below the cursor, a missing fact or diff) or that the store
refuses are replaced by a state sync, as snap sync does: the state of an
act-on block a few below the tip (or of the tip itself when a block between
them kept no diff, as after a move to `recent` or onto a fork whose window
went) is walked off the loop, every node pinned
under a staging scope as it is visited and read from peers when missing,
then the difference from the counts, moved on to the tip, is written in one
adjustment. A start checks each chain's counts against the store first, and
a maintenance pass checks again those that moved since. A node
the counts would start counting and the store lacks is healed the same way
first. On `recent` and on `none`, what a block mined here reads is named by
that block until it executes; a block found valid is stored without the
state it read, its parent's, which the counts and windows keep or peers serve. Kept state is a cache: whatever
reads state the store lacks (execution, a submitted transaction's check, a
state read) reads it from peers. Pins are in the store and a start leaves
them as it finds them, but for the scopes earlier versions kept a tip's
state under, which it lets go of, the counts of a chain no longer hosted or
no longer kept on `recent`, and staging the counts no longer need, and
sweeps what no scope names.

A fact does not depend on its content being held, so a store that lacks
content its facts name is not damaged.

- Executing a block reads what its body fetch brought: the block and the
  state it touches come from this store or from peers. The parent's own
  node comes from its header record when its body is not held.
- Building a template, and storing a mined block and the child blocks it
  carries, read this store, then a block's header record, then peers. What
  a read asked of peers is remembered in memory, within the operator's
  budget for one fetch, so a template's reads can serve the block mined on
  it. A peer chooses what else it sends with a Volume: none of that is
  remembered, and nothing a peer sent is written to the Volume store as it
  came. The store's Volumes are only the ones this node derives when it
  stores a block, and a block a peer sent is stored only once its execution
  has found it valid: until then its body is read into memory, and read
  again whole from peers if memory let it go.
- Checking a submitted transaction reads this store alone, and so do the
  public read routes: anyone may submit or read, and neither spends this
  node's requests to its peers. A transaction whose state is not held stays
  pooled, unchecked.

Every entry is checked against its CID. A read nobody can serve is no
verdict: a block parks and is asked for again, and a template is not built.
Boot reads no content to restore: it stores the Nexus genesis block again
when the store lacks it, since nothing else can supply that block's own
node.

`state.db` keeps each fact once, by id, with the level's staged batch that
first held it and its place in that batch: the block index Bitcoin keeps
for good. Facts are never deleted. A block fact carries no state diff; on
`recent` each executed block's diff is undo data, kept in `state_diffs` for
the state window only. `BootRecovery` validates the databases before
networking starts. `NodeRuntime.boot` then rebuilds each hosted level's
`ChainCore`, parent before child, from that level's facts read in the order
it first took them (`ChainTree.restore(facts:)`): one key range per level,
and the weigh log rebuilt from it keeps every position a peer's stream
cursor names. A saved child proof names its entries by CID: block nodes and
child indexes are read from `headers` and `child_indexes`, and the rest
from `proof_entries`, so it is served byte for byte as credited. Each
commits in the transaction of the work fact it produced.

There are no storage migrations. `state.db` and `volumes.db` are one recovery
unit and must be wiped together on a schema cutover.

## Networking and synchronization

The modules, node roles and rules that a change to sync, storage or the wire
is reviewed against are in [sync architecture](design/sync-architecture.md);
this section describes the code as it stands.

The Ivy adapter has three distinct wire responsibilities:

- `ChainHandshake` establishes the Nexus identity and chain-root context;
- `ChainSyncWire` translates decoded `SyncMessage` values to bounded overlay
  frames for a specific hosted path;
- `OverlayWire` carries process-level announcements such as transaction
  availability.

Wire validation and canonical decoding happen at the adapter boundary. Policy
decisions remain in `NodeCore` and `ChainCore`. The sync state itself is split
into `HeaderSync`, `BodyPipeline`, and `ChildProofSync` so a header, its body,
and the work proving a child block are not conflated.

A child header is not a second kind of block. It is an ordinary block header
for a child path plus one or more `ChildBlockProof` values showing which
ancestor grind contributed work to it. That is why the former
`ChildHeaders.swift` is now `ChildProofs.swift`: the file owns proof admission
and verification, while ordinary header synchronization stays in `Sync/`.

Child levels sync whole-chain top-down: a child level reads its peers only
once its parent level has caught up (the parent's one-way `synced` latch),
since its work and runs come from parent blocks. A page's peer proofs are checked in one
job off the loop and applied in one step; a grind the parent's committing
block lets this node derive is derived, not checked
([proof-derived work](design/proof-derived-work.md#top-down-weighing)).

## API and reads

The HTTP surface has one unversioned set of routes. The daemon decodes a
request, calls `NodeRuntime` for mutations or `ChainReads` for reads, and
encodes the returned API model. There is no second service actor and no
version-routing layer.

RPC mutations are core events with reply IDs:

- submit a transaction;
- request a mining template;
- submit mined work.

Reads do not enter the serial loop. `NodeRuntime` publishes immutable
`ChainSnapshot` and `NodeReadView` values; `ChainReads` combines those with
content-verified reads from `NodeStorage`. Each hosted child has its own
`ChainReads` instance. A request for a path this node does not host is a 404.

## Hosted children and merged mining

Every hosted child has its own `ChainCore`. A parent template may carry the
latest candidate from each direct child, and that candidate may recursively
carry its own child. The template digest includes every hosted level, so a
change to what a child's next block would carry, a new child candidate, or a
child block makes existing miner work stale.

A child candidate commits its carrier's entering state as its `parentState`, and
Lattice requires a child's anchor to move only forward along the parent's
history (spec §5.3 step 6). After a parent reorganization the child's act-on
tip may be anchored on the abandoned parent branch, where no candidate on the
canonical parent can extend it. The template then builds on the heaviest
executed child tip whose anchor the entering state advances from
(`NodeRuntime.anchoredTip`), carrying neither the pool, which stays on the
act-on tip, nor children. Honest work therefore moves to that branch, and the
child reorganizes with its parent once the branch is heavier.

A nested child's first block can be built only after its parent has executed a
block of its own. Consensus binds the child genesis to the parent's state. If
the parent pays no block rewards and otherwise never changes state, it cannot
produce the distinct state needed to host a nested child. Operators must fund
state progression on a parent chain before expecting a nested child to start.

When work is submitted, `NodeStorage` stores only child blocks for which the
grind's verified proof contributes work. `NodeCore` then weighs the root and
all qualifying carried children in path order.

## External mining

```text
lattice-mining-coordinator
  │ POST /mining/templates
  ▼
lattice-node
  │ immutable candidate + search target
  ▼
lattice-miner workers
  │ nonce result
  ▼
lattice-mining-coordinator
  │ POST /mining/work
  ▼
lattice-node runtime and durable effects
```

The node owns chain truth, template construction, and submission validation.
The coordinator owns work lifecycle and range allocation. Workers only search
nonces for an immutable assignment.
