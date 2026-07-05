# Lattice Node — Protocol Reference

> The node's protocol reference: wire format, message types, RPC, sync, mining,
> and economics. The **consensus protocol** is specified canonically in the
> Lattice library (`spec.md §9`); this document references it rather than
> redefining it. For node implementation internals see [architecture.md](architecture.md);
> for the HTTP API see [rpc-api.md](rpc-api.md); for the high-level rationale see
> [whitepaper.md](whitepaper.md). Doc map: [index.md](index.md).

## Abstract

Lattice is a protocol where a chain is both a *root chain* — its own blocks, state, and operations — and a *tree of chains* rooted at it, secured by one shared proof-of-work (merged mining). The single root chain is the **Nexus**; every other chain is a descendant, addressed by route, e.g. `Nexus/Payments`. State is stored path-based (PBSS) in SQLite for O(1) lookups, with content-addressed storage (CAS) for block/transaction data and peer-to-peer distribution. In the production topology each chain runs as a separate process that subscribes to its parent for blocks (§5.6).

---

## 1. Data Structures

### 1.1 Block

| Field | Type | Description |
|-------|------|-------------|
| version | UInt16 | Block format version |
| parent | CID? | Reference to parent block (nil for genesis) |
| transactions | CID → Transaction | Merkle dictionary of transactions |
| target | UInt256 | PoW target for this block (larger = easier to satisfy) |
| nextTarget | UInt256 | Computed target for the next block |
| spec | CID | Chain specification reference |
| parentState | CID | Parent chain's state root this block anchors to (for child chains) |
| prevState | CID | State root BEFORE this block's transactions |
| postState | CID | State root AFTER this block's transactions |
| children | CID → Block | Merged-mined child chain blocks, keyed by parent-relative directory edge |
| height | UInt64 | Block height (0 = genesis) |
| timestamp | Int64 | Milliseconds since Unix epoch |
| nonce | UInt64 | Proof-of-work nonce |

### 1.2 Transaction

| Field | Type | Description |
|-------|------|-------------|
| signatures | [PublicKeyHex: SignatureHex] | Ed25519 signatures over the `lattice-tx-v1` envelope preimage |
| body | CID → TransactionBody | Reference to transaction body |

### 1.3 TransactionBody

| Field | Type | Description |
|-------|------|-------------|
| accountActions | [AccountAction] | Signed per-account balance deltas (credits and debits) |
| actions | [Action] | General key-value state changes |
| depositActions | [DepositAction] | Lock funds for a cross-chain transfer |
| withdrawalActions | [WithdrawalAction] | Claim locked funds on a child chain |
| receiptActions | [ReceiptAction] | Authorize a withdrawal on the parent chain |
| genesisActions | [GenesisAction] | Create a child chain |
| signers | [Address] | Required signers |
| fee | UInt64 | Transaction fee |
| nonce | UInt64 | Sequential nonce per signer account (see §3) |
| chainPath | [String] | Absolute route from the external Nexus root to the target chain (replay protection) |

### 1.4 AccountAction

A balance change is expressed as a signed **delta**, not as an old/new balance pair: the action carries only the amount to add or subtract, and the resulting balance is computed against current state at block application.

| Field | Type | Description |
|-------|------|-------------|
| owner | Address | Account address (CID of public key) |
| delta | Int64 | Signed balance change: positive credits the account, negative debits it. A debit (`delta < 0`) must be authorized by the owner's signature. Must be non-zero (and not `Int64.min`). |

### 1.5 ChainSpec

| Field | Type | Description |
|-------|------|-------------|
| directory | String | Edge label selected by the parent chain (e.g., a child named "Payments"; "Nexus" for the root entrypoint) |
| maxNumberOfTransactionsPerBlock | UInt64 | Block capacity |
| maxStateGrowth | Int | Max state bytes per block |
| maxBlockSize | Int | Max serialized block bytes |
| premine | UInt64 | Premine block count |
| targetBlockTime | UInt64 | Target milliseconds between blocks |
| initialReward | UInt64 | Mining reward at genesis |
| halvingInterval | UInt64 | Blocks between reward halvings |
| retargetWindow | UInt64 | Blocks for target recalculation |

---

## 2. Consensus

### 2.1 Proof of Work

