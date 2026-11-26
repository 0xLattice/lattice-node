# Process trust model

> **Status:** Current description.
> **Purpose:** What a hosted chain level trusts, and what it does not: its
> co-hosted parent level, network peers, and content.

## One process, one chain tree

One `lattice-node` process hosts a Nexus-rooted tree: the Nexus level and
each operator-selected child path, always with its ancestry. The levels are
independent consensus state machines behind one synchronous `NodeCore.step`.
They share one process identity, Ivy overlay, fact journal and RPC surface;
the process never spawns a child daemon.

```text
Nexus level ── in-process parent facts ──▶ Nexus/Payments level
```

The parent owns only its own accepted graph. The child owns only its own
validation, work and fork choice. Sharing a host does not let a parent
choose a child tip or let a child mutate parent state.

## What a child takes from its parent level

A child receives two kinds of hierarchy input from its co-hosted parent:

- forward state continuity from the parent's validated executed graph; and
- attributed runs for the child's directory under Lattice spec §9.10.

These are plain in-process reads, not signed or portable certificates.
Because the host includes every ancestor, it validates the complete lineage
recursively to Nexus and never asks a remote process for a parent verdict.

The authority is intentionally narrow: a child trusts the parent level's
local validated history as it trusts the binary running its own level. A bug
in parent validation can therefore affect descendants, but no remote parent
can return a different answer to different child nodes.

No parent tip, weight snapshot or child topology is projected across the
boundary. How the child checks its parent state and credits work is in
[Proof-derived child work](proof-derived-work.md).

### Child genesis

A child genesis needs no deployment verdict. The host builds it from the
configured child spec and the carrier's entering state. It becomes an
accepted root only through the same mined directory proof, execution and
parent-state anchor used for any child block.

## What peers can and cannot supply

Arbitrary peers may supply content-addressed Volumes. CIDs establish byte
identity; Lattice validation establishes block, state-transition, directory
and proof-of-work validity. A peer cannot turn content availability into a
parent-state verdict.

| Input | From | Trusted for |
|---|---|---|
| Content-addressed Volumes | Any peer | Nothing beyond the bytes matching their CID |
| Headers and child proofs | Any peer | Nothing until verified ([Peer protocol](../protocol.md#header-and-proof-sync)) |
| Parent-state continuity | The co-hosted parent level only | That the parent's executed-from-genesis set produced the state ([Parent-state continuity](proof-derived-work.md#parent-state-continuity)) |
| Attributed runs | The co-hosted parent level only | The reported quantity; the child binds the report and derives the credit itself |

A weighed but unexecuted parent claim issues no fact. Parent canonicity
does not alter a state that was actually produced. Grandparent validity
follows recursively because a parent block executes only after that level
passes the same rule against its own parent.

## One network plane

The process has one Ivy instance. A compatible peer session serves every
path both hosts, and sync messages carry their absolute path. Parent facts,
attributed runs, merged-mining inputs and a locally mined grind's carried
blocks pass directly between levels and never become a second network
protocol.

Provider records keyed by each hosted child chain's path advertise
availability on that shared overlay
([Finding the hosts of a chain](../protocol.md#finding-the-hosts-of-a-chain)).
Nexus has none: every node hosts it. The records grant neither consensus
authority nor a special parent/child network role.

## Durability and operation

One `state.db` transaction records every level touched by a `NodeBatch`,
along with their stream cursors, incomplete header boundaries and child
proofs. Each hosted chain's Volume store under `volumes/` retains its
content. Recovery replays path-keyed immutable facts and recomputes fork
choice; it does not restore remote certificates.

Keep the one process identity stable and back it up separately from the
wipeable tree store. There are no per-level identities or overlays, one
`state.db` serves the whole tree, and there are no storage migrations.
