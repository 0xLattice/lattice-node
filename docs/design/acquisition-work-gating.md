# Acquisition Work Gating (Prove Work Before Keeping It)

## Model

Any peer may lie, withhold, stall, or serve valid but irrelevant data. There is
no honest-majority assumption among peers: security comes from checking every
item and from work that can be compared objectively. Proof of work certifies
itself. A root hash that beats a target proves the work was spent, whatever
else is true of the block. Anyone can mint a PoW-valid block at an easy target,
and relaying one is never a fault
([weight-first-acquisition](weight-first-acquisition.md)). This node verifies
everything itself. It has no assume-valid shortcut, no checkpoint and no
built-in minimum chain work. It weighs a block when it possesses the block,
before executing it.

## Problem

Deferred execution removed the biggest cost of a block that does not matter:
losing branches are weighed but never executed. It did not change what a node
spends to *weigh* a block, and weighing is now the step an adversary can buy
cheaply. Nothing in the acquisition pipeline ties what a node spends on an
offer to how much work stands behind it.

### What an offer costs

- **A probe.** A node cannot see an offer's work until it holds the offer's
  root node, so it must fetch content before it knows anything.
- **Structural verification.** The node checks proof of work, then header
  linkage: it resolves the parent and spec, and checks the timestamp and
  target schedule across the retarget window.
- **Permanent storage.** A weighed block's block boundary and consensus facts
  are staged durably. Lattice "never prunes accepted graph or verified
  local-work facts" (spec §12.5, invariant 9; §9.7), and recovery replays those
  facts at every restart (§9.8). A kept block costs storage forever and replay
  time on every boot.
- **The admission lane.** Candidates are admitted one at a time
  (`CandidateAcquirer.next`), so a slot spent on junk is a slot the live edge
  does not get.
- **A proof round trip for child blocks.** Weighing a child block needs its
  securing-work proof, which is requested from the supplier and requested
  again while it is missing.

### Where cheap work lives

A block's target is bound to the schedule of its own ancestry
(`B.target <= parent.nextTarget`, spec §5.5), so where a branch attaches sets
the cost of extending it. By convention Nexus genesis commits the maximum
target (§5.5; `NexusGenesis`), which every hash satisfies. A branch attached at
or near genesis, or after any stretch where the schedule relaxed, can be
extended for a fraction of the cost of the chain it claims to rival. The honest
chain's difficulty protects the honest chain's tip. It does nothing to make a
deep side branch expensive.

### Exposure in the current pipeline

- **Every unknown announced CID is acquired.** The block-announcement case of
  `NodeNetworkRuntime.handleOverlay` seeds `CandidateAcquirer`, on the weighed
  tier, with every announced block the node does not hold. The acquirer's
  inputs are a CID and a provider. Work is not among them and cannot be, because
  the root has not been fetched yet.
- **A claimed height decides what gets synced.** An announcement's height is
  an unverified claim. A claim more than `rangeSyncDepthThreshold` above the
  node's acquired height starts range sync with that peer, and re-entry picks
  the tallest recorded claim (`maybeRestartRangeSync`). The single range-sync
  slot then pages that peer's main chain forward from the negotiated common
  ancestor and queues every page for weighed admission. Progress is measured by
  canonical height. A low-work branch never becomes canonical, so the slot is
  freed only after `rangeSyncMaxRedrives` windows without progress, and
  announcing again takes it back. Height misleads in the honest case too. A
  heavier chain can be shorter, and then it never triggers range sync; the node
  reaches it only through the predecessor walk.
- **The offering peer chooses how deep the node descends.** A frontier page
  seeds every unknown leaf. Each candidate whose parent is missing seeds that
  parent with the descendant's providers (`CandidateAcquirer.complete`,
  `.predecessor`), so the bytes a peer serves decide how deep the walk goes.
  The walk is limited by a fixed budget of parked candidates, and when the
  budget is full the oldest park is evicted (`evictOldestRetained`). A flood of
  fresh parks pushes out older ones, so the adversary sets the horizon.
- **Weighed admission compares nothing.** In weighed mode,
  `ChainLocalAdmission.prepare` verifies proof of work (or the child
  securing-work proof) and header linkage. It then stages the block boundary
  and the work fact. No input compares the candidate's work with anything the
  node already holds.
- **Resource budgets limit size, not work.** `NodeResourcePolicy` limits what a
  single candidate may cost: spec bytes, witness bytes, Volume counts and member
  counts. The acquirer's ready and park capacities limit memory. None of them
  asks how much work must stand behind what the node keeps.

A cheap branch never becomes canonical and is never executed, so the
invariants hold. What it buys is bandwidth, a share of the single admission
lane, and permanent storage plus replay on every boot. Its price is set by the
easiest schedule the attacker can attach to, not by the chain the node follows.

