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
  ├─ ChainService          transactions, intents, templates, work results
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
new template, mempool operation, or child intent from observing a canonical
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
   candidate requests, parent-issued proofs, genesis links, and exact
   parent-state continuity answers. A configured parent key gates parent facts;
   a claimed path alone grants no authority. Exact-CID exchange is explicitly
   enabled on this plane, but only a connection that completed its own
   compatible hierarchy hello may use it.

Hierarchy CAS reads are bounded, exact selections rather than database access:
there is no enumeration or mutation API, the bytes are non-secret availability,
and the receiver independently checks CIDs and Lattice evidence. A replacement
connection must send a fresh hello even when it authenticates with the same
key.

While a parent requests contextual child candidates, it leases the nonce-zero
provisional carrier as an ephemeral CAS root. Only a request rooted at that
exact CID can receive it; durable descendants in the same selection still come
from the process store. The lease is reference-counted across overlapping
requests, fenced by runtime generation, and discarded after the bounded round.
The provisional carrier is never written to durable consensus content.

A parent may request candidates only from authenticated direct children. Slow
or absent children are omitted within a bounded deadline, so one child cannot
stall Nexus template creation.

Before replying, a child stores the candidate's complete block and transaction
Volumes as a bounded speculative offer. The parent does not expose miner work
until it sends that exact child an authenticated snapshot of every candidate
referenced by its live template book and receives a durable acknowledgement.
The child recursively reserves its own descendants, atomically replaces its
issued set, and then releases every unselected offer. Additions require the
durable acknowledgement; removals run in order without making parent progress
wait on a child. When a parent commits a candidate, its next authenticated
reservation update atomically moves that CID into durable admission-handoff
ownership before releasing the speculative reservation. The same update
recursively hands off committed descendants. Parent-proof delivery and recovery
remain independent, so neither a delayed announcement nor garbage collection
can lose committed content. Offer churn can evict only offers; it cannot evict
issued or handoff candidates. Lost acknowledgements can therefore over-retain,
never under-retain, and the next exact snapshot reconciles the set.
Every hierarchy level applies the same rule. A reconnecting child is omitted
from candidate selection until the final page of its durable evidence index is
ordered into that session. The index resumes from a durable
`(source, ordinal)` cursor against one fixed cut; a changed parent store source
restarts at zero. Validated attachments enter a durable,
VolumeBroker-retained inbox before the cursor advances and leave it only after
admission owns the same Volume. Evidence published while the index is in flight is
queued after its final page and before the child's exact reservation replay, so
neither a page race nor a slow child can stall or under-retain issued evidence.
Child timestamps derive from the immutable parent carrier, so an unchanged
request is CID-stable and refreshes one offer instead of consuming another.

## Child genesis flow

1. Start the child process with its absolute path and parent fact endpoint. It
   opens its durable store in `awaitingGenesis`.
2. Call the parent's `POST /v1/children/intents`. The parent builds and stores a
   child genesis bound to its current state and returns the block and CID.
3. Construct and sign an ordinary parent transaction containing the matching
   `GenesisAction`, then submit it to `POST /v1/transactions`.
4. External mining commits that transaction and child block in a parent
   carrier.
5. The parent durably prepares and publishes the direct-child proof. It also
   acknowledges the exact deployment fact from its accepted graph. The child
   verifies the proof, requires its `parentState` to equal the deployment
   block's entering state, and becomes `active`.

There is no opaque genesis byte channel. The parent retains the complete Cashew
Volumes it created for genesis, while any exact same-chain advertiser may
supply the same CID-verified Volumes. The authenticated immediate-parent process
alone acknowledges the exact accepted deployment tuple and later forward
parent-state movements from its recovered validated graph. These positive
acknowledgements are unsigned, session-bound, and non-portable.

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
contains the child CID and proof envelope. Parent-created genesis retention
stores complete Volume root IDs in NodeStore as local metadata; those IDs do
not affect evidence identity or wire size. Its Ivy request carries a local
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

Normal work never includes a `GenesisAction`. Deployment work explicitly
selects one transaction whose complete anchor set has matching locally retained
child intents, or one deployment subtree supplied by a direct child. Its
effective search target preserves the hardest deployment barrier recursively.
Because every intent binds the carrier's entering parent state, sibling chains
that must launch together are anchored atomically by one transaction.

A child intent carries the exact complete WASM module Volumes named by its
spec. Validation composes those request-owned bytes over local VolumeBroker
content; there is no ambient module-upload CAS. After validation, one exact
`child-intents` retention scope covers every Volume in each live intent closure.
Replacement, anchoring, and parent-state staleness update that set atomically
with respect to process eviction, while restart clears it because intents are
operational state rather than recovery authority.

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
