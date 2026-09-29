# Architecture

## Process boundary

One `lattice-node` process hosts a chain tree: one level per absolute chain
path, each child co-hosted with its whole ancestry (`ChainHost`). `Nexus` is
the only root. The set of levels comes from `lattice.json` (`--config`) and
takes effect when the process starts.

```text
lattice-node process
  Nexus level
    chain: Nexus
    overlay: 4001
    hierarchy (dialed on loopback; firewall): 4002
    RPC: 127.0.0.1:8080
  Nexus/Payments level
    chain: Nexus/Payments
    parent level: Nexus (in-process; evidence over 127.0.0.1:4002)
    overlay: 4101
    hierarchy (dialed on loopback; firewall): 4102
    RPC: 127.0.0.1:8180
```

Each level keeps its own identity key, storage directory, overlay, and RPC
port. A parent level never owns its child's chain state, mempool,
persistence, sync, or fork choice. The host starts levels parent-first and
stops them children-first; stopping one level stops its descendants and
leaves the rest running.

## Identity and addressing

`ChainAddress` accepts only absolute paths beginning with `Nexus`. The final
component is also the parent-relative `directory` edge, but a directory alone
is not a chain identity and is never accepted as a public chain path.

Examples:

- `Nexus` — valid root path.
- `Nexus/Payments` — valid child path.
- `Nexus/Payments/Rollups` — valid descendant path.
- `Payments` — invalid chain path.
- `/Nexus/Payments`, `Nexus/`, and `Nexus//Payments` — invalid.

Nexus has no parent. Every child runs in the same `lattice-node` process as
its whole ancestry, configured through `lattice.json` (`--config`): it reads its
parent facts from the co-hosted parent level, and the host wires its parent
endpoint to the parent level's hierarchy plane on loopback, which carries
only child evidence.

## Runtime components

```text
LatticeNodeDaemon
  ├─ NodeConfiguration     immutable path, keys, ports
  ├─ ChainProcess          block import and durable recovery
  ├─ ChainService          transactions, templates, work results
  ├─ NodeStore             state.db: semantic facts, indexes, root references
  ├─ DiskBroker            volumes.db: materialized CAS volumes
  ├─ Ivy overlay           same-chain peers and content
  ├─ Ivy hierarchy plane   child-evidence delivery, dialed on loopback
  └─ loopback HTTP         thin JSON adapter over ChainService
```

`Node.build` assembles the process, service, and network runtime the way the
daemon runs them. `ChainService` reaches the runtime only through
`NetworkInterface`, and the runtime reaches the service only through
`ChainInterface`. `ChainProcess.open` runs `BootRecovery` before anything is
exposed to networking. `NodeStore` groups its tables by owner (import journal,
block index, evidence index, candidate store, mempool journal, pruning).
`NodeNetworkRuntime` is one actor whose code is split by concern into
`+Lifecycle`, `+Overlay`, `+Hierarchy`, `+Candidates` (the `BlockFetcher`
side), `+ReadURL`, and `+RangeSync`. Each plane's state lives in its own
`OverlayState` or `HierarchyState`, per-peer state is a `PeerSet`, and one
plane reaches another's state only through named seams. Every sleep in the node
library goes through `Timers`.

`ChainProcess` is the sole block-import boundary (`importBlock`). Service and
network code may prepare data, but canonical state changes only through process
import and its staged durable batch.

Production ingress is intentionally one-way:

```text
Ivy acquisition and root attribution
  -> ChainService ingress
  -> ChainProcess validation and durable commit
  -> ChainService reconciliation and publication
```

The runtime never mutates consensus state directly. Network preflight remains
outside the service operation gate, while a commit reserves the service's small
reconciliation fence before process mutation order is released. That prevents a
new template or mempool operation from observing a canonical
commit before its service projection catches up, without allowing a slow peer
to stall mining or RPC. Miner/RPC/reconciliation reads are local-only; remote
content acquisition is explicit and root-scoped to network import or a
targeted retry.

Each network generation receives one immutable handler bundle before either
listener starts. Candidate acquisition creates an explicit root-bound content
session and passes that session through service ingress; provider identity,
cache state, and attribution never depend on ambient task-local state.

Ivy applies bounded transport admission before awaiting the runtime's inbound
delegate, so peer work is backpressured at the transport boundary. On the
private hierarchy plane, only the co-hosted parent level's key bypasses
the receiver's local Tally admission; all normal hierarchy and overlay traffic
remains reputation-gated, and the bypass grants no consensus authority.
Its optional public-address discovery runs after listener readiness and never
delays local RPC availability.

## Two network planes

The planes are deliberately separate:

1. The public overlay admits peers that claim the same Nexus genesis and
   absolute chain path. It carries block and transaction
   Volume inventories plus content-addressed retrieval.
2. The private hierarchy plane has no relay role. It is dialed on loopback
   between a co-hosted parent level and its child levels (the listener binds
   all interfaces, so firewall the hierarchy port), and carries only child
   evidence: the evidence-available hint, the evidence index, the per-block
   evidence request, and the evidence Volumes. The parent level's key is the
   one parent; the child role goes only to the process key of the child
   level the host runs for that directory, so a claimed path alone grants no
   authority. Exact-CID exchange is explicitly enabled on this plane, but
   only a connection that completed its own compatible hierarchy hello may
   use it.

Parent facts (genesis links and parent-state continuity), run reports, and
merged-mining candidates pass in-process between co-hosted levels, never over
a network plane.

Hierarchy CAS reads are bounded, exact selections rather than database access:
there is no enumeration or mutation API, the bytes are non-secret availability,
and the receiver independently checks CIDs and Lattice evidence. A replacement
connection must send a fresh hello even when it authenticates with the same
key.

A parent never waits on a child to serve a template. Each hosted child level
keeps one pre-built candidate against its parent level's validated tip's
post-state — the only thing a candidate takes from a carrier — and the
miner's recipients and minimum work for its subtree, and rebuilds it, one
build at a time, whenever an input changed: the parent's tip, its own
tip, the plan, a grandchild's candidate (a mempool change alone waits for
the next rebuild). The build
takes only the child's own lease and reads its parent level without taking
the parent's gate or lease (`ParentLevel`), and the parent's template path
reads each child's latest candidate synchronously (`ChildLevel`), so the
lock order is acyclic; a SafetyNet gate enforces both. A template takes
every candidate whose parent state is the current tip's post-state and
whose plan is the current one. A child that has not built yet, or whose
candidate is for an older tip, is simply not carried that round; nothing is
asked and nothing is awaited.

A candidate's content is retained by the chain that built it, as its own
budgeted policy (`maximumRetainedCandidateOffers`, oldest offer first), never
by a parent's reservation: the parent commits the candidate's block node it
holds, and the carried block's import at the child later owns the roots
the candidate pinned. Once the parent's evidence names a candidate carried,
its row is a handoff and no wave of newer candidates evicts it. A candidate
the parent never carried costs nothing for long; one evicted before its
block landed is a lost fork, the cache-eviction outcome the design already
takes. Every hierarchy level applies the same rule; nothing is relayed down.

A miner learns its work is stale from one template digest, served by the
template and by the status route alike: the validated tip, the mempool, and
the child candidates held, so a fresh candidate at any level refreshes the
miner's work within one status probe. A child's evidence index
resumes from a durable `(source, ordinal)` cursor against one fixed cut; a
changed parent store source restarts at zero. Validated attachments enter a
durable inbox protected from VolumeBroker pruning before the cursor advances
and leave it only after an import decides the block.

## Child genesis flow

1. Build the self-contained child genesis offline from a seed: the child
   `ChainSpec`, an optional premine recipient, and a timestamp. The genesis
   commits to the empty parent state and uses the maximum target, so the same
   seed always yields the same CID.
2. Construct and sign an ordinary parent transaction containing
   `GenesisAction(directory, genesisCID)`, then submit it to
   `POST /v1/transactions`.
3. External mining includes that transaction in a parent block like any other.
   The accepted block records `directory -> genesisCID` in the parent's
   committed genesis state.
4. The child level, co-hosted with its ancestry (`lattice.json`, `--config`),
   opens its durable store in `awaitingGenesis`. It tries to activate on each
   trigger: its start, every parent tip change, a child-overlay peer's hello,
   and one slow retry armed after an anchored genesis could not be fetched or
   confirmed. There is no polling loop.
5. Each attempt reads the CID its co-hosted parent level anchored under its
   directory. If the data directory holds the seed as `child-genesis.json`
   (re-read on every attempt), the child rebuilds the genesis and requires the
   anchored CID. Without a seed, or when the seed is unreadable or builds
   another CID, it fetches the genesis block by the anchored CID from
   child-overlay peers, requiring the content to hash back to it. A brand-new
   chain has no such peer, so its first node needs the seed.
6. The child confirms, by a local read of its co-hosted parent level, that the
   parent still anchors that CID and recorded the exact
   `(directory, genesisCID, empty parent state)` fact. Only then does it
   bootstrap the genesis and become `active`; otherwise it stays
   `awaitingGenesis` until the next trigger.

There is no opaque genesis byte channel, and no parent block carries a child
genesis.

