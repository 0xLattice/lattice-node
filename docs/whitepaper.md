# Lattice: A Content-Addressed Multi-Chain Proof-of-Work System

*The Lattice Authors*
*March 2026*

## Abstract

We propose **Lattice**, a protocol in which every chain is both a root chain and the tree of chains rooted at it, secured by one shared proof-of-work. All data — blocks, transactions, and state — is stored in a content-addressed storage (CAS) layer, enabling a novel approach to multi-chain security and state management. Each chain defines its own operations yet inherits its ancestors' proof-of-work security through merged mining at zero additional cost. The single root chain is the **Nexus**; every other chain is a descendant beneath it. State transitions are derived by structurally diffing merkle trees rather than replaying transactions, making state extraction correct by construction and independent of execution logic. Block propagation exploits the CAS layer: miners push full blocks to direct peers for availability, while relay peers announce only content identifiers, with downstream nodes reconstructing blocks from locally-cached transaction data. This combination of content-addressed storage, structural state diffing, and merged mining creates a system where adding new chains does not dilute security, state management is provably consistent, and network bandwidth scales sub-linearly with block size. Because the root chain is deliberately small and all data is content-addressed and refetchable, a node — even one holding no local state — runs on commodity hardware and can both validate and mine by fetching from peers on demand, keeping participation in the base chain broadly accessible while throughput is pushed to opt-in high-capacity child chains.

---

## 1. Introduction

The original Bitcoin design [1] demonstrated that a peer-to-peer network of nodes can agree on a total ordering of transactions using proof-of-work, without relying on trusted third parties. However, Bitcoin's single-chain architecture creates a fundamental tradeoff: all applications must compete for space on one chain, and building a new chain means building new security from scratch.

Existing approaches to this problem include sidechains [2], which require explicit trust assumptions for cross-chain transfers; rollups [3], which inherit parent chain security but require complex fraud or validity proofs; and proof-of-stake multi-chain systems [4], which sacrifice the permissionless nature of proof-of-work.

We present Lattice, a system that resolves this tension through three key ideas:

1. **Content-addressed merged mining.** A parent chain block may embed child chain blocks as content-addressed references. The parent's proof-of-work covers the entire tree, so child chains inherit full security with no additional mining. Adding a new child chain requires no changes to the mining process.

2. **Structural state diffing.** Rather than deriving state by replaying transactions, Lattice stores pre-execution and post-execution state roots in each block and computes state transitions by structurally diffing the merkle trees. This makes state extraction correct by construction, enables O(accounts) state rebuild after sync, and allows reorg recovery without transaction re-execution.

3. **CAS-first block propagation.** All blockchain data is content-addressed. Transactions gossiped through the mempool are stored locally by their content identifier. When a block is announced, receiving nodes reconstruct it from their local CAS, fetching only genuinely new data (coinbase, state roots) from the network. This reduces relay bandwidth by approximately 99% for transaction-heavy blocks.

A direct consequence is that the cost of *participating* in the root chain is low. The Nexus is kept deliberately lightweight — a slow block interval and a small block size — and because state is content-addressed and refetchable, a node can run to a small, configurable resource budget, evicting and refetching from peers rather than retaining everything. A node holding no local state at all can still validate and produce blocks, fetching the subtrees it needs on demand. This keeps the barrier to running and mining the base chain low — which is what makes the network broadly decentralized rather than concentrated among operators who can afford a heavyweight full node. Applications that need high throughput do not push that cost onto the base chain; they create child chains whose own `ChainSpec` selects faster blocks and larger limits, borne only by that child's participants while inheriting the Nexus's proof-of-work through merged mining.

---

## 2. Content-Addressed Storage

### 2.1 Data Model

Every object in Lattice — blocks, transactions, state trees, chain specifications — is serialized to a deterministic canonical form and identified by its content hash (CID). The CID is computed as:

```
CID = encode(hash(serialize(object)))
```

where `serialize` uses sorted-key JSON encoding and `hash` produces a 256-bit digest. This means identical data always produces identical identifiers, regardless of when or where it was created.

### 2.2 Three-Tier Resolution

Objects are stored in a three-tier cache hierarchy:

- **Memory**: In-process LRU cache for hot data
- **Disk**: Persistent key-value store for local data
- **Network**: Peer-to-peer fetch via the Ivy protocol for missing data

When a CID is requested, the system checks each tier in order. This means data gossiped via the mempool (stored locally) is never re-fetched during block reconstruction — a property we exploit for bandwidth-efficient block propagation.

### 2.3 Merkle Data Structures

State is organized as merkle dictionaries — content-addressed key-value trees where each node's CID depends on its children. This provides two properties:

1. **Inclusion proofs.** A light client can verify that an account balance is correct by checking a logarithmic-sized proof against the state root in a block header.

2. **Structural diffing.** Given two state roots (before and after a block's transactions), the system can compute exactly which keys changed, were inserted, or were deleted, without knowledge of the transactions themselves.

---

## 3. Multi-Chain Architecture

Lattice does not impose one rule set on every chain — each chain defines its own operations (state transitions, validity, economics). What Lattice provides is the *organizing protocol* that arranges these heterogeneous chains into a tree where each parent secures its children with the same proof-of-work. That organizing relationship is self-similar at every parent→child edge; the chains it secures are free to differ. See [Fractal structure](design/fractal-structure.md).

### 3.1 The Nexus Chain

The single root — the primary entry, addressed as `Nexus` — sits at the top of the tree; every other chain is a descendant beneath it. It has its own state, transaction throughput, and economic parameters (block time, reward schedule, target adjustment). Every node must validate this chain.

### 3.2 Child Chains

A child chain is a fully independent blockchain with its own:
- **Chain specification**: block time, reward, max transactions, state growth limits
- **State**: separate account balances, general state, and transaction history
- **Target**: adjusted independently of the parent

Child chains are created by including a child genesis block inside a Nexus block's `children` field. Once discovered, nodes that subscribe to that child chain begin tracking its state.

### 3.3 Merged Mining

A block template includes a `children` field — a content-addressed dictionary mapping parent-relative directory edges to child block headers. The miner searches against the **easiest** target among the chains it carries; whatever nonce it finds produces a valid block for exactly those chains whose target that one hash clears — the child (easy target) commonly, the parent/Nexus (hard target) only when the same hash also clears it. Each level is graded **independently** against its own target from the single grind. A hash that clears the child but *not* the parent yields a **child-only carrier**: a root-shaped block that commits the child but is never added to the parent chain, yet still secures the child via a self-contained `ChildBlockProof`.

The proof-of-work hash covers the entire block structure including the child block CIDs. Each block commits to its predecessor (`parent`), its pre- and post-execution state roots (`prevState`, `postState`), its parent chain's state (`parentState`), the embedded child blocks (`children`), and its `height`:

```
hash_input = parent || prevState || postState || parentState || target || ... || children || height || timestamp
valid iff target >= hash(hash_input + nonce)
```

Since the `children` CID is included in the hash input, the child blocks are immutably bound to the parent's proof-of-work. An attacker cannot modify a child block without invalidating the parent block's hash.

### 3.4 Security Analysis

Each chain is validated against **its own** target and secured by its own opt-in hashpower; a child is not automatically backed by "the full hashrate of Nexus." A child block is secured by the carrier's proof-of-work *hash* via a self-contained `ChildBlockProof` (`childTarget >= carrierHash` + parent-state anchor), **independent of whether that carrier ever became a canonical Nexus block** — a child-only carrier secures a child while never being a Nexus block at all, so there is no "corresponding Nexus block" to rewrite. Inherited (parent-level) work is credited **per level, only for a carrier whose hash actually clears that level's target** (counted once per chain), and is **zero** for a child-only carrier. See `docs/analysis/merged-mining-incentives.md` for the authoritative per-chain security model, which superseded the earlier "one Nexus PoW secures everything" framing.

This contrasts with independent PoW chains, where security is proportional to each chain's individual hashrate, and with federated sidechains, where security depends on the honesty of a fixed set of signers.

---

## 4. State Management

### 4.1 Dual State Representation

Each block contains two state roots:
- **prevState**: the state root *before* the block's transactions are applied
- **postState**: the state root *after* the block's transactions are applied

Both are CIDs pointing into the merkle state tree. The prevState of block *N* equals the postState of block *N-1*.

### 4.2 Structural State Diffing

To determine what changed in a block, the node structurally diffs the postState and prevState merkle trees:

```
diff = postState.accountState.diff(from: prevState.accountState)
diff.inserted  → new accounts created
diff.deleted   → accounts removed
diff.modified  → accounts whose balance changed (with old and new values)
```

This approach has three advantages over transaction replay:

1. **Correct by construction.** The diff captures every state change, including implicit changes from child chain operations that don't appear in transaction bodies.
2. **Execution-independent.** State changes can be extracted without understanding transaction semantics. This enables alternative node implementations to verify state without reimplementing the full execution engine.
3. **Efficient reorg recovery.** To roll back a block during a chain reorganization, the node inverts the diff (swapping old and new values). No transaction re-execution is required.

### 4.3 Path-Based State Storage

For query performance, current state is cached in a SQLite database indexed by path:

| Path | Value |
|------|-------|
| `account:<address>` | `{balance, nonce}` |
| `general:<key>` | arbitrary data |
| `meta:chain-tip` | current tip CID |

This provides O(1) balance lookups for RPC queries. The CAS merkle tree remains the source of truth; the path-based cache is rebuilt from the CAS postState after sync.

### 4.4 State Rebuild After Sync

When a node syncs from a peer, it does not replay every block's transactions. Instead:

1. Resolve the tip block's postState root from the CAS
2. Recursively resolve the account state merkle dictionary
3. Enumerate all key-value pairs and write them to the path-based cache

This is O(total accounts) rather than O(total blocks × changes per block).

---

## 5. Block Propagation

### 5.1 The CAS Propagation Model

Traditional blockchain networks propagate full block data to every peer. In Lattice, transaction bodies are already distributed through mempool gossip and cached in each node's local CAS.

When a miner produces a block:

1. The full block tree (header, transactions, state) is stored in the miner's CAS
2. The miner pushes the full block to direct peers (ensuring immediate data availability)
3. Direct peers announce only the block CID to their peers
4. Downstream nodes resolve the block CID through their CAS — finding most transaction bodies already cached locally from prior mempool gossip
5. Only genuinely new data (coinbase transaction, state roots) is fetched from the network

### 5.2 Bandwidth Analysis

For a block containing *n* transactions where *p* fraction of those transactions were previously gossiped through the mempool:

- Traditional propagation: each relay transfers the full block (~*n* × *t* bytes, where *t* is average transaction size)
- CAS propagation (hop 2+): each relay transfers the block header + (1-*p*) × *n* × *t* bytes

In practice, *p* > 0.99 for blocks produced shortly after mempool propagation, yielding approximately 99% bandwidth reduction on relay hops.

---

## 6. Transaction Model

### 6.1 Account Actions

Lattice uses an explicit balance-change model rather than an opcode-based virtual machine. A transaction contains a list of `AccountAction` entries, each specifying:

- `owner`: the account address
- `delta`: a signed `Int64` balance change — positive credits the account, negative debits it

Each `delta` must be non-zero. The node aggregates the net delta per account, resolves each owner's current balance from state, and applies the change — rejecting any debit that exceeds the owner's balance. There is no client-supplied "current balance" field; balances live in state and the action carries only the change. The conservation law holds across all actions:

```
sum(debits) = sum(credits) + fee
```

where a credit is a positive `delta` and a debit is the magnitude of a negative `delta`.

Accounts are identified by an address derived as the CID of an Ed25519 public key. Actions that debit an account must be authorized by an Ed25519 signature from that account's key.

### 6.2 Cross-Chain Value Transfer

Value moves between chains in the tree through a protocol-level three-step flow, with no bridge contract, time-lock, or trusted intermediary. Each step is an ordinary on-chain action, and validity is established entirely by sparse merkle proofs against the relevant chain states.

1. **Deposit.** On the source chain, the depositor locks funds by recording a `DepositAction` in that chain's deposit state. A deposit is keyed by `(nonce, demander, amountDemanded)` and records the amount actually deposited. Locking the funds debits the depositor's balance under the same conservation law as ordinary account actions.

2. **Receipt.** On the **parent** chain of the destination, a `ReceiptAction` authorizes a specific withdrawer to claim the deposit. The receipt is keyed by `(nonce, demander, amountDemanded, directory)` — where `directory` is the destination edge label relative to that parent — and binds the claim to one withdrawer address (stored as a CID reference to the withdrawer's public key). Because receipts live on the parent chain, the parent's state acts as the authoritative record that a cross-chain claim has been authorized.

3. **Withdrawal.** On the destination child chain, a `WithdrawalAction` releases the funds to the named withdrawer. A withdrawal is valid only if two sparse merkle proofs hold against the parent state root carried by the child block: an **existence proof** that the matching deposit exists in the source chain's deposit state, and an **existence proof** that the matching receipt exists in the parent chain's receipt state (`parentState.receiptState`). If either proof fails, the withdrawal is rejected. Parent-chain canonicity is not part of this validation; the committed state root and content-addressed proof are the authority.

Because the proofs are checked against committed state roots rather than mediated by a contract or a federation, cross-chain transfers inherit the same merged-mining security as the chains themselves: forging a withdrawal would require forging the parent chain's proof-of-work.

---

## 7. Consensus

### 7.1 Proof of Work

A block is valid when `target >= hash(block_prefix + nonce)`, where the block prefix includes all block fields except the nonce. The node owns block template construction, target calculation, solution validation, block sealing, persistence, and gossip. External mining code coordinates work and performs the proof-of-work nonce search, returning nonce/hash results to the node-owned acceptance path. The node itself runs no internal nonce-search loop.

### 7.2 Fork Choice — Hierarchical GHOST

The canonical tip is the one of greatest **`trueCumWork`**, which combines a block's own forward descendant-subtree work with verified merged-mining proof contributions:

```
work(B)          = MAX_UINT256 / B.target
subtreeWeight(B) = work(B) + Σ subtreeWeight(children(B))   // forward GHOST subtree, each block once
inherited(B)     = Σ verifiedProofContribution(B)           // 0 for the nexus, AND 0 for any carrier level whose shared hash did NOT clear that level's own target (e.g. a child-only carrier); credited once per chain; idempotent by proof contribution ID
trueCumWork(B)   = subtreeWeight(B) + inherited(B)
```

Heaviest `trueCumWork` wins; an exact tie holds the incumbent. This selects the chain backed by the most total work **plus the verified work that actually proved this block was committed in the lattice**, not merely the longest path. A parent block is a proof carrier and an availability source, not a child fork-choice authority: once a child has a valid content-addressed proof that some parent block committed it, a later parent reorg does not erase that proof fact or roll back the child by itself. Parent canonicity matters to the parent chain's own mining, mempool, and fork choice; child chains advance and reorganize only from their own valid blocks plus verified proof contributions. There is **no explicit finality** — any block can be reorganized at any depth if a heavier child-chain subtree plus verified proof contributions appears (the only depth bound is a node's local retention horizon). Normative definition **and** design rationale live in the Lattice consensus library (`spec.md §9` and its `consensus-fork-choice.md`); the node-side realization is in [design/consensus-fork-choice.md](design/consensus-fork-choice.md).

### 7.3 Target Adjustment (Retargeting)

The target adjusts on every block within a rolling window (default: 120 blocks). If blocks are produced faster than the target block time (1 hour for Nexus), the target decreases (harder to satisfy); if slower, it increases (easier to satisfy). The adjustment rate is bounded to prevent extreme oscillations.

### 7.4 Block Rewards

```
reward(height) = initialReward >> (height / halvingInterval)
```

With `initialReward = 1,048,576` (2^20) and `halvingInterval = 876,600` blocks (approximately 100 years at 1-hour blocks), the reward halves roughly every century. Summed over all halvings, mined issuance converges to `halvingInterval × 2 × initialReward ≈ 1.84 × 10^12` tokens. A premine of roughly 10% of the schedule (about 175,320 blocks' worth of initial reward, ≈ 1.84 × 10^11 tokens) is allocated at genesis, bringing the total supply to approximately 2.0 × 10^12 tokens.

---

## 8. Network Protocol

### 8.1 Peer Discovery

Nodes discover peers through four mechanisms, in priority order:

1. **Persisted peers** from the previous session
2. **Bootstrap nodes** hardcoded in the binary
3. **DNS seeds** via TXT record lookups
4. **DHT discovery** via Kademlia queries (every 60 seconds)

### 8.2 Eclipse Attack Protection

To prevent an attacker from isolating a node by controlling all its peer connections:

- Maximum 2 outbound connections per /16 IPv4 subnet
- 2 "anchor peers" persisted across restarts
- Overrepresented subnets pruned during periodic peer refresh
- Peer reputation tracked via the Tally system, with automatic disconnection of misbehaving peers

### 8.3 Protocol Versioning

Each peer announcement includes a protocol version number, enabling coordinated network upgrades via height-activated forks. Nodes reject peers below the minimum supported protocol version.

---

## 9. Economics

### 9.1 Nexus Parameters

| Parameter | Value |
|-----------|-------|
| Block time | 1 hour (3,600,000 ms) |
| Initial reward | 1,048,576 tokens (2^20) |
| Halving interval | 876,600 blocks (~100 years at 1-hour blocks) |
| Mined issuance | ~1.84 × 10^12 tokens |
| Premine | ~10% (~175,320 blocks of reward, ≈ 1.84 × 10^11 tokens) |
| Total supply | ~2.0 × 10^12 tokens |
| Max transactions/block | 5,000 |
| Max block size | 1 MB |

### 9.2 Child Chain Economics

Each child chain defines its own economic parameters — block time, reward schedule, halving interval — independent of the Nexus chain. This enables application-specific tokenomics while inheriting Nexus-level security.

### 9.3 Fee Market

Transactions include an explicit fee. Miners select transactions by fee descending, creating a fee market where users compete for block space. Replace-by-fee (RBF) allows users to increase the fee on a pending transaction by at least 10%.

---

## 10. Related Work

**Bitcoin** [1] introduced proof-of-work consensus and the UTXO transaction model. Lattice builds on Bitcoin's security model while replacing UTXOs with explicit balance changes and adding native multi-chain support.

**Ethereum** [5] introduced stateful accounts and a Turing-complete virtual machine. Lattice takes a simpler approach: explicit account actions rather than general computation, with state transitions derived from merkle diffs rather than VM execution.

**Namecoin** [6] pioneered merged mining, allowing a child chain to reuse the parent's proof-of-work. Lattice generalizes this to an arbitrary tree of child chains embedded directly in the parent block structure.

**IPFS/Filecoin** [7] demonstrated content-addressed storage for distributed systems. Lattice applies the same principle to blockchain data, using CIDs as the universal reference mechanism for blocks, transactions, and state.

**Ethereum PBSS** [8] introduced path-based state storage to replace hash-based storage, reducing disk growth by an order of magnitude. Lattice adopts this pattern, using SQLite as a path-indexed cache over the CAS merkle trees.

---

## 11. Conclusion

Lattice demonstrates that content-addressed storage, when used as the foundational layer of a blockchain, enables a constellation of improvements to multi-chain security, state management, and network efficiency.

Merged mining through content-addressed child blocks provides a clean solution to the security fragmentation problem: new chains inherit full parent-chain security at zero marginal cost. Structural state diffing eliminates the need for transaction replay during state extraction, reorg recovery, and post-sync state rebuild. CAS-aware block propagation reduces relay bandwidth by approximately 99% by exploiting the fact that transaction data is already distributed via mempool gossip.

The system is operational, with a reference implementation, formal protocol specification, and deployment tooling available at https://github.com/adalinxx.

---

## References

[1] S. Nakamoto, "Bitcoin: A Peer-to-Peer Electronic Cash System," 2008.

[2] A. Back et al., "Enabling Blockchain Innovations with Pegged Sidechains," 2014.

[3] V. Buterin, "An Incomplete Guide to Rollups," 2021.

[4] E. Buchman, J. Kwon, Z. Milosevic, "The latest gossip on BFT consensus," 2018.

[5] V. Buterin, "Ethereum: A Next-Generation Smart Contract and Decentralized Application Platform," 2013.

[6] Namecoin, "Merged Mining Specification," 2011.

[7] J. Benet, "IPFS — Content Addressed, Versioned, P2P File System," 2014.

[8] R. Chen, "Geth Path-Based Storage Model," Ethereum Foundation, 2023.
