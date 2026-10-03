# Recursive commitments, independent levels

The canonical consensus rationale lives in Lattice's
[philosophy](https://github.com/adalinxx/Lattice/blob/43.1.0/docs/philosophy.md)
and [foundational architecture](https://github.com/adalinxx/Lattice/blob/43.1.0/docs/foundational-architecture.md).
This page records the node consequence.

The hierarchy is recursive data hosted by one tree runtime. A mined Nexus root
may commit a child candidate that commits another child candidate. One process
hosts every selected level and its ancestry, while each level validates its own
blocks and chooses its own canonical projection.

That gives the node four rules:

1. Every public chain identity is an absolute Nexus-inclusive path.
2. Cross-chain facts pass in-process between co-hosted parent and child levels;
   arbitrary peers provide availability, not a parent verdict.
3. Lattice validates one sparse root-to-candidate route and updates only the
   accepted graph for that level.
4. A child's directory proof derives its physical work, and parent descendants
   credit the carrier's run once under spec §9.10. Parent canonicity never
   commands child fork choice.

The compact model is: **recursive commitments, co-hosted independent
decisions**. See [chain addressing](chain-addressing.md) and the
[process trust model](process-trust-model.md).
