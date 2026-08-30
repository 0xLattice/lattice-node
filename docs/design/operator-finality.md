# Operator-Level Finality

## Problem

A Lattice node never forgets. Three surfaces accumulate losing-fork state
forever:

- **The accepted graph.** Every valid block a node admits — canonical or a
  losing sibling — stays in its accepted set permanently, and accepted-leaf
  pages serve the whole set to every peer. A live testnet child measured 74%
  losing siblings: roughly three units of junk exchanged and re-validated for
  every unit of chain.
- **The parent's evidence archive.** Every child block a parent ever carried
  keeps its proof and edge rows durably, and the portable-attachment index
  re-advertises all of it to every syncing child, forever (measured: 13.5
  evidence rows per canonical child block).
- **Acquisition effort.** A bare advertised CID gives a node no way to decline
  work, so every hoarded sibling costs every peer a content fetch, an evidence
  solicitation, and a full admission attempt — competing for the same bounded
  lanes that deliver live blocks.

The result is a self-reinforcing churn ecology: hoarded junk starves live
delivery, stalled tips mint more siblings, and every node re-grinds every
other node's archive. Sync, cold boot, and mining cadence all degrade with
the total junk ever created rather than with the chain.

## Concept

**The operator's eviction choice is that node's finality.** There is no
protocol finality and no network constant — consensus remains pure heaviest
selection, and exported work can always return. Each operator instead chooses
how much losing-fork state their node retains, and that choice bounds, for
that node only, how cheaply it can follow a deep reorg:

- Within the operator's retention horizon, competing forks are held locally
  and fork choice switches between them freely.
- Below the horizon, losing forks are evicted — index rows, content, and pins
  together, atomically, as one unit of reference. The node has de facto
  finalized its own view to that depth.
- A deeper reorg remains protocol-legal and followable: the heavier branch
  re-enters through ordinary verified acquisition from any peer that kept it.
  Eviction removes willingness to store, never validity. Eviction is never
  rejection.

Finality therefore emerges per-node from resource policy, the same way it
emerges for a Bitcoin operator who prunes: the network's rules never finalize
anything, but each participant decides how much history they are prepared to
re-examine.

### You serve what you keep

Served surfaces — accepted-leaf pages, the portable-attachment index, content
exchange — advertise the operator's retained set, nothing more. An archive
node that keeps everything serves everything; a lean node serves the canonical
chain plus its retained fringe. Availability, like finality, is operator
choice; a fork survives network-wide exactly as long as someone chooses to
keep it, which is the only durability a permissionless system can honestly
offer.

### Declining work cheaply

Retention policy also governs acquisition: a node that would evict a block on
arrival should be able to decline acquiring it. Advertisements may carry
untrusted hints (height, claimed weight) that let a receiver skip candidates
that cannot alter its fork choice — verified after acquisition whenever the
node does engage, so a lying hint can waste at most the work the receiver
volunteered. Under the equal-work-holds-incumbent rule, a same-height sibling
of the incumbent with no descendants is the canonical example of provably
unhelpful work.

## Boundaries

- Consensus (Lattice) is untouched: no fork-depth rules, no finality
  thresholds, no changes to weight comparison or admission validity.
- Retention knobs live in node configuration with sane defaults, per chain,
  like every other operator budget. No knob is ever load-bearing for
  correctness — a node with any setting, including "keep everything", is a
  fully conforming peer.
- The recovery invariant is absolute: every eviction must leave no index,
  scan cursor, or advertisement promising the evicted state (unit of eviction
  = unit of reference), and re-acquisition of an evicted branch must work
  end-to-end.