The process that directly parents an edge retains only its sparse commitment
proof. Ordinary child validation Volumes remain child-chain data. Import stages a
newly authorized child's proof route in the same transaction as its genesis
link, because that child cannot authenticate before the authorization exists.
The parent replays durable authorized-genesis availability when the child
reconnects. An ancestor does not become an implicit archive for packages below
its direct children.

Parent and child retain the same child-evidence proof attachment, but acquire it
at different moments. The semantic direct edge is indexed in SQLite and derived
from that proof when read; it is not stored again as a second Volume. The parent
retains the edge it issued; the child retains the edge it validated and may
relay complete content-verified root Volumes to same-chain peers.
The child never returns topology or derived work to its parent. Work is derived
from the child proof and remains entirely inside the child process.

An evidence Volume is one complete, one-entry Volume whose canonical manifest
contains the child CID and proof envelope. Its Ivy request carries a local
singleton/archive allocation bound even though those limits are not added to
the wire protocol.

The permanent edge record is the reusable source for later outer-root
attachments. The bounded prepared-proof store exists only to bridge a crash
before first publication. Neither record is embedded as a backlink in a block.

Evidence discovery is only an index or live availability summary containing
`child CID + root CID + attachment Volume CID`. The receiver fetches that
complete Volume from the exact announcing session and verifies it locally.
There is no second evidence request, proof-root request, or partial evidence
response protocol; every `(child, root)` attachment is already one independent
inventory entry, including noncanonical and repeated-child roots.

## Nexus bootstrap

Nexus has no parent, so an empty Nexus store starts from a configured local
trust anchor. `ChainProcess.open` constructs the deterministic genesis,
recomputes its CID, and requires it to equal:

`bafyreick4k7a6bxz4huqx4wiu3z5yph4tnpl4zvq2pi6xv3ouribtvzs24`

Only then does it bootstrap the root locally. Signature and signer fields in
genesis transactions are non-authoritative and need no special empty shape. The
exact genesis CID supplies authorization: local configuration for Nexus and a
parent `GenesisAction` commitment for a child. Ordinary post-genesis
transactions remain signature-strict. On recovery, store
metadata and the height-zero fact must name that same CID; no alternate Nexus
genesis is accepted.

## External mining pipeline

```text
lattice-mining-coordinator
  │ POST /v1/mining/templates
  ▼
lattice-node (Nexus)
  │ complete nonce-zero candidate + effective search target
  ▼
lattice-miner workers
  │ nonce results
  ▼
lattice-mining-coordinator
  │ POST /v1/mining/work
  ▼
lattice-node import → durability → overlay and child-proof publication
```

The node owns chain truth and template validity. The coordinator owns work
lifecycle and range allocation. Workers own only proof-of-work search over an
immutable assignment.

Templates have no deployment mode. A transaction carrying a `GenesisAction` is
selected like any other pooled transaction. Child geneses are self-contained,
so a template never carries one; merged-mining templates attach only ongoing
direct-child candidates supplied by their processes. The effective search
target is the easiest target among the Nexus candidate and those child
candidates.

## Durability and recovery

Each process directory contains:

```text
<storage>/
  process.key   # default process identity, mode 0600
  state.db      # staged protocol facts, immutable indexes, recovery metadata
  volumes.db    # materialized content volumes
```

Import publishes each complete Volume, merge-retains its root, and only then
commits the protocol fact that references it. A failed fact commit may leave a
safe retained orphan. Import and issued hierarchy roots therefore grow
merge-only while live. Prepared hierarchy evidence is different: it is a
bounded cache, so one serialized store gate performs its Volume writes, SQLite
capacity eviction, and exact retained-set advance as a single ordered
operation. Under the exclusive startup lock, the node materializes protocol
constants, derives the exact roots for import, issued hierarchy, and
prepared hierarchy scopes, verifies every referenced Volume, populates the
hierarchy scopes before removing legacy ownership, audits semantic indexes,
and reconstructs the chain by replaying staged import batches. Networking
starts afterward. Nexus also verifies the exact genesis CID.

The on-disk names predate the import vocabulary and are kept deliberately: the
import journal is still stored in the `admission_batches` and `admission_facts`
tables, and a block's `BlockStatus` (`header`, `executed`, `executedAndPinned`)
is stored in the `accepted_blocks.validated` column with its original integer
values.

Legacy databases and volume layouts are not migrated in place. Operators must
remove the entire configured storage directory and resync; keeping only one of
`state.db` or `volumes.db` breaks their durability invariant.

## Testing networks

Deploy a child chain with test-oriented parameters when an application needs a
public or long-lived testing network. Nexus retains its one pinned genesis.
This preserves the same addressing, parent facts,
merged mining, and consensus rules used by every other child.