### Prior art: headers pre-sync

Bitcoin Core faced the same kind of attack: low-difficulty header chains forked
from early history, filling memory and disk. Its answer is headers pre-sync.
When headers connect to a chain with less work than an anti-DoS threshold, the
node validates them without storing them and keeps a compact commitment to what
it saw. Only after the peer's chain has proven enough cumulative work does the
node download those headers again, check them against its commitments, and
store them. The node commits to proving the work before storing a chain; it
does not refuse the chain. The threshold is the greater of a minimum chain work
built into each release and the node's own tip work minus roughly a day of
blocks at the tip's difficulty.

The two halves of that threshold transfer differently. The relative half, which
is measured against what the node already holds, is a node-local judgment and
fits here. The absolute half, a minimum-work constant shipped with each
release, is exactly the kind of central constant this project does not have.
The mechanics differ as well. Fork choice here weighs subtrees, not a single
chain, and content addressing already commits a leaf to its whole ancestry, so
no separate commitment scheme is needed.

## Constraints

**Validity and fork choice are untouchable.** The node boundary says so
directly: "No node-local work floor exists: any filter on work that can reach
fork choice would be consensus-relevant, so the chain's own target is the only
work gate" ([protocol.md](../protocol.md)). The specification allows one kind
of local preference: a node "may apply its own root-work floor before spending
resources on acquisition, but that is a non-punitive local preference and never
changes validity" (Lattice spec §5.4). A gate may control what a node spends
resources on. It may never decide whether a block is valid, how much it weighs,
or which head the node selects. The chain's target stays the only gate on
validity and weight. This document is about a gate on spending.

**Operator choice, not protocol constants.** "Storage, transport,
bootstrap-spec, and parent-witness ceilings are node-local acquisition policy,
not common consensus constants" (spec §3.5), and "operators may apply stricter
local acquisition policy" (Lattice philosophy, design principle 5). Every bar,
margin and budget in this document is an operator setting with a sensible
default, and a node that gates nothing is a fully conforming peer.

**Availability is never invalidity.** "Failure to obtain an input is never a
verdict" ([weight-first-acquisition](weight-first-acquisition.md)), and
"Absence is never evidence of nonexistence, and by itself never lowers a peer's
standing" ([operator-finality](operator-finality.md)). Going over a local
ceiling already "declines or defers acquisition without proving the candidate
invalid or punishing its advertiser" ([protocol.md](../protocol.md)). Declining
to keep an offer is the same kind of decision.

**No stranding.** A node must not end up on a lower-work chain because it
declined to acquire the heavier one. This constraint shapes the whole concept.
An evicting node keeps counting what it verified, but "a declining node never
learns the declined work at all" ([operator-finality](operator-finality.md)).
And under subtree weighting, "subtree aggregation lets many
individually-immaterial blocks be collectively decisive"
([weight-first-acquisition](weight-first-acquisition.md)). No filter applied to
blocks one at a time can be shown to be harmless. Only a rule about what an
offer could change can.

## Concept

**A node proves an offer's work before it pays to keep it. The amount of work
it requires is set by what the offer would have to beat, never by a per-block
floor.**

Acquisition spends in three steps, and only the last is permanent:

- **Probe.** The node obtains an offered root and verifies its proof of work.
  This step cannot be avoided, because no gate can act on work it has not seen.
  The probe is the price of learning an offer's work at all. Fabricated or
  mismatched bytes can still be attributed to their sender, as today.
- **Tally.** While an offer has not yet been shown to matter, the node verifies
  the work of each root in the offer and the parent links that join them, and
  adds up the offer's proven work. It uses the consensus measure, so a grind
  counts once however often it is replayed (spec §9.1). Nothing is staged,
  stored durably, entered into the consensus graph or relayed. A tally's
  footprint does not grow with the length of the offer. Content addressing makes
  a leaf CID a commitment to its whole ancestry, so when the node later
  acquires the offer it gets exactly the bytes it tallied, or can tell that it
  did not.
- **Keep.** Once an offer's proven work reaches the bar, it goes through
  ordinary acquisition unchanged: weighed when possessed, stored durably,
  counted, and executed if it becomes load-bearing. If the offering peer
  withholds the offer at this point, that is an availability gap like any
  other.

### The bar

An offer attaches to the node's graph at a block the node holds. Its weight
then enters every fork comparison on the path from that block back to genesis,
and it also competes with the attachment block's existing children. The
**bar** is the smallest margin among the comparisons that the offer's side does
not already win, which is the least work that could change the outcome of any
of them. When the offer attaches to the canonical chain, the bar is simply the
incumbent's work above the attachment point: Bitcoin's relative threshold,
restated for subtree weight. When it attaches to a losing branch, the bar is
the margin at the deepest fork that branch loses. That margin is smaller, as it
should be.

