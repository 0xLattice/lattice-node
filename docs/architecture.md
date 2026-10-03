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
  API/             request/response models and read operations
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

`HeaderEvidenceStore` is a deliberate sidecar for weighed header material and
credited child proofs. A sync header can arrive before the full block Volume,
so this data cannot be inserted into the immutable Volume store as though it
were a complete boundary.

```text
<storage>/
  state.db             facts, indexes, cursors, and local mempool for the tree
  volumes.db           shared materialized content and retained roots
  header-evidence.db   incomplete header boundaries and child proofs
```

Persistence is content-first: referenced Volumes and header evidence become
durable before the fact transaction that names them. The complete `NodeBatch`
then commits in one SQLite transaction across every affected chain path,
including each path's sync cursors. A crash may leave retained content that no
fact references, but it cannot leave a durable fact without its content or a
parent-level half of a multi-level grind.

`BootRecovery` validates the databases and retained roots before networking
starts. `NodeRuntime.boot` then rebuilds every `ChainCore` from one ordered
scan grouped by path. The evidence sidecar has its own schema epoch and Nexus
identity, and saved child proofs must decode, match their indexes, and cover
every durable child work fact. Startup fails rather than serving child headers
without their proofs.

There are no storage migrations. `state.db`, `volumes.db`, and
`header-evidence.db` are one recovery unit and must be wiped together on a
schema cutover.

## Networking and synchronization

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
carry its own child. The template digest includes every hosted level, so a new
child transaction, child candidate, or child block makes existing miner work
stale.

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
