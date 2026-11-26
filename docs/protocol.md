# Lattice node peer protocol

How two `lattice-node` processes talk to each other: the session hello, the
messages that sync headers and proofs, how content is exchanged, how the
hosts of a chain find each other, and what a peer can be blamed for.

This page does not define consensus. Validation, state transitions, work
accounting and fork choice are defined by the
[Lattice specification](https://github.com/0xLattice/Lattice/blob/59.3.0/docs/spec.md).
Related references:

| For | Read |
|---|---|
| HTTP routes, request and response bodies | [HTTP API](rpc-api.md) |
| What the pool admits, replaces and evicts | [Transaction pool policy](mempool.md) |
| The contract between node, coordinator and mining workers | [Mining role boundaries](design/mining-role-boundaries.md), [External mining workers](mining-workers.md) |
| How the node is built | [Node architecture](architecture.md) |
| How a child block's work and parent state are checked | [Proof-derived child work](design/proof-derived-work.md) |
| Operating the network side of a node | [Networking](networking.md) |

## One overlay for the whole tree

A process hosts one Nexus-rooted tree of chains and has one Ivy network
plane. A peer session serves every chain both ends host. The overlay
carries three kinds of traffic: transaction announcements, sync messages
scoped to one chain, and content.

Every chain is named by its absolute path, which always begins with `Nexus`
([Chain addressing](design/chain-addressing.md)):

```text
Nexus
Nexus/Payments
Nexus/Payments/Receipts
```

Sync messages carry the path of the chain they concern.

Parent facts, run reports and merged-mining candidates never cross a network
plane. They pass in-process between the levels one node hosts
([Process trust model](design/process-trust-model.md)). No network peer
holds a parent or child role, and no peer can provide a parent-state
verdict.

## The Nexus genesis

The pinned Nexus genesis CID is:

```text
bafyreiggtg4ezifboyekbf4gxst2jr3mpjqcxsbmopy7w6fp46g4ngpgxa
```

It contains the deterministic premine transaction for public key
`ed01fe416588df6e7fa5213c0d3e430f504bb5203172120c86b874826b55f53bdb7d`.

- On an empty store the node constructs the genesis locally, recomputes its
  CID, and uses it only for configured root bootstrap. It is never accepted
  from a peer.
- The CID is a trust anchor, never a peer-admission signature permit. Nexus
  is admitted only at the configured CID.
- Every transaction in any genesis has empty signers and signatures.
  Ordinary post-genesis transactions remain signature-strict.
- A child root is built from its configured spec and the parent's entering
  state, then admitted only with a valid mined directory proof.

The CID is also committed to Bitcoin; see
[Bitcoin-anchored genesis](design/bitcoin-anchored-genesis.md) to verify it.

## Sessions

### Hello

Ivy authenticates the peer's key. Each connection must then complete a
compatible hello before it may request anything, including a connection
that replaces an earlier one from the same key. The hello grants no
authority over facts.

| Field | Meaning |
|---|---|
| `version` | The node protocol version. The overlay requires version 6; a peer on another version is refused the session. |
| `nexusGenesisCID` | The Nexus genesis the sender runs. It must equal the receiver's. |
| `chainPath` | The root path of the sender's tree. It must equal the receiver's. |
| `capabilities` | Optional. What the sender speaks beyond version 6: a sorted list of strings, absent when empty. |

The hello is decoded leniently, so a node that predates `capabilities`, or
any later field, accepts a hello that carries it.

### Capabilities

| Capability | The peer |
|---|---|
| `volume-bundle` | answers a Volume bundle request ([Bundles](#bundles)). |
| `relay` | carries a session between two peers it has sessions with. |
| `host:<path>` | hosts that child chain. Nexus is not named: every node hosts it. |
| `hello-updates` | sends its hello again when what it hosts changes, and takes a later hello on an open session as what that peer now speaks and hosts. |
| `stream-tail` | answers a stream request whose `after` is the largest 64-bit value with its log's last entry and subscribes the asker, so a peer that wants only what is new need not page the history. |

A node sends a later hello only to a peer that named `hello-updates`, and
takes one only from a peer whose hello named it.

### Adding to the wire without a flag day

The version changes, and old and new nodes part, only for a change that
makes them disagree about what is valid. Everything else is an addition,
and old and new nodes keep one network:

1. An addition is a new message type (a new overlay topic, a new Ivy message
   tag) or a new optional field of the hello. An existing message never
   changes its meaning or its encoding. Overlay messages are canonical-exact
   (`CanonicalJSONMessage`: a decoded message must re-encode to the bytes
   received), so adding a field to an existing message is not compatible:
   it is a new message on a new topic, as `read-endpoint.response.v2` stands
   beside `read-endpoint.response`.
2. The hello's optional `capabilities` names what a node speaks beyond
   version 6.
3. A node sends a new message type only to a peer whose hello advertised
   it. A peer that advertised nothing is spoken to exactly as before.
4. What a node does not know it ignores: an unknown capability, an overlay
   message of an unknown topic, an Ivy message of an unknown tag. None of
   them ends the session or counts against the peer.

Ivy releases through 14.0.0 end the session of a peer that sends an unknown
Ivy tag; later ones ignore it. That is why rule 3 is not optional.

## Finding the hosts of a chain

A node joins any chain by first being a node of its parent, then asking the
DHT which of the parent's nodes host the child, as a provider announce and
lookup work in IPFS. One process hosts a chain's whole ancestry on one
overlay, so every host of a child is already in its parent's network and
they share one DHT. The same rule applies at every depth.

| What | How |
|---|---|
| Rendezvous key | `lattice.chain-peers.v1:<nexus genesis>:<path>`, one per hosted child chain, carrying the full path. |
| Announce | The node periodically announces each hosted child under its key, and names each in its hello as `host:<path>`. Nexus has neither. |
| Lookup | A joiner looks the key up and dials the hosts it finds. A lookup answers with a sample of the key's providers; announcing more often does not buy a place in it. |
| Not announced | The node publishes no provider record per block or per state. |

A child's **current peers** are the sessions whose hello named it or that
its providers include. The node dials a bounded random set of that chain's
providers:

- while a hosted child has no current peer;
- when the child's verified progress stalls;
- once an interval while it has fewer current peers than the target.

A Nexus stall retries disconnected bootstrap peers.

Current peers are what a child chain is routed by:

- its transaction announcements go only to them (Nexus's go to every
  session);
- a block's body is asked of them alone (its bundle of the capable ones,
  then each Volume), then of the connected peers known to provide the block
  or that Volume, never of anyone else.

Provider records advertise availability. They grant neither consensus
authority nor a parent or child network role.

## Header and proof sync

Each chain level keeps a weigh log: the headers it weighed and the child
proofs it credited, by position. Peers read each other's logs and fetch the
entries they lack. All five messages are canonical JSON on their own overlay
topic and carry the chain's path.

| Message | Topic | Carries |
|---|---|---|
| `getStream` | `lattice.overlay.stream.request.v1` | A request for the receiver's log after a position, in the log the sender last read (`logID`); from position 0 when that log changed. It also names the sender's own log, so the receiver reads it again when it changed. |
| `stream` | `lattice.overlay.stream.page.v1` | A page of the sender's log, or a push of what it appended (`requestID` 0). Pages carry IDs only: each entry is a position, whether it is a header or a proof, its CID and its block. At most 4,096 entries. |
| `getData` | `lattice.overlay.data.request.v1` | A request for weighed headers by CID, with their proofs. At most 4,096 CIDs. |
| `getAncestors` | `lattice.overlay.ancestors.request.v1` | A request for a header (the unknown parent of a header the sender sent) and up to 2,048 of its ancestors, child to parent. |
| `headers` | `lattice.overlay.headers.response.v1` | The answer to `getData` or `getAncestors`, or an unsolicited header (`requestID` 0). At most 4,096 entries; `hasMore` when the answer was cut by bytes. |

A header entry contains:

- the canonical block bytes;
- an optional child index;
- the `ChildBlockProof` values the sender credited for that block;
- a genesis spec when needed.

The receiver verifies every header and proof before adding it to its own
log. When serving a child header, the node attaches the proofs it has
already verified. A receiver missing a streamed proof requests the
corresponding header entry from the peer that advertised it.

A block carried by a grind learned from a peer follows the same acquisition
and proof path as any other on the shared overlay.

### Local size limits

| Limit | Default | Applies to |
|---|---|---|
| `maxChildIndexBytes` | 1 MiB | a header's child index |
| `maxProofBytes` | 64 KiB | one child proof |

An entry over a limit is unavailable on that node, like content it cannot
fetch: never judged, never blamed. These are local resource limits, not
consensus rules.

### Cursors and the proof index

Durable sync cursors are written in the same tree-wide transaction as the
facts they pass.

Verified child proofs are indexed locally by chain path, child CID and grind
root in `state.db`. The index is recovery and serving evidence, not a second
network or consensus authority. A restart refuses unreadable or misindexed
proof rows.

## Content exchange

Peer content exchange is Volume-native. A Volume is one complete
content-addressed unit named by its root CID.

- An announcer names one complete Volume by its root CID and must serve
  that Volume from the exact authenticated session that made the claim.
- Node protocol messages never request arbitrary CID selections. Entry
  CIDs, bounded framing and atomic publication are transport and storage
  details.
- Content bytes are non-secret availability and grant no validity: the
  consumer verifies every CID and the exact Lattice evidence it reads.

### What a block carries

A block's bundle is the content the protocol says a block carries
(`Block.carriedContentPaths`, which the node's `storeBlockContent` stores):

- the block's own Volume;
- its transactions';
- its spec and policy modules.

It never includes the state the block reads or writes, its parent, or its
child blocks, with one exception: a child block's parent-receipt witness
(`Block.parentReceiptWitnessPaths`, stored by `storeParentReceiptWitness`),
the parent state's nodes on the path to each of its withdrawals' receipts.
That state is another chain's, which the node does not derive by executing
the block's parent, so the witness travels with the body, as the protocol's
validation witness data (spec §3.5).

A node derives a block's pre-state by executing its parent, as Bitcoin's
initial block download and geth's full sync do. Its execution reads that
state from this node's store first, then what is in memory, and asks peers
only for what neither holds (a state it let go of, as a reorganization past
its kept windows needs).

### Bundles

A bundle sends a block's Volumes with one request.

- **Recording.** Storing a block records its Volume roots in
  `volume-bundles.db`, a cache beside the stores that nothing else reads and
  whose failure costs only speed. For a block with no record the server
  walks the same paths over its local content and records what it finds. A
  root with nothing recorded bundles only itself.
- **Asking.** A content session asks, on its first miss, for the bundle of
  its root from the connected peers that advertised `volume-bundle`.
- **Accounting.** A bundled Volume is verified, charged to the session and
  credited to its server only when the session's traversal asks for its
  root, exactly as a requested Volume is.
- **Fallback.** Whatever a bundle lacks, and everything when no connected
  peer advertised bundles, is requested one Volume at a time.

A bundle is an optimisation and never the only way to a block:

- It is asked for on a block's first attempt only, so a retry is the
  per-Volume traversal.
- A session keeps `volume-bundle` only while every bundle it is asked for
  ends, whole or "no bundle". One whose answer times out, breaks the
  stream, carries a Volume that does not verify, or is cut off is from then
  on fetched from one Volume at a time, until it reconnects and says hello
  again.

### Local ceilings

Each candidate-root content session uses the node's `NodeResourcePolicy` for
the bytes it may hold, and nothing else. `ChainSpec.maxBlockSize` remains
chain-selected validity for that chain's complete block Volume boundary
(excluding the spec and materialized state Volumes). Exceeding a local
ceiling declines or defers acquisition without proving the candidate invalid
or punishing its advertiser.

## Transaction announcements

Transactions are same-chain Volumes.

1. A peer advertises a transaction Volume root
   (`lattice.overlay.transaction.available.v1`).
2. The receiver pulls it from that exact session, resolves the transaction,
   and re-materializes the canonical typed Volume locally. Unrelated
   peer-supplied members are never retained or relayed.
3. Lattice validates the transaction against the current state.
4. The node relays only a newly admitted root.

Peer transactions are serveable while pooled. What the pool then admits and
keeps is in [Transaction pool policy](mempool.md).

## What costs a peer

| Event | Consequence |
|---|---|
| A Volume, bundled or requested, that does not verify (another root, or an entry that does not match its CID) | Tally records a protocol violation against the peer that sent it, which lowers its standing. The Volume is then requested again. |
| A Volume nobody sent (none found, this node's own capacity or byte budget, its cancellation) | Blames no one. |
| A child index or proof over a local size limit | Unavailable on this node; blames no one. |
| A candidate over a local ceiling | Acquisition is declined or deferred; its advertiser is not punished. |
| An unknown capability, overlay topic or Ivy tag | Ignored. |

The rules for headers and proofs (only a proof-of-work failure blames) are
invariants NODE-SEMANTICS-003 and NODE-SEMANTICS-005 in
[Correctness invariants](correctness-invariants.md).
