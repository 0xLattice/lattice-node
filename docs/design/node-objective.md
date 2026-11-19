# What the node is for, and what we measure

> **Status: draft for the owner.** Targets marked **Owner to set** need a
> number. Everything else records a decision already made.

The [sync architecture](sync-architecture.md) says how the node is built,
and [the node as built](node-architecture.md) what it is today. This page
says what it is for: the outcomes that matter, how each is measured, the
target, and what is known today. A change names the outcome it serves and
shows its effect on that row; work on a target stops when it is met.

## Purpose

A Lattice node follows every chain it hosts to the network's heaviest
chain, executes it, and serves what it holds to peers, miners, operators and
readers. The network's chain is the truth; a node holds a checked view of it.

Lattice is a hierarchy of chains, not one chain
([specification](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/spec.md) §1):
each child is secured by work it inherits from its parent, keeps its own
fork choice, and is hosted only by the nodes that opt into it
([philosophy](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/philosophy.md)).
So most outcomes below are measured **per chain path**: a node can be at the
tip of Nexus while a child three levels down has stopped.

## Outcomes, in order

When two conflict, the earlier one wins.

1. **Agreement.** The node reaches the same verdicts and tips as the
   protocol's rules, and keeps the transfer protocol's guarantees: no value
   created, no double withdrawal, no forged parent state (§8.3).
2. **Liveness at every depth.** Every hosted chain stays at the network's
   heaviest tip, and a node that falls behind catches up. Unavailable is never
   invalid; every wait has a reason and a wake. A stall is a bug.
3. **Security of each chain.** Blocks reach the network fast enough that
   few go stale, and each child keeps the share of parent work its security
   rests on ([merged-mining security](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/economics/merged-mining-security.md)).
4. **Promises kept.** What the node tells an operator or a miner it has kept
   outlives a crash and a power loss: an acknowledged transaction, a pin, the
   configuration, a block it said it accepted.
5. **Compatibility.** This version and the previous one stay on one network:
   wire changes are additions, and older peers are still served. Storage may
   change; a node the team runs may be wiped and synced again.
6. **Cost to verify.** Running a node, and hosting one more chain, stays cheap
   enough that many can: CPU, memory, disk, bandwidth. Deeper paths cost
   more by design; whoever opts in pays.
7. **Cross-chain transfers complete.** A deposit, its receipt and its
   withdrawal go through, in a time a user can plan around.
8. **Content stays available.** What a hosted chain needs can be had from its
   hosts.
9. **Mining is served promptly.** Templates and submitted work are answered
   fast, and little work is spent on stale templates.

Sync throughput is not an outcome. It matters only through time to tip
(outcome 2) and is capped per chain by the protocol.

## Measures and targets

Measured on Linux, as the nodes run. "Network" rows need observations of the
live network; "node" rows come from a node's own `/status` and metrics, or
from the benchmark (`Benchmarks/sync`).

| Outcome | Measure | Where from | Target | Today |
|---|---|---|---|---|
| 1 Agreement | Divergences when replaying a real chain, in mixed-version runs, and in the simulator | tests, two-version runs, simulator | Zero | Zero in CI; no replay of a real chain |
| 2 Liveness | Blocks and seconds behind the heaviest known tip, per chain path, as a distribution | node | **Owner to set** (for example, under 2 blocks 99% of the time) | Not reported (see below) |
| 2 Liveness | Stalls: a chain path not advancing while a heavier tip is known, for longer than a threshold | node | Zero | A production node stopped at height 3,920, unexplained |
| 2 Liveness | Time to tip from empty, and from a restart, per chain path | benchmark, node | **Owner to set** | Benchmark: 9,086 blocks over four chains in about 74 s with one worker on a 4-CPU runner |
| 3 Security | Time for a block to reach most hosts, per chain | network | **Owner to set** | Not measured |
| 3 Security | Share of blocks that go stale, per chain | network | **Owner to set** | Not measured |
| 3 Security | For each child, the share of parent hash rate whose templates commit it | network | **Owner to set** | Not measured |
| 4 Promises | Acknowledged transactions or accepted blocks lost after a crash or power loss | tests | Zero | Zero in tests |
| 5 Compatibility | Partitions or refused messages between this version and the previous | two-version runs | Zero | Zero in CI |
| 6 Cost | CPU, peak memory, disk kept, disk written, bandwidth, for the root alone and per extra chain | benchmark, node | **Owner to set** (the root on one CPU) | About 4.4 ms CPU per block, 190 MiB, 90 MB kept, 2.9 GB written per benchmark sync; per-chain cost not measured |
| 7 Transfers | Time from deposit to withdrawal on a parent–child pair; share that complete | network, tests | **Owner to set** | Not measured |
| 8 Availability | Share of content requests served; how long a body stays unavailable; hosts per chain | node, network | **Owner to set** | Not measured |
| 9 Mining | Time to answer a template request and a submission; share of work on stale templates | node | **Owner to set** | Not measured |

**What to instrument first.** Liveness per chain path (outcome 2) is the
outcome that is failing and the one a node can report about itself:
`/status` reports, for each chain path, how far it is behind the heaviest
tip it knows and how long since its acted-on tip last moved. Stale rate and
each child's share of hash rate (outcome 3) are next: they are the inputs of
Lattice's own security model, and nobody observes them.

## How a change is judged

- It names the outcome it serves and its effect on that row, measured, or
  says why it cannot be measured yet.
- It does not make an earlier outcome worse to improve a later one.
- If its target is met, it does not land unless the owner raised the target.
- It reports what it adds: lines, new components, and every rule a caller
  must keep. A component with no conventional equivalent says so
  ([the node compared](node-architecture-compared.md)).

## Durability

Writes are atomic and ordered; a restart resumes from a consistent earlier
state. Chain data can be had again from the network, so the node makes no
promise about it beyond outcome 4.

## Non-goals

- Changing consensus, or anything hashed.
- Light nodes, for now. The design keeps a light role; it is built later.
- A scheduler of the node's own.
- Extra caution for a chain this node alone hosts, beyond outcome 4.
- Speed past the targets.
- Resource limits on WASM policy modules.
