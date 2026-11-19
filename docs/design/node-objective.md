# What the node is for, and what we optimise

> **Status: draft for the owner.** Lines marked **Owner to set** need a
> decision. Everything else records a decision already made, with where it
> came from.

The [sync architecture](sync-architecture.md) says how the node is built.
This page says what it is built for: what a change must protect, in what
order, how we know a target is met, and when to stop working on one. A
change that cannot say which objective it serves, and by how much, does not
start.

## Purpose

A Lattice node follows every chain it hosts to the network's heaviest
chain, executes it, and serves what it holds to peers, miners, operators
and readers. The network's chain is the truth; a node holds a checked view
of it ([durability](#durability)).

## Objectives, in order

When two conflict, the earlier one wins.

1. **Consensus correctness.** The node accepts exactly what the
   [protocol](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/spec.md)
   accepts and acts on the heaviest executed tip. Lattice's
   [foundational architecture](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/foundational-architecture.md)
   is normative; nothing here changes a hashed byte or a consensus decision.
2. **Liveness.** A node with one honest, reachable peer reaches that peer's
   tip on every chain it hosts, and keeps up. Unavailable is never invalid;
   every wait has a typed reason and a wake ([rules 2 and 5](sync-architecture.md#rules)).
   A node that stops advancing while blocks exist is a bug, whatever else
   it gets right.
3. **Compatibility.** Nodes of this version and the previous one stay on
   one network: wire changes are additions, and what older peers ask for
   is still served. Storage may change freely: a node the team runs may be
   wiped and synced again; no storage migrations.
4. **Promises kept.** What the node tells an operator or a miner it has
   kept outlives a crash and a power loss: an acknowledged transaction, a
   pin, the configuration, a block a miner or an author was told is
   accepted. Nothing else waits on a disk.
5. **A design a maintainer can hold in their head.** Modular, from first
   principles, and conventional in shape: where an established client
   (Bitcoin Core, geth) solves the same problem, the node does it the same
   way — the same parts, in the same order, under the same atomic
   boundary — or the design says why not. New machinery needs a measured
   reason against an objective here.
6. **Performance, to the targets below.** Not beyond them: when a target is
   met on Linux, work on it stops until the owner raises it.

## Targets

Measured on Linux, as the nodes run (a plain fsync on macOS does not reach
the device, so macOS numbers understate disk costs). The sync benchmark is
`Benchmarks/sync` (`ChildSyncBench`); a whole-node scorecard adds the rest.

| Objective | Measure | Target | Today |
|---|---|---|---|
| Liveness | A node with one honest peer reaches its tip on every hosted chain | Always; a stall is a bug with a simulator scenario | A production node has stopped at a height, not yet explained |
| Liveness | Time from a block being mined to a synced node acting on it | **Owner to set** | Not measured |
| Sync throughput | Blocks per second executed while catching up, one CPU | 50–100 | About 233 (9,086 blocks in about 39 s) after #129, as a review measured it; not measured on Linux since |
| Sync time | The benchmark's 9,086 blocks over four chains | **Owner to set**, or none beyond the throughput target | 10.4 s with three workers, natively on macOS, at 31aa0d1b |
| Start | Time from launch to serving | **Owner to set** | Not measured |
| Disk | Bytes kept, and bytes written per block, while syncing | **Owner to set** | About 80 MB kept and about 2 GB written per sync (macOS, 31aa0d1b) |
| Memory | Peak resident memory while syncing | **Owner to set**; bounded by configured limits | About 200 MiB on the benchmark |
| Mining | Time to answer a template request | **Owner to set** | Not measured |
| Reads | Time to answer an account or block read | **Owner to set** | Not measured |

## How a change is judged

- It names the objective it serves and shows the effect on that row of the
  table, on Linux, or says why it cannot be measured yet.
- It does not make an earlier objective worse to improve a later one.
- If the target it serves is met, it does not land unless the owner raised
  the target.
- It reports what it adds: lines, new components, and every new rule a
  caller must keep. A component with no conventional equivalent says so.

## Durability

Decided 2026-11-18 and amended 2026-11-19. Consistency is strict:
writes are atomic and ordered, and a restart resumes from a consistent
earlier state. Durability catches up: chain data can be fetched again, so
it does not wait on a disk. The exceptions are the promises in objective 4.

## Non-goals

- Changing consensus, or anything hashed.
- Light nodes, for now. The design keeps a light role; it is built later.
- A scheduler of the node's own (fair shares, time accounting, priorities
  to tune).
- Extra caution for a chain this node alone hosts: a miner who wants a
  block kept is answered only once it is written, and nothing more.
- Throughput past the targets.
- Resource limits on WASM policy modules.