The PoW hash is computed as:
```
prefix = parentCID 0x00 transactionsCID 0x00 target.hex 0x00 nextTarget.hex
       0x00 specCID 0x00 parentStateCID 0x00 prevStateCID 0x00 postStateCID
       0x00 childrenCID 0x00 height 0x00 timestamp 0x00 nonce
hash = UInt256.hash(prefix)   // SHA-256; every field joined by a 0x00 separator
```

A block is valid when `target >= hash` (equivalently `proofOfWorkHash(B) ≤ B.target`).

### 2.2 Chain Selection

The canonical tip is the one of greatest **`trueCumWork`** — a block's forward descendant-subtree work (`subtreeWeight`) plus verified merged-mining proof contributions (`inherited`), not a naive single-path sum and not the current canonical work of a parent tip. Per-block work is `UInt256.max / target`. On a fork the node switches only to a **strictly heavier** `trueCumWork` tip; an exact tie holds the incumbent. Additional parent carriers can increase a child block's inherited weight only when they are verified as proof facts committing that child block. A parent-chain extension or reorg that does not provide a new verified child-commitment proof does not rewrite child fork choice. There is no explicit finality. The model is defined in the Lattice library `spec.md §9`; the node-side wiring is in [design/consensus-fork-choice.md](design/consensus-fork-choice.md).

### 2.3 Target Adjustment (Retargeting)

The target adjusts every block from a time-weighted average of solve times over the `retargetWindow` (default: 120 blocks for Nexus; `targetBlockTime` is 1 h). If blocks are faster than `targetBlockTime` the target decreases (harder); if slower it increases (easier). Each step is clamped to at most **2× in either direction** (`maxTargetChange`) so a timestamp grind cannot swing difficulty by an unbounded factor in one block. There is no separate time-based easing of the *current* block's target — a block is mined at its parent's scheduled `nextTarget`.

**Stall recovery.** If hashrate drops sharply (e.g. miners diverted elsewhere), blocks stop and the difficulty stays pinned where it was. The chain climbs back out on its own: each slow block, being far over `targetBlockTime`, halves the difficulty for the next, so it converges to the live hashrate in roughly `log₂(difficulty / sustainable difficulty)` blocks (the first block is the hardest; adding hashrate shortens it). No reset or intervention is needed — just continued mining.

### 2.4 Block Reward

```
reward(height) = initialReward >> (height / halvingInterval)
```

The coinbase transaction has fee=0. It credits the chain's configured payout address with `reward + sum(fees)` and is signed by a node-local coinbase authority. The coinbase nonce follows that authority signer account's normal transaction nonce; it does not consume the payout account's nonce.

### 2.5 Merged Mining

A block may contain child chain blocks in its `children` field (a merkle dictionary keyed by parent-relative directory edge). Child blocks inherit proof-of-work through the content-addressed proof that a parent block committed them — no additional mining is required. Each child chain has its own ChainSpec, state, and target, and is validated against its *own* target: a single PoW hash that misses the parent's target may still satisfy a child's higher (easier) one. Validation always recurses into `children`, so a grandchild can be accepted even when the intermediate block is not. Child blocks anchor to parent state roots through `parentState` and state-root continuity proofs; they do not depend on the parent block remaining canonical.

**Child-only carriers and the direct-child case.** A *carrier* is any block whose `children` commit a child block; it need not be canonical, and it need not clear its own target. When the carrier **is** the PoW root (the direct-child case — the proof path from carrier to child has length 1) and its hash cleared the child's easy target but *not* Nexus's hard target, it is a **child-only carrier**: never a canonical Nexus block, but a valid securing carrier for the child. A follower validates it exactly as it validates any carrier — `childTarget >= carrierHash`, a path-bound `ChildBlockProof`, and parent-state anchoring — resolved from the proof's **own sealed entries**, never by requiring standalone root PoW. Per-level crediting is what makes this safe: a child-only carrier's hash fails `validateProofOfWork` at the root target, so it contributes **zero** inherited root work and cannot inflate fork choice; it only lets the child advance. Gating a direct child's carrier on standalone root PoW (instead of the child-proof predicate) permanently wedges a pure parent-stream follower — the class of bug this rule exists to prevent.

### 2.6 Child Chain Creation & Discovery