The rule is the pivotality rule from
[weight-first-acquisition](weight-first-acquisition.md), applied to unkept work
instead of unvalidated work. **An offer may stay unkept only while the total
unkept work that would enter each comparison is strictly less than that
comparison's margin. Where it is not, offers are kept until it is.** The bar
limits the total, not each offer. Honest weight that arrives as many small
offers, such as siblings from many miners, is kept as soon as together it could
matter. An attacker gains nothing by splitting a branch into small offers: what
gets kept still carries at least the bar in proven work. An exact tie can
change a comparison, so it is never "strictly less" and is always kept.

Every uncertainty lowers the bar:

- **Only validated weight raises it.** When computing a comparison's margin,
  unvalidated weight on the side currently winning is left out. Otherwise a
  miner could publish a heavy branch, withhold its bodies, and raise the bar
  for every honest alternative, keeping out a lighter valid branch the node
  would otherwise hold. Weight on the offer's own side counts whether or not it
  is validated.
- **Exclusion recomputes it.** When a subtree is proven invalid and excluded,
  the margins it supported shrink and every tally is judged again.
- **Narrowing margins let tallies in.** The bar is not fixed when an offer
  arrives. When a comparison tightens toward a tie, offers that were below its
  old margin cross the new one and are kept.
- **An operator margin lowers it further.** Offers within that much work of
  mattering are kept outright. The default is set so the live edge (successors,
  siblings, short forks) is never tallied.
- **Enough work needs no attachment point.** An offer whose proven work already
  exceeds all of the node's validated work can be kept before the node finds
  where it attaches.

So the bar only takes effect where work is cheap compared with what an offer
would have to beat, which in practice means deep attachments to easy schedules.

### Deferral, never refusal

An offer below the bar is not refused. It is not recorded as seen, not marked
invalid, and not held against the peer that offered it. It can still be offered
and acquired again by CID.

Tallying has its own operator budget, per peer and in total. When the budget is
full, the node first releases the tally furthest from its bar, never the one
closest to mattering, so flooding the node with cheap offers cannot push out the
offer it most needs. A released tally is treated as if the offer had never been
received: it comes back by being offered again.

Where an offer attaches determines when the bar is known. Forward acquisition
from a negotiated common ancestor ([bulk-sync-stream](bulk-sync-stream.md))
knows the attachment point before the first page, so the bar is known from the
start. A top-down predecessor walk only finds the attachment point at the
bottom, so each step of its descent costs a probe and draws on the tally
budget. Beyond the live edge, the node approaches the offer forward instead.

Claims carried in announcements (height today, any future work hint) may decide
which offers are tallied first. They never decide what is kept. This preserves
the boundaries [operator-finality](operator-finality.md) sets for any design
that declines work cheaply. No advertisement can prove an offer irrelevant.
Declining only lowers an offer's priority and is never final. An honest heavy
offer that under-claims is still tallied on its proven work. Hints are
advisory.

## Stranding

A gate strands a node when it declines the chain that is actually heaviest.
These are the ways that can happen, and how the concept handles each:

- **A per-block floor.** Declining every block whose own work is below a floor
  strands a node whenever the heaviest chain is made of such blocks. Examples: a
  fresh chain at the genesis target, a chain whose difficulty fell after
  hashrate left, a child chain whose securing work is legitimately small, or
  any branch that is heaviest only because many light blocks add up. A node with
  such a floor follows a lighter chain of blocks above the floor, which means
  the floor has reached fork choice. The specification allows a root-work floor
  as a local preference (§5.4). In this design a block's own work may only order
  acquisition, never decline it.
- **A bar measured against the wrong thing.** The bar comes from the node's own
  validated graph. A chain heavier than the one the node follows has, by
  definition, more work above the fork point than the incumbent, so its
  combined tally always crosses the bar. A node sitting on a light chain has a
  low bar and readily admits heavier chains. The failure only appears if work
  the node cannot act on is allowed to raise the bar, which is why unvalidated
  incumbent weight is left out.
- **A tally that cannot finish.** A bar the heaviest chain would cross is
  useless if the tally gives up first. That is why a tally's footprint does not
  grow with the offer's length, and why budget pressure releases the tallies
  furthest from mattering first. Width is the remaining limit. Fork choice can
  make a subtree heaviest through its side branches, and a tally that sees only
  a main chain undercounts it. Undercounting only delays keeping, and an honest
  subtree's width follows its real fork rate, but the budget must be large
  enough to fit that width.
