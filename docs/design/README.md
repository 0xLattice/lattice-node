# Lattice node design documents

An index of the design documents for `lattice-node`, grouped by what kind
of page each is. Every page states its status at the top. For how the node
is built start with [Node architecture](../architecture.md); for what
nodes say to each other, the [Peer protocol](../protocol.md). Consensus
rules are in the
[Lattice specification](https://github.com/0xLattice/Lattice/blob/59.3.0/docs/spec.md),
not here.

## Current descriptions

How a part of the node works now, and why it has that shape.

| Page | What it describes |
|---|---|
| [Recursive commitments, independent levels](fractal-structure.md) | The four rules the node follows because the chain hierarchy is recursive. |
| [Chain addressing](chain-addressing.md) | How a chain is named, and what makes a path valid. |
| [Process trust model](process-trust-model.md) | What a hosted chain level trusts: its co-hosted parent, peers, content. |
| [Consensus and fork-choice ownership](consensus-fork-choice.md) | The line between Lattice's rules and the node's operation, and what a fresh node must trust to sync. |
| [Proof-derived child work](proof-derived-work.md) | How a child block's work and parent state are checked, top-down weighing, and derived grinds. |
| [Composable hosted-tree capabilities](modular-import-pipeline.md) | The six capabilities block and transaction intake is composed of, and their boundaries. |
| [Body acquisition](block-fetching.md) | From a weighed header to an executed block: which bodies, from whom, and how the node waits. |
| [Mining role boundaries](mining-role-boundaries.md) | The contract between node, coordinator and nonce-search workers. |
| [Bitcoin-anchored genesis](bitcoin-anchored-genesis.md) | Where the Nexus genesis is committed on Bitcoin, and how to verify it. |

## Decision records

What was decided, why, and what was measured.

| Page | What it records |
|---|---|
| [Node design](node-design.md) | What the node is for, its outcomes and targets, each part compared with other clients, the benchmark log, the decisions taken and what to do next. |
| [Sync architecture](sync-architecture.md) | The modules, the loop's contract and the fifteen rules a change to sync, storage or the wire is reviewed against, with where the code departs from them. |

## Proposals

| Page | Status |
|---|---|
| [Deferred execution](weight-first-acquisition.md) | Implemented: the rule is spec §9.9, the mechanism is in [Body acquisition](block-fetching.md). Kept for the reasons and invariants. |

## Status values

| Status | Meaning |
|---|---|
| Current description | Describes the code as it stands. If it disagrees with the code, the page is wrong. |
| Decision record | Records a decision and its reasons. It is kept as written, and says which parts are in effect. |
| Proposal, implemented | Written before the work. It names where the result lives now. |
| Superseded | Replaced; it names the page that replaced it. |
