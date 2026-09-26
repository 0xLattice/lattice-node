# Architecture

## Process boundary

One `lattice-node` process owns exactly one absolute chain path. `Nexus` is the
only root; every other process is configured with a complete Nexus-inclusive
path and one immediate parent endpoint.

```text
Nexus process
  chain: Nexus
  overlay: 4001
  hierarchy facts: 4002
  RPC: 127.0.0.1:8080

Payments process
  chain: Nexus/Payments
  parent: <nexus-key>@<nexus-host>:4002
  overlay: 4101
  hierarchy facts: 4102
  RPC: 127.0.0.1:8180
```

A parent never owns its child's chain state, mempool, persistence, sync, or fork
choice. External orchestration starts and stops independent chain processes.

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

The Nexus process has no parent. Every child must configure `--parent` with the
authenticated immediate parent's fact-plane public key and endpoint.

## Runtime components

```text
LatticeNodeDaemon
  ├─ NodeConfiguration     immutable path, keys, ports
  ├─ ChainProcess          consensus admission and durable recovery
  ├─ ChainService          transactions, templates, work results
  ├─ NodeStore             state.db: semantic facts, indexes, root references
  ├─ DiskBroker            volumes.db: materialized CAS volumes
  ├─ Ivy overlay           same-chain peers and content
  ├─ Ivy hierarchy plane   authenticated direct parent/child facts
  └─ loopback HTTP         thin JSON adapter over ChainService
```

`ChainProcess` is the sole consensus-admission boundary. Service and network
code may prepare data, but canonical state changes only through process
admission and its staged durable batch.

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
content acquisition is explicit and root-scoped to network admission or a
targeted retry.

Each network generation receives one immutable handler bundle before either
listener starts. Candidate acquisition creates an explicit root-bound content
session and passes that session through service ingress; provider identity,
cache state, and attribution never depend on ambient task-local state.

Ivy applies bounded transport admission before awaiting the runtime's inbound
delegate, so peer work is backpressured at the transport boundary. On the
private hierarchy plane, only the exact configured immediate parent bypasses
the receiver's local Tally admission; all normal hierarchy and overlay traffic
remains reputation-gated, and the bypass grants no consensus authority.
Its optional public-address discovery runs after listener readiness and never
delays local RPC availability.

## Two network planes

The planes are deliberately separate:

1. The public overlay admits peers that claim the same Nexus genesis and
   absolute chain path. It carries block and transaction
   Volume inventories plus content-addressed retrieval.
2. The private hierarchy plane has no relay role. It carries direct-child
   candidate pushes, parent-issued proofs, genesis links, and exact
   parent-state continuity answers. A configured parent key gates parent facts;
   a claimed path alone grants no authority. Exact-CID exchange is explicitly
   enabled on this plane, but only a connection that completed its own
   compatible hierarchy hello may use it.

Hierarchy CAS reads are bounded, exact selections rather than database access:
there is no enumeration or mutation API, the bytes are non-secret availability,
and the receiver independently checks CIDs and Lattice evidence. A replacement
connection must send a fresh hello even when it authenticates with the same
key.

A parent never requests a child candidate and never waits on a child to
serve a template. The parent pushes its template context to each
authenticated direct child whenever it changes: its validated tip block and
the miner's reward plan and minimum work for the child's subtree (`parent
tip available`). The child builds its candidate against the tip's post-state
— the only thing a candidate takes from a carrier — reading the tip's content
from the parent's own session, and pushes the candidate up whenever any of
its inputs changed: that context, its own validated tip, its mempool, a
grandchild's push (`child candidate available`). Pushes carry a per-session
sequence; a lower one is a reordered stale push and is dropped. The parent
keeps only the latest candidate per child peer, and a template takes every
held candidate whose parent state is the current tip's post-state. A child
that has not pushed yet, or whose candidate is for an older tip, is simply
not carried that round; nothing is asked and nothing is awaited.

A candidate's content is retained by the chain that built it, as its own
budgeted policy (`maximumRetainedCandidateOffers`, oldest offer first), never
by a parent's reservation: the parent commits the candidate's block node it
holds, and the carried block's admission at the child later owns the roots
the offer pinned. Once the parent's evidence names a candidate carried, its
row is a handoff and no wave of newer offers evicts it. An offer the parent
never carried costs nothing for long; an offer evicted before its block
landed is a lost fork, the cache-eviction outcome the design already takes.
Every hierarchy level applies the same rule; nothing is relayed down.

A miner learns its work is stale from one template digest, served by the
template and by the status route alike: the validated tip, the mempool, and
the child candidates held, so a fresh candidate at any level refreshes the
miner's work within one status probe. A reconnecting child is omitted from
templates until the final page of its durable evidence index is ordered into
that session, and is pushed the current context as soon as it is. The index
resumes from a durable `(source, ordinal)` cursor against one fixed cut; a
changed parent store source restarts at zero. Validated attachments enter a
durable, VolumeBroker-retained inbox before the cursor advances and leave it
only after an admission decides the block.

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
4. The child process, started with its absolute path and parent fact endpoint,
   opens its durable store in `awaitingGenesis` and runs two genesis paths
   concurrently. If its data directory holds the seed as `child-genesis.json`
   at startup (the file is read only then), it rebuilds the genesis locally.
   Independently, it asks the parent for the CID recorded under its directory
   and fetches the genesis block by that CID from child-overlay peers,
   requiring the content to hash back to it. A brand-new chain has no such
   peer, so its first node needs the seed in place before it starts.
5. The child asks its authenticated immediate parent to acknowledge the exact
   `(directory, genesisCID, empty parent state)` fact. Only a positive answer
   lets it bootstrap the genesis and become `active`; otherwise it stays
   `awaitingGenesis` and retries.

There is no opaque genesis byte channel, and no parent block carries a child
genesis. The authenticated immediate-parent process alone acknowledges the
recorded genesis and later forward parent-state movements from its recovered
validated graph. These positive acknowledgements are unsigned, session-bound,
and non-portable.

The process that directly parents an edge retains only its sparse commitment
proof. Ordinary child validation Volumes remain child-chain data. Admission stages a
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

`bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`

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
lattice-node admission → durability → overlay and child-proof publication
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

Admission publishes each complete Volume, merge-retains its root, and only then
commits the protocol fact that references it. A failed fact commit may leave a
safe retained orphan. Admission and issued hierarchy roots therefore grow
merge-only while live. Prepared hierarchy evidence is different: it is a
bounded cache, so one serialized store gate performs its Volume writes, SQLite
capacity eviction, and exact retained-set advance as a single ordered
operation. Under the exclusive startup lock, the node materializes protocol
constants, derives the exact roots for admission, issued hierarchy, and
prepared hierarchy scopes, verifies every referenced Volume, populates the
hierarchy scopes before removing legacy ownership, audits semantic indexes,
and reconstructs the chain by replaying staged admission batches. Networking
starts afterward. Nexus also verifies the exact genesis CID.

Legacy databases and volume layouts are not migrated in place. Operators must
remove the entire configured storage directory and resync; keeping only one of
`state.db` or `volumes.db` breaks their durability invariant.

## Testing networks

Deploy a child chain with test-oriented parameters when an application needs a
public or long-lived testing network. Nexus retains its one pinned genesis.
This preserves the same addressing, parent facts,
merged mining, and consensus rules used by every other child.
