# Recursive commitments, independent processes

The canonical design rationale is in Lattice's
[philosophy](https://github.com/adalinxx/Lattice/blob/35.0.1/docs/philosophy.md)
and [foundational architecture](https://github.com/adalinxx/Lattice/blob/35.0.1/docs/foundational-architecture.md).
This page records only the consequences for `lattice-node`.

The hierarchy is recursive data, not a recursive runtime. A mined root may
commit a child candidate that commits another child candidate, but one process
validates and chooses exactly one absolute path. A process never embeds a child
validator or runs fork choice for a descendant.

That gives the node four rules:

1. Every public chain identity is an absolute Nexus-inclusive path.
2. Cross-chain evidence travels only between authenticated immediate-parent and
   direct-child processes; a provider supplies availability, not validity.
3. Lattice validates one sparse root-to-candidate route and updates only the
   accepted forest for that process's path.
4. A child's directory proof derives its own physical work, and the parent
   block that commits it — by parent pointer — credits its run of indirectly
   committing descendants to that child block, once (spec §9.10); the parent's
   canonical tip is never a command to change child state or fork choice.

The compact model is: **recursive commitments, independent decisions**. See
[chain addressing](chain-addressing.md) and the
[process trust model](process-trust-model.md) for the node interfaces that
preserve it.
