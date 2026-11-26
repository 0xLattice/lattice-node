# Lattice node architecture

How `lattice-node` is built: what one process hosts, how decisions are
separated from I/O, how storage and recovery work, and how sync, reads and
mining attach. It describes the code as it stands.

Related pages:

| For | Read |
|---|---|
| Messages between nodes | [Peer protocol](protocol.md) |
| The claims the simulators and tests check | [Correctness invariants](correctness-invariants.md) |
| The rules a change to sync, storage or the wire is reviewed against | [Sync architecture](design/sync-architecture.md) |
| What the node is for, how each part compares with other clients, measurements | [Node design](design/node-design.md) |
| Why a part is built the way it is | [Design documents](design/README.md) |
| The source tree, directory by directory | [Development](development.md#code-layout) |

## One process, one tree of chains

One `lattice-node` process hosts a Nexus-rooted tree. Nexus is always the
runtime root; the `hostedChains` setting adds the child paths that this
operator chooses to serve. A nested child is valid only when every ancestor is hosted
by the same process.

```text
lattice-node
  Nexus
  Nexus/Alpha
  Nexus/Alpha/Beta
```

The process has:

- one identity;
- one Ivy overlay;
- one serial runtime loop;
- one fact database (`state.db`) and one Volume store per hosted chain;
- one loopback operator HTTP listener, and optionally a remote operator
  listener and a public read listener ([HTTP API](rpc-api.md)).

Each hosted path still has independent consensus state, fork choice, sync
state and mempool, and a path-keyed stream in the node's fact journal.
Messages, transactions, reads and mining work identify the path they
concern.

## Core and shell

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
plain events, but it does not know SQLite, Ivy, HTTP, files, clocks or
tasks. `LatticeNode` owns the runtime and executes the core's effects
through the storage, network, read and mining modules. The daemon only maps
HTTP requests and responses.

| Module | Role |
|---|---|
| `LatticeNodeCore` | The deterministic state machines: `Chain/` (`ChainCore`, selection, bodies, child proofs), `Host/` (`NodeCore` and multi-level coordination), `Mempool/`, `Mining/`, `Sync/`. |
| `LatticeNode` | `NodeRuntime`, the production shell, with the node configuration and metrics. |
| `LatticeNodeStore` | SQLite facts and indexes, the Volume stores, boot recovery, retention, locks. |
| `LatticeNodeNet` | Handshake, overlay frames, sync codec, the Ivy content source. |
| `LatticeNodeReads` | Read operations (`ChainReads`). |
| `LatticeNodeMining` | Template assembly and multi-level mining plans. |
| `LatticeNodeAPI` | Request and response models. |
| `LatticeNodeConfig` | Operator configuration, topology and the Nexus genesis. |
| `LatticeNodeDaemon` | The CLI and HTTP adapters. |

## Deterministic core

`ChainCore` is the state machine for one chain path. It owns:

- header synchronization and fork choice;
- body acquisition and execution scheduling;
- child-proof admission;
- the mempool and mining-template state;
- the immutable snapshot published to readers.

`NodeCore` owns one `ChainCore` per hosted path. Its synchronous `step`
method routes a `NodeEvent` to the right level, coordinates parent/child
facts, and returns ordered `NodeEffect` values. A mined subtree is handled
in one node step, so all contributing levels agree on what the submitted
grind changed.

Time is an input to `step`. Work such as execution and proof verification
is represented by a job effect whose result returns as another event. This
makes the same core usable by production and deterministic simulation.

## Production runtime

`NodeRuntime` is the production shell around `NodeCore`. One serial task
owns the core and is the only code that calls `step`. Network messages, RPC
writes, timer firings, content arrivals and worker results all enter that
task as plain inputs.

All ingress follows one sequence:

```text
acquire
  -> verify
  -> produce one path-keyed NodeBatch
  -> retain complete selected volumes
  -> atomically commit every affected level and cursor
  -> publish the resulting level snapshots
```

For each turn the runtime preserves the core's effect order:

1. Persist the `NodeBatch` and referenced content.
2. Publish the new per-level snapshots and read views.
3. Execute sends, fetches, jobs, timers, disconnects and RPC replies.

The transaction is the durability boundary. Success means the complete tree
batch is durable; failure publishes none of it and stops the runtime. A
persistence failure is fail-stop because publishing state that was not
durably recorded would make restart behavior disagree with the live
process. Live execution and recovery consume the same immutable facts.

Network ingress is bounded before it reaches the loop. Worker tasks never
mutate core state; they post their results back as events. The loop's
contract and the table of jobs are in
[Sync architecture](design/sync-architecture.md#the-loops-contract).

## Storage and recovery

`NodeStorage` is the runtime's storage gateway. It owns one tree-wide
`NodeStore`, the shared `DiskBroker`, retained-root scopes, and the durable
local mempool journal. Facts, accepted-block indexes and stream cursors
carry their absolute chain path.

### Files

```text
<storage>/
  state.db             facts, headers, child proofs, indexes, cursors, state diffs, local mempool
  volumes/<hash>.db    each hosted chain's content and retained roots, named by the
                       SHA-256 of its path (the root's
                       also holds the constants, the operator's pins and the mempool's)
  volume-bundles.db    cache: per block, the Volume roots served together
```

Weighed header material and credited child proofs live in `state.db` beside
the facts that reference them. A sync header can arrive before the full
block Volume, so this data cannot be inserted into the immutable Volume
store as though it were a complete boundary.

`volume-bundles.db` is a cache and no part of the recovery unit: nothing but
bundle serving reads it, a node runs without it, and it may be deleted while
the node is stopped.

There are no storage migrations. `state.db` and `volumes/` are one recovery
unit and must be wiped together when the schema changes. The operator's
view of these files is in [Storage](storage.md).

### Write order

Persistence is content-first: referenced Volumes become durable before the
fact transaction that names them.

1. One admission's Volumes are one transaction of their chain's Volume
   store, store by store, then retained. An admission is a block's Volumes
   once its execution found it valid or it was mined here, or the
   post-states of one step.
2. The complete `NodeBatch` then commits in one SQLite transaction across
   every affected chain path, including each path's headers, child proofs
   and sync cursors.

A crash cannot leave part of a block's content or a parent-level half of a
multi-level grind. A crash between two chains' stores leaves content no fact
names, retained under its window's scope: it goes when the tip is a window
past it, or with its chain.

### What keeps content

Content stays in its chain's Volume store because a retention scope names
it, and each scope says why.

| Content | Named by | Let go of |
|---|---|---|
| A block's body (its own Volume and its transactions') | That block on its chain, so a transaction two blocks carry stays until both are let go of | When its block is found invalid; and, when the operator keeps no bodies beyond the ones the node operates on (`blockBodies: none`), when another block becomes its chain's tip |
| What executions read and create (state, specs, policy modules) and the Nexus genesis block | The chain | See the state window below |
| What a block mined here reads, on `state: recent` and `none` | That block | When it executes |
| A Volume the operator pins | The operator scope | When it is unpinned |

A block found valid is stored without the state it read, its parent's,
which the counts and windows keep or peers serve.

Kept state is a cache: whatever reads state the store lacks (execution, a
submitted transaction's check, a state read) reads it from peers.

### The state window

When the operator keeps recent state (`state: recent`, or `none`, which is
a window of one block):

- What a step's executions stored is named by its chain and the height of
  the step's newest block, retained in the transaction that stores it.
- It is let go of, every such height in one transaction, once that height
  is a state window or more below the chain's tip and, on `recent`, the
  counts (below) have moved there.

### Counts on `recent`

On `recent` each chain also has a counted scope, the reference counting
with delayed deletion of OpenEthereum's journal database.

- **What is counted.** The count of each node is the places it holds in the
  state of the chain's act-on tip plus the places the blocks above a cursor,
  a window below the tip, replaced. The scope's marker names the cursor and
  the tip.
- **When the counts move.** They move to the tip in one adjustment once it
  has climbed a window above their own (at once when it is on another
  branch, and at a start or a maintenance pass). So while they follow the
  tip the windows hold at most two windows of executions.
- **How a move is computed.** From the facts of the blocks entering and
  leaving the act-on chain and of the blocks the cursor passes (each
  executed block's state diff, which `state.db` keeps for the state
  window), under a compare-and-swap of the marker, so the counts, the cursor
  and the tip are written together or not at all.
- **Windows wait for counts.** The windows are let go of only once the
  counts reached the tip.
- **Counted means held.** The store refuses to count a node it does not
  hold, so what the counts name is held.

### State sync

Counts that cannot follow (a reorganization below the cursor, a missing
fact or diff) or that the store refuses are replaced by a state sync, as
snap sync does:

1. The state of an act-on block a few below the tip is walked off the loop.
   The tip itself is walked when a block between them kept no diff, as
   after a move to `recent` or onto a fork whose window went.
2. Every node is pinned under a staging scope as it is visited, and read
   from peers when missing.
3. The difference from the counts, moved on to the tip, is written in one
   adjustment.

A start checks each chain's counts against the store first, and a
maintenance pass checks again those that moved since. A node the counts
would start counting and the store lacks is healed the same way first.

### What a start does to the store

Pins are in the store and a start leaves them as it finds them, with these
exceptions, which it lets go of:

- the scopes earlier versions kept a tip's state under;
- the counts of a chain no longer hosted or no longer kept on `recent`;
- staging the counts no longer need.

It then sweeps what no scope names.

### Reading content the store lacks

A fact does not depend on its content being held, so a store that lacks
content its facts name is not damaged.

- **Executing a block** reads what its body fetch brought: the block and
  the state it touches come from this store or from peers. The parent's own
  node comes from its header record when its body is not held.
- **Building a template, and storing a mined block and the child blocks it
  carries,** read this store, then a block's header record, then peers.
  What a read asked of peers is remembered in memory, within the operator's
  budget for one fetch, so a template's reads can serve the block mined on
  it.
- **What a peer sent** is never written to the Volume store as it came. A
  peer chooses what else it sends with a Volume: none of that is
  remembered. The store's Volumes are only the ones this node derives when
  it stores a block, and a block a peer sent is stored only once its
  execution has found it valid: until then its body is read into memory,
  and read again whole from peers if memory let it go.
- **A public read of a block body, or of content by CID,** reads this store
  alone: anyone may read, and such a read does not spend this node's
  requests to its peers.
- **Checking a submitted transaction** reads this store first, so what it
  refuses there (a bad signature, the wrong chain, a stale nonce) costs no
  request to peers. State of the tip the store lacks is then read from
  peers, and the transaction is judged again.

Every entry is checked against its CID. A read nobody can serve is no
verdict: a block parks and is asked for again, and a template is not built.

### Recovery

`state.db` keeps each fact once, by id, with the level's staged batch that
first held it and its place in that batch: the block index Bitcoin keeps
for good. Facts are never deleted. A block fact carries no state diff; on
`recent` each executed block's diff is undo data, kept in `state_diffs` for
the state window only.

At a start:

1. `BootRecovery` validates the databases before networking starts.
2. Boot reads no content to restore. It stores the Nexus genesis block
   again when the store lacks it, since nothing else can supply that
   block's own node.
3. `NodeRuntime.boot` rebuilds each hosted level's `ChainCore`, parent
   before child, from that level's facts read in the order it first took
   them (`ChainTree.restore(facts:)`): one key range per level. The weigh
   log rebuilt from it keeps every position a peer's stream cursor names.

A saved child proof names its entries by CID: block nodes and child indexes
are read from `headers` and `child_indexes`, and the rest from
`proof_entries`, so it is served byte for byte as credited. Each commits in
the transaction of the work fact it produced.

## Networking and synchronization

The Ivy adapter has three distinct wire responsibilities:

- `ChainHandshake` establishes the Nexus identity and chain-root context;
- `ChainSyncWire` translates decoded `SyncMessage` values to bounded
  overlay frames for a specific hosted path;
- `OverlayWire` carries process-level announcements such as transaction
  availability.

The messages themselves are in the [peer protocol](protocol.md).

Wire validation and canonical decoding happen at the adapter boundary.
Policy decisions remain in `NodeCore` and `ChainCore`. The sync state
itself is split into `HeaderSync`, `BodyPipeline` and `ChildProofSync` so a
header, its body, and the work proving a child block are not conflated.

A child header is not a second kind of block. It is an ordinary block
header for a child path plus one or more `ChildBlockProof` values showing
which ancestor grind contributed work to it. `ChildProofs.swift` owns proof
admission and verification; ordinary header synchronization stays in
`Sync/`.

Child levels sync top-down by weight:

- A child level reads its peers only once its parent level has weighed a
  peer's whole log (the parent's one-way `headersSynced` latch), since its
  work and runs come from parent blocks the parent has weighed.
- It does not wait for the parent to execute them: a child block's
  execution waits, block by block, for the parent state it names.
- A page's peer proofs are checked in one job off the loop and applied in
  one step. A grind the parent's committing block lets this node derive is
  derived, not checked.

See [Proof-derived child work](design/proof-derived-work.md#top-down-weighing)
and [Body acquisition](design/block-fetching.md).

## API and reads

The HTTP surface has one unversioned set of routes, listed in the
[HTTP API](rpc-api.md). The daemon decodes a request, calls `NodeRuntime`
for mutations or `ChainReads` for reads, and encodes the returned API
model. There is no second service actor and no version-routing layer.

The listeners share handlers. The public read listener
(`--public-read-port`) serves only a bounded, non-mutating read allowlist,
and the same routes are registered on the loopback listener so the two
cannot drift. `/health` is served from an ungated snapshot and omits the
template digest.

RPC mutations are core events with reply IDs:

- submit a transaction;
- request a mining template;
- submit mined work.

Reads do not enter the serial loop. `NodeRuntime` publishes immutable
`ChainSnapshot` and `NodeReadView` values; `ChainReads` combines those with
content-verified reads from `NodeStorage`. Each hosted child has its own
`ChainReads` instance. A request for a path this node does not host is a
404.

## Hosted children and merged mining

Every hosted child has its own `ChainCore`. Merged-mining candidates pass
in-process: one template job reads an immutable epoch copy of every hosted
level and recursively builds at most one candidate per directory. A parent
template may carry the latest candidate from each direct child, and that
candidate may recursively carry its own child.

### What a template carries

| The child level | Its candidate |
|---|---|
| has an executed tip | builds on that tip |
| has no root and a configured spec | is a genesis built from the spec and the carrier's entering state |
| has a root that is weighed but not yet executed | waits |

There is no template mode or deployment transaction. A sibling built before
a child imports another carried block is ordinary fork input: the child's
fork choice settles it just as it settles stale blocks in conventional
merged mining.

Template requests may name one reward recipient per absolute chain path.
The node partitions those recipients through the hierarchy, carries a
child's block only when it pays the recipient named for that chain, and
issues only the final parent template.

The template digest includes every hosted level, so a change to what a
child's next block would carry, a new child candidate, or a child block
makes existing miner work stale.

### After a parent reorganization

A child candidate commits its carrier's entering state as its
`parentState`, and Lattice requires a child's anchor to move only forward
along the parent's history (spec §5.3 step 6). After a parent
reorganization the child's act-on tip may be anchored on the abandoned
parent branch, where no candidate on the canonical parent can extend it.
The template then builds on the heaviest executed child tip whose anchor
the entering state advances from (`NodeRuntime.anchoredTip`), carrying
neither the pool, which stays on the act-on tip, nor children. Honest work
therefore moves to that branch, and the child reorganizes with its parent
once the branch is heavier.

### Nested children

A nested child's first block can be built only after its parent has
executed a block of its own. Consensus binds the child genesis to the
parent's state. If the parent pays no block rewards and otherwise never
changes state, it cannot produce the distinct state needed to host a nested
child. Operators must fund state progression on a parent chain before
expecting a nested child to start.

### Submitted work

Candidate content is retained with the issued work and becomes durable only
if the submitted grind actually secures that level. When work is submitted:

1. `NodeStorage` stores only child blocks for which the grind's verified
   proof contributes work.
2. `NodeCore` weighs the root and all qualifying carried children in path
   order, in one step. The root and every carried block whose target the
   hash meets contribute to one path-keyed `NodeBatch`; all affected facts
   and cursors commit together before any new snapshot is published.

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

The node owns chain truth, template construction and submission validation.
It never runs a nonce-search loop. The coordinator owns work lifecycle and
range allocation. Workers only search nonces for an immutable assignment.
The full contract is in
[Mining role boundaries](design/mining-role-boundaries.md).
