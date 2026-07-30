# Mining Role Boundaries

This document is the mining contract. It defines the boundary between the
node, a coordinator, and nonce-search workers.

## Roles

`LatticeNode` is the authority for chain state. It owns block template
construction, transaction selection, reward-plan validation, effective target
calculation, child-chain candidate embedding, merged-mining proof handling,
solution validation, block acceptance, persistence, and gossip publication.

`MiningCoordinator` owns work lifecycle outside the node. It fetches or
subscribes to node work, detects stale work, cancels old assignments, allocates
non-overlapping nonce ranges, collects worker results, resolves result races,
and submits the winning result to the node-owned solution API.

`LatticeMiner` is a worker. A worker receives a serialized nonce-0 `Block` node
assignment, deserializes it locally, searches the assigned nonce range, and
returns a nonce result or no result. It does not construct blocks, choose
transactions, resolve block content roots, know child-chain topology, gossip
blocks, generate child proofs, publish to Ivy, or send wallet private keys.
Reward transactions are signed outside the node and supplied as public payloads.
It must not gossip blocks.

## Worker Protocol

Worker input is an immutable assignment:

| Field | Owner | Description |
| --- | --- | --- |
| `workID` | Node or coordinator | CID-derived identifier for the exact nonce-zero template. |
| `blockHex` | Node | Hex-encoded serialized nonce-0 `Block` node. The worker may deserialize it and derive the canonical PoW midstate locally; it must not resolve sub-CIDs or mutate/submit the block. |
| `target` | Node | Search target for the parent plus embedded child candidates. |
| `nonceRange` | Coordinator | Inclusive start nonce and count assigned to this worker; ranges for one `workID` must not overlap. |
| `batchSize` | Coordinator | Local search chunk size used for cancellation checks and scheduling. |
| `staleToken` | Coordinator | Cancellation marker or generation number. If it changes, the worker stops returning results for the old work. |

Worker output is:

| Field | Description |
| --- | --- |
| `workID` | Work assignment the result belongs to. |
| `nonce` | Winning nonce, if found. |
| `hash` | Optional local diagnostic; it is not trusted or submitted to the node. |
| `rangeStart`, `rangeCount` | Range that produced the result. |
| `status` | `found` or `exhausted`; cancellation terminates the worker process. |

Workers may also expose local progress counters, but those counters are not
consensus inputs and are not submitted to the node.

Workers derive the midstate from Lattice's canonical nonce-independent block
preimage and append every candidate nonce as exactly eight big-endian bytes.
The worker does not define a second proof-of-work encoding.

## Ownership Matrix

| Responsibility | Owner |
| --- | --- |
| Template and candidate construction | `LatticeNode` |
| Externally signed reward transactions | Miner/wallet input; validated and partitioned by `LatticeNode` |
| Effective target calculation | `LatticeNode` |
| Merged-mining child proof generation and verification | `LatticeNode` |
| Block sealing from accepted solution | `LatticeNode` |
| Block acceptance, persistence, and gossip publication | `LatticeNode` |
| Stale-work detection and cancellation | `MiningCoordinator` |
| Nonce-range allocation and de-duplication | `MiningCoordinator` |
| Worker retry/backoff and result race resolution | `MiningCoordinator` |
| Proof-of-work nonce search | `LatticeMiner` worker |

## Submission Contract

The coordinator submits a result to the node, not a sealed block to peers. The
node validates that `workID` still names issued work,
that the nonce satisfies the node-computed target, and that the submission
has not already been accepted. Stale, malformed, wrong-chain, wrong-target, and
duplicate submissions are rejected without mutating canonical state or
publishing a block.

After a valid submission, the node seals the block with the submitted nonce,
generates any required merged-mining proof material, accepts and persists the
block through the normal block-acceptance path, and publishes the accepted block
through the node network runtime and same-chain overlay.

## Private-Key Boundary

Workers and coordinators must not send private key material to the node in
template/work requests. Reward signing happens before the coordinator reads the
reward plan. The template endpoint receives only the resulting transaction body
and signatures. Process identity remains a network identity, never a payout
identity.

## SOTA Basis

The contract follows the role split used by modern proof-of-work mining
protocols:

- [Stratum V2 Mining Protocol](https://stratumprotocol.org/specification/05-mining-protocol/)
  separates Mining Devices from upstream job/template roles. Mining devices
  receive work/search space and submit proof-of-work results.
- [Stratum V2 Job Declaration](https://stratumprotocol.org/specification/06-Job-Declaration-Protocol/)
  and [Template Distribution](https://stratumprotocol.org/specification/07-template-distribution-protocol/)
  separate template construction from downstream hash devices and allow an
  upstream role to coordinate valid work.
- [BIP22](https://github.com/bitcoin/bips/blob/master/bip-0022.mediawiki) /
  Bitcoin Core's [`getblocktemplate`](https://bitcoincore.org/en/doc/0.21.0/rpc/mining/getblocktemplate/)
  and [`submitblock`](https://developer.bitcoin.org/reference/rpc/submitblock.html)
  pattern keeps template construction and final block validation on the
  node/pool side while external mining software searches for proof-of-work.
- [AuxPoW / merged mining](https://en.bitcoin.it/wiki/Merged_mining_specification)
  keeps auxiliary proof material at the chain/protocol layer. Hash workers
  should not need child-chain topology or proof-generation responsibilities.

## Implementation Rule

Mining code must stay on the matrix above. `Sources/LatticeMiner` is a nonce
search worker target only. RPC transport, stale-work handling, range allocation,
and solution submission live in the coordinator. Contextual child orchestration
and proof generation stay inside the node's authenticated hierarchy plane. No
Ivy gossip, child topology, proof generation, or private-key submission may
exist in the worker target.
