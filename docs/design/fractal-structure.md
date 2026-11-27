# Recursive commitments, independent levels

> **Status:** Current description.
> **Purpose:** The four rules the node follows because the chain hierarchy
> is recursive. The consensus rationale is Lattice's
> [philosophy](https://github.com/0xLattice/Lattice/blob/59.3.1/docs/philosophy.md)
> and [foundational architecture](https://github.com/0xLattice/Lattice/blob/59.3.1/docs/foundational-architecture.md).

The hierarchy is recursive data hosted by one tree runtime. A mined Nexus
root may commit a child candidate that commits another child candidate. One
process hosts every selected level and its ancestry, while each level
validates its own blocks and chooses its own canonical projection.

## The four rules

1. Every public chain identity is an absolute Nexus-inclusive path
   ([Chain addressing](chain-addressing.md)).
2. Cross-chain facts pass in-process between co-hosted parent and child
   levels; arbitrary peers provide availability, not a parent verdict
   ([Process trust model](process-trust-model.md)).
3. Lattice validates one sparse root-to-candidate route and updates only the
   accepted graph for that level.
4. A child's directory proof derives its physical work, and parent
   descendants credit the carrier's run once under spec §9.10. Parent
   canonicity never commands child fork choice
   ([Proof-derived child work](proof-derived-work.md)).

The compact model is: **recursive commitments, co-hosted independent
decisions**.