A child chain is *created* by a **`GenesisAction`** that records `{directory, blockCID}` into the parent's `genesisState` — a MerkleDictionary mapping a parent-relative directory edge to the child's genesis block CID. The parent stores only that opaque anchor; it never fetches or validates the child genesis content (verify-not-trust — recording an unverified anchor is correct, judging it is the attack surface). A node **discovers** a child as soon as it accepts a parent block whose post-state commits that `GenesisAction`; no restart or DHT lookup is needed.

The `GenesisAction` travels in an **ordinary signed transaction** (`genesisActions`, built via [`/api/transaction/prepare`](rpc-api.md#post-apitransactionprepare)). Because it is a normal mempool transaction it gossips to every node and **any** miner can include it in the next block — the announcement is not tied to the deploying node winning a block, and survives that node going offline. Anyone with a funded account may announce any directory; first writer on the canonical chain wins the name (the parent does not arbitrate which CIDs are "valuable").

This is distinct from the per-block **anchoring** of §2.5: `genesisState` records that a child *exists* (creation/discovery), while a parent block's `children` field commits each individual child *block* (merged-mining proof). Deploying a child locally (`POST /api/chain/deploy`) only seeds its genesis and process; it is announced — and thus discoverable — only once a `GenesisAction` for it lands in the parent chain.

In the per-process topology, a child process does not mine its own blocks: it subscribes to its parent's P2P gossip, extracts its embedded block from each parent block's `children` via a sparse content-addressed proof (`ChildBlockProof`), and validates it against the parent's PoW root hash. See §5.6.

This parent-secures-children relationship is Lattice's core organizing protocol: it is self-similar at every parent→child edge, even though each chain defines its own operations. See [Fractal structure](design/fractal-structure.md).

The source that serves the parent bytes is not trusted. It only provides
availability. The child verifies CIDs, PoW, child-inclusion proofs, and any
state-root proofs before the data can affect child state or inherited work. This
is why parent processes do not need child fork-choice views: they publish and
serve proof-carrying blocks, while each child independently decides what those
proofs mean for its own chain.

---

## 3. Transaction Validation

A transaction is valid if ALL of the following hold:

1. **Signatures**: Every address in `signers` has a valid Ed25519 signature over `TransactionSigning.preimage(bodyCID, chainPath, nonce)`, domain-tagged as `lattice-tx-v1`
2. **Fee bounds**: `MINIMUM_TRANSACTION_FEE (1) <= fee <= MAX_TRANSACTION_FEE (1,000,000,000,000)`
3. **Nonce**: Nonces are sequential per signer account, starting at 0 with no gaps. Consensus tracks the last confirmed nonce per signer in the account state trie; the mempool admits a bounded window of future nonces (up to 64 ahead) for concurrent submission.
4. **Chain path**: `chainPath` is non-empty and equals the validating chain's full path from the Nexus root (cross-chain replay protection; covered by the signed envelope)
5. **Account deltas**: Every `AccountAction` has a non-zero `delta`; each debit (`delta < 0`) names an `owner` in `signers`, and each owner's current on-chain balance covers their net debit
6. **Conservation**: transaction debits cover credits plus fees, and block credits are bounded by debits plus the coinbase reward and cross-chain withdrawal/deposit effects (no value created or destroyed)
7. **Cross-chain actions**: deposit/withdrawal/receipt senders (`demander`/`withdrawer`) must be in `signers`; a withdrawal must prove a matching deposit and receipt exist on the parent chain

### 3.1 Mempool Admission

Beyond validity, mempool admission requires:
- Global mempool not full (max 10,000 transactions)
- Per-account limit not reached (max 64 pending per sender)
- If same sender+nonce exists: replacement requires fee ≥ old_fee × 1.1 + 1 (10% bump)
- If mempool full: new tx fee must exceed lowest existing fee

### 3.2 Transaction Selection (Block Building)

Transactions are selected by fee descending. The miner includes up to `maxNumberOfTransactionsPerBlock - 1` fee-paying transactions, plus one coinbase transaction at index 0.

---

## 4. State Model

### 4.1 Content-Addressed Storage (CAS)

All blocks, transactions, and state objects are stored by their content identifier (CID). The CAS has three tiers:
1. **Memory**: In-process LRU cache
2. **Disk**: Shared DiskBroker — a single SQLite store (Volume-granular, ref-counted pins) for all chains
3. **Network**: Peer-to-peer fetch via Ivy protocol

The CAS is the single source of truth for all blockchain data. Higher-level systems (PBSS, receipts, mempool persistence) store only CID references and derive full data on-demand via CAS resolution. This eliminates data duplication and ensures consistency:

- **Mempool persistence**: Saves only `{signatures, bodyCID}` per transaction. On startup, bodies are resolved from CAS (already stored locally from prior gossip).
- **Transaction receipts**: Recent receipts stored in full for fast queries. A lightweight index `{txCID → blockHash, height}` enables CAS-derived reconstruction for older receipts if the full receipt has been pruned.
- **Block propagation**: Miners push full block data to direct peers (ensuring availability). Relay peers announce CIDs only; downstream nodes resolve from CAS, finding most transaction bodies already local from mempool gossip.
- **State queries**: PBSS (SQLite) serves as a fast O(1) read cache over the CAS merkle trees. The CAS remains authoritative; PBSS is rebuilt from CAS after sync.

Accepted blocks are stored as one **object closure** — a single `storeRecursively`
pass producing per-boundary volumes joined by owned-child edges, rooted at the
block CID, with no singleton promotion. The owned closure is the block, its
`transactions` (and bodies), the chain `spec`, the `postState` frontier, and
`children` block volumes. The block's backward links — `prevState`, `parentState`,
and `parent` — are cashew `Reference`s, *not* owned children: never walked, never
edged, and resolved by CID on demand, so a pin on the block root cannot leak
backward into prior/parent state or ancestor blocks. Content is resolved by CID
(`fetchData`), not by entering Volume roots. See
[Block content storage](design/block-content-storage.md).

### 4.2 Path-Based State Storage (PBSS)

Current state is indexed by path in SQLite for O(1) lookups:

| Path | Value | Description |
|------|-------|-------------|
| `account:<address>` | `{balance, nonce}` | Account state |
| `general:<key>` | bytes | General state (orders, etc.) |
| `meta:chain-tip` | CID | Current chain tip |
| `meta:height` | UInt64 | Current block height |
| `meta:state-root` | CID | Current postState CID |

### 4.3 CAS State Diffing

State changes are derived by structurally diffing the CAS merkle trees rather than replaying transactions. Each block's `prevState` (pre-execution state root) and `postState` (post-execution state root) are diffed using cashew's `CashewDiff`:

```
diff = postState.accountState.diff(from: prevState.accountState, fetcher: fetcher)
diff.inserted  → new accounts (address → balance)
diff.deleted   → removed accounts
diff.modified  → changed accounts (old balance → new balance)
```

This is used for:
- **Block acceptance**: Extract account changes to update PBSS StateStore
- **Reorg recovery**: Invert diffs (swap old/new) to roll back orphaned blocks' state changes
- **Sync state rebuild**: Resolve tip postState directly instead of replaying blocks

Advantages over transaction replay: correct by construction (captures all state changes including implicit ones from child chains), O(changed accounts) instead of O(transactions × actions), and independent of transaction execution logic.

### 4.4 State Expiry

Accounts inactive for >1,000,000 blocks are moved from `account:<address>` to `expired:<address>`. They can be revived by providing the account data. Expired accounts retain their balance and nonce.

### 4.5 Transaction Receipts

Two-tier receipt storage for optimal availability and efficiency:

1. **Recent receipts**: Full receipt stored in StateStore on block acceptance (fast queries, no CAS dependency)
2. **Receipt index**: Lightweight `{txCID → blockHash, height}` index stored alongside full receipt

On query, the full receipt is returned directly if available. If it has been pruned (state expiry), the index enables CAS-derived reconstruction by resolving the block and extracting the transaction. This gracefully degrades: recent receipts are instant, historical receipts require a CAS fetch but remain available as long as the block is in CAS.

| Field | Type | Description |
|-------|------|-------------|
| txCID | String | Transaction content identifier |
| blockHash | String | Block containing this transaction |
| blockHeight | UInt64 | Block height |
| timestamp | Int64 | Block timestamp |
| fee | UInt64 | Transaction fee |
| sender | String | First signer address |
| accountActions | [{owner, delta}] | Signed per-account balance deltas |

---

## 5. Networking

### 5.1 P2P Protocol (Ivy)

Nodes communicate via the Ivy protocol, which provides:
- **Kademlia DHT** for peer discovery
- **Tally** reputation system for peer scoring
- **k-bucket routing** for peer management
- **Block announcement**: broadcast block CID to peers
- **Block fetch**: retrieve block data by CID
- **Volume fetch**: request an opaque serialized Volume by root CID
- **Chain announce on connect**: when a new peer connects, the node announces its current chain tip for each subscribed chain, triggering synchronization if the peer is behind
- **mDNS**: local network peer discovery (optional)

Volume fetches are root-keyed. A `WANT` asks for the full serialized Volume
rooted at a CID; the responder serves the entries it has for that root without
needing to know the Cashew/Lattice schema. Ivy verifies each returned
`(CID, bytes)` pair by content address and requires the root entry to be
present before resolving the fetch. Invalid bytes are slashable; `NOT_HAVE`,
empty `BLOCKS`, and hash-valid responses that do not include the root are
neutral incomplete responses that only exhaust that peer candidate.

### 5.2 Peer Discovery

On startup, peers are discovered from (in order):
1. Persisted peers (`peers.json` from previous session)
2. Hardcoded bootstrap nodes (`BootstrapPeers.nexus`)
3. DNS seeds (TXT records at seed hostnames)
4. DHT peer refresh (every 60 seconds)

### 5.3 Peer Diversity (Eclipse Protection)

- Max 2 outbound connections per /16 subnet
- Target 8 outbound + 2 block-relay-only connections
- 2 anchor peers persisted across restarts
- Overrepresented subnets pruned during refresh

### 5.4 Block Propagation

Blocks use a **hybrid push/announce** model for optimal data availability and bandwidth:

1. **Miner → direct peers**: Full block data pushed via `publishBlock`, ensuring at least N peers have the complete block immediately
2. **Relay peers → their peers**: CID-only announcement via `announceBlock`; downstream nodes resolve from CAS
3. **CAS resolution**: Receiving peers resolve block CID through the 3-tier CAS (memory → disk → network). Transaction bodies are typically already local from prior mempool gossip
4. **Deduplication**: CAS never re-fetches data already stored locally. Only genuinely new content (coinbase transaction, state roots) is transferred on hops 2+

This balances data availability (full push to first hop guarantees block survival) with bandwidth efficiency (CID-only relay for subsequent hops, ~99% reduction for transaction-heavy blocks).

### 5.5 Rate Limiting

Per-peer: max 20 blocks per 10-second window. Peer reputation managed by the Tally system — peers delivering invalid blocks, timing out, or exceeding rate limits are penalized and eventually disconnected.

### 5.6 Per-Process Child Subscription

In the per-process topology each child chain runs as its own `LatticeNode` (`--genesis-hex --chain-directory --subscribe-p2p`) and receives its blocks from its parent rather than mining or fetching them independently:

1. The parent's `POST /api/chain/deploy` returns the child's `genesisHex` and a `chainP2PAddress` for the parent P2P endpoint the child subscribes to. The child boots from that genesis (`--genesis-hex`), so it needs no DHT lookup to start, and the parent does not create a child fork-choice view.
2. The child opens a **dedicated Ivy connection** to the parent's P2P port (`--subscribe-p2p`). A `ParentChainBlockExtractor` consumes parent-block gossip, extracts this child's block from `parent.children[directory]` using a sparse content-addressed proof (`ChildBlockProof`), validates it against the parent's proof-of-work root hash and parent-state continuity evidence, applies it, and relays it onto the child's own gossip network so the child's grandchildren can subscribe in turn. The parent link is an availability channel, not a canonicality oracle.
3. The child calls `POST /api/chain/register-rpc` so the parent can advertise its RPC endpoint via `GET /api/chain/map`.

Child P2P ports are derived as `basePort + 1 + FNV1a(directory) mod 16384`, where `directory` is the child's edge label relative to its parent, so a child and its parent agree on the port without coordination. This isolates each chain into its own process — independent crashes, restarts, and resource limits — while preserving merged-mining security, since verified parent-carrier proofs still cover the child block. A parent reorg changes what the parent mines next; it does not force the child to reset unless the child itself observes a heavier valid fork under its own `trueCumWork`.

---

## 6. Synchronization

### 6.1 Sync Trigger

Sync is triggered when a peer announces a block whose height is more than `catchUpSyncThreshold` (3) blocks ahead of the local tip — smaller gaps are absorbed by normal gossip. Syncs within `shallowSyncThreshold` (200) blocks keep mining running; deeper syncs pause it until the sync completes. The trigger fires via normal block gossip or via the chain announce exchanged on peer connect, so a restarted node that is behind begins syncing as soon as it connects to an up-to-date peer, without waiting for the next mined block.

### 6.5 Crash Recovery (CAS-Based)

If the node shuts down ungracefully (crash, SIGKILL, power loss), `chain_state.json` may be stale by up to `persistInterval` blocks. The SQLite state store is crash-safe (WAL mode) and tracks the authoritative chain tip and height. CAS files are written to disk immediately on block acceptance.

On restart, the node detects any gap between the chain state (from `chain_state.json`) and SQLite, then recovers:

1. Read chain tip CID and height from SQLite (`meta:chain-tip`, `meta:height`)
2. If SQLite height > chain state height, walk backwards through CAS from SQLite tip to chain state tip, collecting blocks
3. Replay collected blocks forward via `processBlockHeader`
4. Persist the recovered chain state

This is a local-only operation — no peers are needed. Recovery is O(gap) where gap is the number of blocks between the last persist and the crash.

### 6.2 Headers-First Sync

Node sync uses one headers-first path. There is no node-level state-only, full,
snapshot, or tip-only strategy selection.

Headers-first sync runs three phases:

1. Download and validate the candidate header chain, including PoW and ancestry.
2. Download and resolve the required block bodies and state/action data.
3. Replay block effects, advance storage retained roots, then publish the
   canonical segment through the durable StateStore commit path.

A peer tip that cannot provide enough verifiable headers, bodies, and state to
build a canonical segment fails closed. It is not installed as an estimate-only
tip.

### 6.3 Post-Sync Verification

After sync, query multiple peers to confirm the synced chain tip is recognized by the network. Log warning if fewer than 2 peers confirm.

### 6.4 State Rebuild

After sync, the PBSS StateStore is rebuilt directly from the tip block's postState state root via CAS resolution:

1. Resolve tip block's `postState` → `LatticeState`
2. Resolve `accountState` MerkleDictionary recursively
3. Enumerate all key-value pairs (address → balance)
4. Bulk-write to StateStore's `account:` paths
5. Populate block index from persisted block metadata

This is O(accounts) — resolving the final state once — rather than O(blocks × changes) from replaying every block's changeset. Falls back to block-by-block replay if CAS resolution fails.

---

## 7. Mining

Mining is split across three roles: `LatticeNode`, `MiningCoordinator`, and
`LatticeMiner` worker. The role contract is defined in
[Mining role boundaries](design/mining-role-boundaries.md). The node runs no
internal proof-of-work search. It owns chain state, template construction,
solution validation, block acceptance, persistence, merged-mining proof
handling, and gossip publication. The coordinator owns work lifecycle and nonce
range fan-out. Workers only search assigned immutable work.

### 7.1 Block Template Construction (node)

1. Resolve current chain tip
2. Select up to `maxTransactionsPerBlock - 1` transactions from mempool (fee descending)
3. Build coinbase transaction (reward + fees to non-secret payout/address material, signed by the node-local coinbase authority)
4. Build child chain blocks for merged mining
5. Compute next target
6. Assemble block template with nonce=0

### 7.2 Work Coordination

A `MiningCoordinator` fetches or subscribes to node work, assigns
non-overlapping nonce ranges to one or more workers, cancels stale work, resolves
competing worker results, and submits the first valid result back to the node.
The coordinator does not construct child proofs or publish blocks.

### 7.3 Proof-of-Work Search (worker)

`LatticeMiner` workers search a provided `workId`, serialized nonce-0 `Block`
node (`blockHex`), node-computed target, and nonce range. A worker may derive
the canonical PoW midstate locally from that block, then returns a nonce/hash
result or an exhausted/cancelled/stale status. A worker does not resolve block
content roots, know child-chain topology, gossip, generate child proofs, or hold
or send coinbase private keys to the node.

### 7.4 Solution Submission

On ingesting a valid solution result from the coordinator, or a valid block from
a peer, the node:

1. Rejects stale, malformed, wrong-target, wrong-chain, or duplicate work
2. Seals accepted local work with the submitted nonce
3. Generates or verifies merged-mining proof material as needed
4. Stores block content recursively in CAS
5. Processes locally through the normal block-acceptance path
6. Removes confirmed transactions from both mempools
7. Updates block index and StateStore
8. Publishes the accepted block through `ChainNetwork`
9. Persists chain state if interval reached

---

## 8. RPC API

### 8.1 Chain

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/chain/info` | GET | Chain status (height, tip, mining, mempool, genesis hash/timestamp) |
| `/api/chain/spec` | GET | Chain specification parameters |
| `/api/chain/map` | GET | Chain path → RPC endpoint for per-process children |
| `/api/chain/deploy` | POST | Create a child chain; returns `genesisHex` + `chainP2PAddress` (privileged) |
| `/api/chain/register-rpc` | POST | A child process registers its RPC endpoint with the parent |

### 8.2 Accounts

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/balance/{address}` | GET | Account balance |
| `/api/nonce/{address}` | GET | Account nonce |
| `/api/proof/{address}` | GET | Merkle balance proof |

### 8.3 Blocks

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/block/latest` | GET | Latest block info |
| `/api/block/{id}` | GET | Block by hash or height |

### 8.4 Transactions

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/transaction` | POST | Submit transaction |
| `/api/receipt/{txCID}` | GET | Transaction receipt |
| `/api/mempool` | GET | Mempool stats |

### 8.5 Fee Market

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/fee/estimate?target=N` | GET | Fee estimate for N-block confirmation |
| `/api/fee/histogram` | GET | Fee distribution histogram |

### 8.6 Cross-Chain Transfer

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/deposits` | GET | Active deposits on this chain |
| `/api/deposit` | GET | Look up one deposit by demander/amount/nonce |
| `/api/receipt-state` | GET | Look up a withdrawal receipt on the parent chain |

### 8.7 Light Client

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/light/headers?from=X&to=Y` | GET | Block headers for sync |
| `/api/light/proof/{address}` | GET | Account proof with chain context |

### 8.8 Network

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/peers` | GET | Connected peer list |

### 8.9 Observability

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/metrics` | GET | Prometheus metrics |
| `/ws` | GET | Event subscription stream |

### 8.10 Authentication

At startup, the node writes a random 32-byte hex RPC cookie to `<dataDir>/.cookie`. Privileged/state-changing RPC endpoints require `Authorization: Bearer <token>` even on loopback; public read endpoints, `/health`, `/metrics`, and `/ws` remain public.

---

## 9. Nexus Chain Parameters

| Parameter | Value |
|-----------|-------|
| Directory | Nexus |
| Target block time | 3,600,000 ms (1 hour) |
| Initial reward | 1,048,576 (2^20) |
| Halving interval | 876,600 blocks (~100 years at 1-hour blocks) |
| Max transactions/block | 5,000 |
| Max state growth | 3,000,000 bytes/block |
| Max block size | 1,000,000 bytes |
| Premine | 175,320 blocks of reward ≈ 183,836,344,320 (~10% of total supply) |
| Retarget window | 120 blocks |
| Genesis timestamp | 0 (epoch — deterministic, launch-date-independent) |

(Testnet ships its own frozen genesis: the Nexus-identical spec with a distinct faucet premine owner, the same timestamp `0`, and its own pinned `expectedBlockHash`. Nodes confirm they share a genesis by comparing `genesisHash` from `/api/chain/info`.)

---

## 9b. Cross-Chain Transfer (Deposits, Receipts, Withdrawals)

Value moves between a parent chain and a child chain through a three-step, protocol-level flow — there is no bridge contract and no time-lock. Each step is a transaction action validated at consensus.

### 9b.1 Deposit

A `DepositAction` on the source chain locks funds. It carries `{nonce, demander, amountDemanded, amountDeposited}`; the `demander` must be a signer and both amounts must be non-zero. The locked amount is recorded in the chain's `depositState` (a sparse merkle dictionary keyed by `demander/amountDemanded/nonce`).

### 9b.2 Receipt

A `ReceiptAction` on the parent chain authorizes a specific withdrawer to claim the deposit. It carries `{withdrawer, nonce, demander, amountDemanded, directory}` and is recorded in the parent's `receiptState`. The `directory` field is the destination edge label relative to that parent; the full destination identity is the parent chain path plus this edge.

### 9b.3 Withdrawal

A `WithdrawalAction` on the child chain releases the funds to the withdrawer. It carries `{withdrawer, nonce, demander, amountDemanded, amountWithdrawn}`. It is valid only if the validator can prove, against the parent chain's state root referenced by `parentState`, that (a) a matching deposit exists with `amountDeposited >= amountWithdrawn`, and (b) a matching receipt exists naming this `withdrawer` for this parent-relative `directory`. Both are sparse merkle proofs; the deposit entry is deleted as part of the transition.

### 9b.4 Balance Conservation

Across a block, transaction fees are not independent income: they are spendable by the miner only when the same block's account actions include the corresponding sender debits. Deposits remove value from one chain's circulating supply and the corresponding withdrawals introduce it on the other. Every step is zero-sum on its own chain.

---

## 10. Security Considerations

### 10.1 Replay Protection
Two mechanisms: (1) **sequential per-signer nonces** — each signer account's nonces must be contiguous from 0 with no gaps, enforced at consensus against the account state trie; and (2) **`chainPath`** in the signed `lattice-tx-v1` envelope — a transaction names the exact chain path it targets, so it cannot be replayed on a different chain in the tree. The mempool admits a bounded window (up to 64) of future nonces per signer for concurrent submission.

### 10.2 Balance Verification
Every debit is verified against current account state. Conservation is enforced from account deltas: sender debits must cover recipient credits, fees, deposits, and withdrawals according to the chain transition being validated.

### 10.3 Overflow Protection
All fee/balance arithmetic uses overflow-checking operations. Overflow returns validation failure.

### 10.4 Fee Bounds
Min fee: 1. Max fee: 1,000,000,000,000. Prevents both spam (min) and overflow attacks (max).

### 10.5 Block Rate Limiting
Max 20 blocks per peer per 10-second window. Oversized blocks (> maxBlockSize) rejected with reputation penalty.

### 10.6 Timestamp Validation
Block timestamps must be within ±2 hours of node's local time.

---

## 11. Node Architecture

```
┌─────────────────────────────────────────────────────┐
│  CLI (swift-argument-parser)                         │
│  node | devnet | cluster | keys | status | query     │
├─────────────────────────────────────────────────────┤
│  Daemon                                              │
│  Signal handling, background loops, lifecycle        │
├──────────┬──────────┬───────────┬───────────────────┤
│  Chain   │  Mempool │  Network  │  RPC              │
│  Blocks  │  NodeMem │  Ivy P2P  │  Hummingbird HTTP │
│  Sync    │  Validat │  Peers    │  Auth             │
│  State   │  Persist │  Diversity│  Prometheus       │
│  Persist │  RBF     │  Anchors  │  WebSocket (plan) │
├──────────┼──────────┼───────────┼───────────────────┤
│  Mining  │  Storage │  Config   │  Health           │
│  PoW     │  PBSS    │  NodeConf │  Logger           │
│  Merged  │  SQLite  │  Resource │  Metrics          │
│  Parallel│  CAS     │           │                   │
├──────────┴──────────┴───────────┴───────────────────┤
│  Lattice (external): Consensus, ChainState, Blocks   │
│  Ivy (external): P2P, DHT, Tally                     │
│  VolumeBroker (external): CAS storage brokers, pins   │
└─────────────────────────────────────────────────────┘
```

---

## 12. Future Considerations

- **EIP-1559 dynamic fee market**: Algorithmic base fee with priority tip and fee burning
- **Block DAG**: Process orphan blocks (GhostDAG/DAGKnight) instead of discarding them
- **Cluster mempool**: Group related transactions for optimal block building
- **Erasure-coded propagation**: Reed-Solomon encoding for bandwidth-efficient block relay
- **Verkle tree state proofs**: Smaller proofs for stateless client verification
- **WebSocket subscriptions**: Real-time block/transaction event streaming
- **Formal verification**: Model consensus rules in proof assistant

---

*Protocol Version: 2*
*Specification Version: 0.1.0*
*Last Updated: May 2026*