- **Choosing by claim.** Picking whom to sync from by claimed height prefers a
  tall cheap branch over a shorter, heavier one. Claims only order tallies and
  never decide what is kept, so a truthful heavier offer is kept on its proof,
  whatever anyone announced.
- **A released tally that later matters.** An offer can be below every margin
  when its tally is released and still become decisive if a comparison later
  narrows toward a tie. Until someone offers it again, the node's head differs
  from that of a node that kept it. The exposure is the same as for any branch
  the node never received, and the release order places it on the work furthest
  from any margin. It is still the one way the gate can affect a head, so it
  must stay rare.
- **A fresh node.** A node at genesis has a bar near zero and keeps whatever it
  is offered first, cheap branches included. It is not stranded, because the
  honest chain is heavier and crosses the bar. But it has paid for the cheap
  branch and keeps paying on every boot. Bitcoin closes this gap with a built-in
  minimum chain work. Here that could only be the operator's own choice, and a
  minimum set above the real chain's work would strand the node. Such a minimum
  must therefore defer and report, never decline.

## Not the miners' minimum work filter

A separate decision has miners apply a minimum work filter. A miner voluntarily
mines at a target harder than scheduled, so that a fresh chain, which starts at
the easiest target, does not race through its first blocks in seconds. The
specification allows this directly: "A block may meet that schedule or
voluntarily exceed it — as hard or harder, never easier", and a new chain
"self-calibrates as early miners voluntarily mine harder" (§5.5).

The two mechanisms act on different sides:

- **The miner filter acts on production.** It governs what a miner creates. It
  binds only the miners who choose it, changes no validity rule, and constrains
  nobody else. An attacker does not run it.
- **The acquisition gate acts on spending.** It governs what a node spends to
  fetch and keep what others created. It binds only the node that applies it,
  and it changes no validity rule either.

They interact in four ways:

- **Neither is an input to the other.** In particular, the gate must not use the
  miners' target as its bar. "Decline blocks easier than honest miners produce"
  is a per-block floor. It strands every node on a fresh chain before the
  filter takes effect and whenever miners choose differently, and blocks at the
  scheduled target are valid and may make up the heaviest chain.
- **The filter does not close the exposure.** A branch's schedule comes from its
  own ancestry, so a branch attached at genesis starts at the maximum target no
  matter what honest miners do.
- **The filter strengthens the gate.** Harder honest blocks put more incumbent
  work above any deep attachment point, so the bar a cheap deep branch must
  reach rises sooner. Each block's schedule is recomputed from the block's
  actual target, so the harder schedule persists and makes blocks near the tip
  more expensive for everyone.
- **The filter makes height a worse proxy.** Blocks mined harder than scheduled
  make an honest chain shorter for the same work. Any acquisition choice based
  on height becomes easier to exploit with a tall, cheap branch, which is one
  more reason the gate orders and keeps by proven work.

## Boundaries

- **Consensus is untouched.** No validity rule, work measure, comparison,
  exclusion or tier changes. An offer below the bar is neither valid nor
  invalid. Once kept, it is admitted exactly as today.
- **Same head while tallying.** At every moment, a gating node computes the same
  head it would compute if it had kept every offer it is still tallying. That is
  the pivotality rule above, and it is what keeps the gate from reaching fork
  choice.
- **Weight preservation is unchanged.** Eviction never drops counted work
  ([operator-finality](operator-finality.md)), and the gate never counts work it
  has not kept. The two fit together: eviction decides what a node stops
  keeping, this design decides what it starts keeping, and neither changes a
  counted fact.
- **No punishment.** Nothing below the bar lowers a peer's standing. Spending
  per peer is a resource budget, not reputation. Bytes that do not match what
  was advertised can still be attributed to their sender, as today.
- **Operator settings.** The margin, the tally budgets and any minimum required
  before keeping are node configuration with sensible defaults. The default
  never tallies an honest live-edge block, and "keep everything" is a conforming
  setting.
- **The node's own blocks and parent facts are not gated.** A block this node
  produced is kept as today. Genesis and continuity facts issued by the parent
  carry no work, and the [process trust model](process-trust-model.md) governs
  them, not this gate.
- **Child chains use the same bar and measure.** A child block's weight is
  inherited securing work, so tallying it needs the securing-work proof. That
  proof is the per-sibling round trip [operator-finality](operator-finality.md)
  leaves open. Where a child node already holds the parent carriers, it can
  prove that weight without the network
  ([bulk-sync-stream](bulk-sync-stream.md)).
- **The probe is out of scope.** Offers that are not blocks at all, such as
  fabricated CIDs or roots nobody serves, carry no work for any gate to act on.
  They belong to transport and peer accountability: binding content to the
  exact announcer, and attributing deficient content.
