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

Two distinct causes deserve separation. Sibling *production* is driven by
block interval versus propagation-and-adoption latency; retention does not
cause it and eviction will not reduce it. What retention causes is sibling
*perpetuation*: everything ever minted is redistributed to and re-ground by
every node forever, so sync, cold boot, and mining cadence degrade with the
total junk ever created rather than with the chain. This design addresses
perpetuation only.

## Concept

**The operator's eviction choice is that node's finality.** There is no
protocol finality and no network constant — consensus remains pure heaviest
selection, and exported work can always return. Each operator instead chooses
how much losing-fork state their node retains, and that choice bounds — for
that node only — how *expensively* it follows a deep reorg, never *whether*
it will:

- Within the operator's retention horizon, competing forks are held locally
  and fork choice switches between them freely.
- Below the horizon, losing forks are evicted. The node has de facto
  finalized its own view to that depth in the pruning-node sense: it is not
  a guarantee about outcomes, only a bound on what the node keeps on hand to
  reverse cheaply. No external consumer (explorer, replica, wallet) may treat
  any node's horizon as a confirmation depth.
- A deeper reorg remains protocol-legal and followable: the heavier branch
  re-enters through ordinary verified acquisition from any peer that kept it.
  Eviction removes willingness to store, never validity. Eviction is never
  rejection.

Finality therefore emerges per-node from resource policy, the same way it
emerges for a Bitcoin operator who prunes: the network's rules never finalize
anything, but each participant decides how much history they are prepared to
re-examine.

### Eviction is weight-preserving

Fork choice weighs whole subtrees, so a losing sibling is not weight-neutral:
its work contributes to every ancestor's total. If eviction silently removed
weight the node had already counted, nodes would compute different heaviest
branches purely as a function of their retention policy, and the
equal-work-holds-incumbent rule would make that split sticky — the network
would partition along retention class with no attacker and no protocol
change. Therefore:

- **Eviction discards stored bytes and service willingness, never verified
  work facts or graph edges the node has already counted.** A node's fork
  choice must be identical to that of a node which retained everything it
  has ever verified.
- The effect of an eviction is immediate and identical before and after a
  restart; no node's head may change across a restart without new facts.
- Retention changes what a node stores and serves, never what it produces:
  a miner-serving node templates on the same head regardless of its horizon.

### The adversary must not set the horizon

Losing-fork volume is produced by whoever finds it cheapest to produce, so a
budget filled in arrival order collapses the horizon exactly when churn is
highest. Eviction priority is therefore ordered by distance from the current
head: the competing fringe nearest the head is the last thing released, and
no remote party can shrink another node's effective horizon by producing
volume. A branch just re-acquired is not immediately re-evictable — the
success metric is net exchanged volume, not retained bytes; an eviction
policy that induces evict/re-acquire thrash has failed even if the disk
stays small.

### Cross-chain obligations are not junk

A chain's retention policy governs only state no other chain has committed
to. Child blocks bind themselves to parent facts — inherited-weight evidence,
and the carrier's pre-state, where the carrier may be a *non-canonical*
parent block (parent canonicity alone can never change child validity). A
parent that evicted those facts as "losing-fork junk" would re-introduce
canonicity-dependence through availability. Evidence and carrier pre-state
that a tracked child has bound itself to are child-chain obligations,
retained independently of the parent's own fork choice. This means a
meaningful fraction of the parent evidence archive is load-bearing for
someone else and is not reclaimable by this design.

### You serve what you keep

Served surfaces — accepted-leaf pages, the portable-attachment index, content
exchange — advertise the operator's retained set, nothing more. An archive
node that keeps everything serves everything; a lean node serves the
canonical chain plus its retained fringe. Availability, like finality, is
operator choice; a fork survives network-wide exactly as long as someone
chooses to keep it, which is the only durability a permissionless system can
honestly offer. Two consequences must be stated:

- **Absence is never evidence of nonexistence, and by itself never lowers a
  peer's standing.** A pruned peer and a withholding peer are
  wire-indistinguishable; the only valid conclusion from a miss is "ask
  elsewhere". (This gives real withholders cover; the design accepts that
  because availability was never attestable in the first place.)
- A query for evicted data answers "not retained here" — it never errors and
  never asserts nonexistence.

Operator retention governs *non-canonical* state. The canonical
genesis-to-tip closure is a distinct axis: fresh nodes re-execute from
genesis by design, so joinability depends on canonical closure remaining
available somewhere, and no local knob decides that for the network.

## Companion direction (separate design): declining work cheaply

The bounded admission lanes are only relieved if a node can also decline
acquiring junk, not merely evict it after paying full admission cost.
Advertisements could carry untrusted hints (height, claimed weight) letting
a receiver deprioritize candidates unlikely to alter its fork choice. This
is deliberately *not* part of the present concept, because it is the one
piece that can permanently change what a node believes: an evicting node
still counts all work it verified, but a declining node never learns the
declined work at all. Any future design must hold these boundaries:

- No advertisement can prove a candidate irrelevant — "childless sibling" is
  a claim about an unseen future, exactly what a withholding miner presents.
  There is no provably-unhelpful classifier.
- Declining is deprioritization, never a terminal decision: a declined CID
  stays re-announceable and re-acquirable, never absorbed into a seen set.
- The dangerous lie is *under*-claiming: over-claiming wastes only the work
  a receiver volunteers, but advertising a real heavy block as light costs
  the liar nothing and suppresses acquisition everywhere, unverified —
  so no single announcer's claim may drive a decline.
- Hints are optional and advisory; a node that emits none and a node that
  ignores all of them are both fully conforming peers.

## Boundaries

- Consensus (Lattice) is untouched: no fork-depth rules, no finality
  thresholds, no changes to weight comparison or admission validity — and,
  via weight-preservation above, no retention setting may alter the head any
  node computes.
- Retention knobs live in node configuration with sane defaults, per chain,
  like every other operator budget. No knob is ever load-bearing for
  correctness — a node with any setting, including "keep everything", is a
  fully conforming peer.
- The recovery invariant is absolute: every eviction must leave no index,
  scan cursor, or advertisement promising the evicted state (unit of
  eviction = unit of reference), and re-acquisition of an evicted branch
  must work end-to-end. A crash during eviction may leave unreferenced
  bytes, never a reference promising bytes that are gone.
