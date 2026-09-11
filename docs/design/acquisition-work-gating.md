# Acquisition Work Gating (Prove Work Before Keeping It)

## Model

Any peer may lie, withhold, stall, or serve valid but irrelevant data. There is
no honest-majority assumption among peers: security comes from checking every
item and from work that can be compared objectively. Proof of work certifies
itself. A root hash that beats a target proves the work was spent, whatever
else is true of the block. Anyone can mint a block that meets its own target
when that target is easy, so producing one is cheap wherever the schedule is
easy. Bytes that match their CID are never a serving fault, whatever the block
later proves to be ([weight-first-acquisition](weight-first-acquisition.md)).
This node verifies everything itself. It has no assume-valid shortcut, no
checkpoint and no built-in minimum chain work. It weighs a block when it
possesses the block, before executing it.

## Problem

Deferred execution removed the biggest cost of a block that does not matter:
losing branches are weighed but never executed. It did not change what a node
spends to *weigh* a block, and weighing is now the step an adversary can buy
cheaply. Nothing in the acquisition pipeline ties what a node spends on an
offer to how much work stands behind it.

### What an offer costs

- **A probe.** A node cannot see an offer's work until it holds the offer's
  root node, so it must fetch content before it knows anything.
- **Structural verification.** The node checks proof of work (for a child
  block, its securing-work proof), then header linkage. It resolves the parent
  and spec, and checks the version, that the spec matches the parent's, that
  the block's `prevState` equals the parent's `postState`, the height, the
  timestamp, and the target schedule across the retarget window.
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
extended for a fraction of the cost of the chain it claims to rival.

Timestamps must strictly increase and may not run ahead of real time. That
limits how *deep* a branch can grow while staying cheap, but not how *wide*.
Nor does it stop an abandoned tip from easing. With no clamp committed, the
newest interval carries the most weight in the retarget window. So one block
with a late timestamp eases the next target roughly in proportion to the gap,
about 145-fold for a year-old Nexus tip. The late block itself must still meet
the old schedule. But the gap stays in the window, and the few blocks that
follow keep easing, so the schedule can be driven to the maximum target for
roughly one block's work at the old difficulty.

The honest chain's difficulty protects the honest chain's tip. It does nothing
to make a deep side branch expensive.

A second kind of offer carries work without being a new block. One block may be
secured by many distinct grinds (§9.1), and a carrier need not be valid on its
own chain (§9.5). So securing-work evidence for a child block the node already
holds adds a new, permanent work fact. Against an old child block at an easy
target, such evidence costs almost nothing.

### Exposure in the current pipeline

- **Every announced CID is acquired.** The block-announcement case of
  `NodeNetworkRuntime.handleOverlay` seeds `CandidateAcquirer`, on the weighed
  tier, with every announced block, whether or not the node holds it (held
  blocks resolve as duplicates). The acquirer's inputs are a CID and a
  provider. Work is not among them and cannot be, because the root has not been
  fetched yet.
- **A claimed height decides what gets synced.** An announcement's height is
  an unverified claim. A claim more than `rangeSyncDepthThreshold` above the
  node's acquired height starts range sync with that peer, and re-entry picks
  the tallest recorded claim (`maybeRestartRangeSync`). The single range-sync
  slot then pages that peer's main chain forward from the negotiated common
  ancestor, and every page is stored as it arrives. Progress is measured by
  canonical height. The slot is also freed on an empty page, when there is no
  common ancestor, when the peer disconnects, or when the target is reached.
  But a peer actually serving a low-work branch never advances canonical height,
  so the slot is held until `rangeSyncMaxRedrives` windows pass without
  progress. Announcing any CID the node does not hold then takes the slot back.
  Height misleads in the honest case too. A heavier chain can be shorter, and
  then it never triggers range sync; the node reaches it only through the
  predecessor walk.
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
chain, so tallies of overlapping offers have to be combined rather than kept
per chain. Content addressing commits a leaf to its whole ancestry, which binds
what is kept to what was tallied without a separate commitment scheme, provided
keeping is tied to the tallied CIDs.

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

An *offer* is anything that would add work to the node's graph: a new block or
branch, or securing-work evidence that adds a grind to a block the node already
holds or is tallying. Evidence gets the same treatment as a branch, because it
enters the same comparisons.

Acquisition spends in three steps, and only the last is permanent:

- **Probe.** The node obtains an offered root and verifies its proof of work
  (for a child block, its securing-work proof). This step cannot be avoided,
  because no gate can act on work it has not seen. The probe is the price of
  learning an offer's work at all. Fabricated or mismatched bytes can still be
  attributed to their sender, as today.
- **Tally.** While an offer has not yet been shown to matter, the node applies
  every check weighed admission applies: proof of work (for a child block, the
  securing-work proof), version, parent link, matching spec, `prevState`
  against the parent's `postState`, height, timestamp, and target schedule. It
  records the resulting proven work. Nothing is staged, stored durably, entered
  into the consensus graph or relayed. A block's work is credited only once all
  of its checks have completed. A top-down walk meets a block's descendants
  before its ancestors, so the schedule checks for the top of the walk complete
  only as the walk descends far enough to cover their retarget window. Until
  then that work stays uncredited and the pending blocks occupy the budget. The
  window is committed by the chain, and §3.5 already lets a node decline to
  operate a chain whose committed parameters exceed its resources.
- **Keep.** Once the work that would enter a comparison reaches the bar, the
  offers behind it go through ordinary acquisition unchanged: weighed when
  possessed, stored durably, counted, and executed if they become load-bearing.
  If the offering peer withholds at this point, that is an availability gap like
  any other.

### The tally record

Tallies are not independent per offer. Many leaves can share one unkept spine,
forward offers can share a prefix, and a side leaf's walk can cross another
tally's spine. The bar limits the *total* unkept work entering each comparison
under the consensus measure. So the node's tallies form one shared record,
which has these properties:

- **It knows the shape, not just the amounts.** It holds each tallied block's
  parent link as well as its proven work. Without links, work could not be
  assigned to the comparisons it would enter.
- **It combines work by grind identity (§9.1).** This applies both within the
  record and against work already counted in the kept graph. Summing overlaps
  would let N one-block leaves on a cheap spine each claim the spine's work.
  Failing to combine them would leave a branch that is heavier only through its
  side branches uncounted, and the node on the lighter chain.
- **Tallies that meet, merge.** A top-down walk that reaches a block already in
  a forward tally joins that tally and takes on its attachment point.
- **It is bounded and forgettable.** It grows with the number of tallied blocks,
  is bounded by the operator's tally budget, and does not survive a restart. It
  is not a seen set in the [operator-finality](operator-finality.md) sense:
  nothing in it is recorded as rejected, and every entry stays re-offerable.

Proven work in the record is a **lower bound, not a verdict**. A tally that has
not attached, or whose checks have not all completed, has an open frontier. A
re-offer of any block in it, or a new provider for its missing ancestor, resumes
the walk from that frontier. Only a complete tally, attached with every check
done, lets a re-offer skip the walk. That makes the record safe against
poisoning. An attacker who announces an honest leaf first and stalls its
ancestry leaves only a partial lower bound, which the honest peers' offers then
extend. And an entry cannot be inflated, because work proves itself and one
grind secures only one location per chain (§9.1). Work the record already knows
still orders acquisition, and it is judged again whenever the bar drops.

Keeping must be tied to the bytes that were tallied. A content-addressed leaf
commits to its whole ancestry, but that only protects the node if keeping
either descends from the tallied CIDs or checks each fetched block against the
record before storing it. Otherwise a peer could pass the tally with one branch
and serve another at keep time, which would be detected only after storage. A
branch kept after a tally is fetched twice, in effect: once to prove its work,
then again to store it. That adds latency to honest deep reorgs.

### The bar

An offer attaches to the node's graph at a block the node holds. Its weight
then enters every fork comparison on the path from that block back to genesis,
and it also competes with the attachment block's existing children. How the
bar is set depends on whether the offer's side loses any of those comparisons:

- **If it loses at least one**, the **bar** is the smallest margin among the
  comparisons its side loses: the least work that could change the outcome of
  one of them. Each margin is measured against *validated* work (see below).
  When the offer attaches below the canonical tip, that is the incumbent's
  validated work above the attachment point: Bitcoin's relative threshold,
  restated for subtree weight. When the offer sits on a losing branch, the
  smallest losing margin on its path is smaller, as it should be.
- **If it loses none and keeping it would move the head**, as when it extends
  the canonical tip, the bar is zero. It is kept at once.
- **If it loses none and would not move the head**, as with evidence adding a
  grind to a canonical block, it has no bar. Its work only widens margins the
  node already wins, so it is never decisive and may stay unkept. It is judged
  again whenever the graph changes and one of its comparisons starts to lose.

The rule is the pivotality rule from
[weight-first-acquisition](weight-first-acquisition.md), applied to unkept work
instead of unvalidated work. **An offer may stay unkept only while the total
unkept work that would enter each comparison, combined by grind identity, is
strictly less than that comparison's margin. Where it is not, offers are kept
until it is.** The bar limits the total, not each offer. Honest weight that
arrives as many small offers, such as siblings from many miners, is kept as
soon as together it could matter. An attacker gains nothing by splitting a
branch into small offers: overlapping work counts once, so what gets kept still
carries at least the bar in proven work. An exact tie can change a comparison,
so it is never "strictly less" and is always kept.

**The bar prices work, not bytes or blocks.** Once a comparison reaches its
margin, every block riding that comparison is keepable, however many there are
and however cheap each one is. The gate guarantees that what the node keeps
carries real work in proportion to what it could change. It leaves block count
and byte volume to per-block byte policy and the operator's storage budget.

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
  exceeds all of the node's work can be kept before the node finds where it
  attaches. This test counts the node's weighed-inclusive total, which makes it
  harder to pass than a validated-only total would. Unattached work never
  reaches fork choice, so the stricter test costs nothing.

So the bar only takes effect where work is cheap compared with what an offer
would have to beat, which in practice means deep attachments to easy schedules.

### Deferral, never refusal

An offer below the bar is not refused. It is not recorded as rejected, not
marked invalid, and not held against the peer that offered it. It can still be
offered and acquired again by CID.

Where an offer attaches determines when the bar is known. Forward acquisition
from a negotiated common ancestor ([bulk-sync-stream](bulk-sync-stream.md))
knows the attachment point before the first page, so the bar is known from the
start. A top-down predecessor walk only finds the attachment point at the
bottom, so each step of its descent costs a probe and draws on the tally
budget. Beyond the live edge, the node approaches main-chain offers forward
instead.

Claims carried in announcements (height today, any future work hint) may decide
which offers are tallied first. They never decide what is kept. This preserves
the boundaries [operator-finality](operator-finality.md) sets for any design
that declines work cheaply. No advertisement can prove an offer irrelevant.
Declining only lowers an offer's priority and is never final. An honest heavy
offer that under-claims is still tallied on its proven work. Hints are
advisory.

### Budget pressure

Tallying has an operator budget, and something must give when it is full. This
document does not choose that mechanism. It states the properties any
budget-pressure policy must have. The guarantees below follow from those
properties, whatever mechanism provides them.

- **P1: A release never silently forgets proven work.** Every release, whether
  of an attached or an unattached tally, leaves a resumable record: the CIDs of
  the frontier where the tally stopped, the proven lower bound behind them, and
  the providers known for them. The record is identified by CID and combines
  work by grind identity, so replaying the same offer cannot add its work twice.
  A later tally that reaches a recorded CID replaces the record's entry for it.
- **P2: Released work may block release, never cause keeping.** Released work
  counts toward how close a comparison is to its margin when deciding whether
  another tally may be released, so the gate fails open. Released work may also
  cause released tallies to resume from their recorded frontiers. But it never,
  by itself, causes anything to be kept. Keeping requires work that has been
  tallied again, checked and tied to its bytes. Released totals therefore
  cannot get junk kept, however they are replayed.
- **P3: Pressure pauses peers, never the node.** When the budget is full, the
  node stops starting tallies for particular peers, never all tallying.
  Otherwise an attacker could fill the budget with branches whose bottom parent
  nobody serves and cut the node off from the heavier branch. Peers are ranked
  by work whose proof has already been verified, meaning a root hash or
  securing proof that beats its claimed target. That is real work even before
  the schedule checks complete, so an honest top-down walk is not ranked as if
  it had proven nothing while its top retarget window waits on ancestors.
  Fully-checked credit remains the only thing that crosses a bar.
- **P4: Reserved budget follows the node's own choices and observations.** Any
  share of the budget reserved against inbound pressure goes to peers the node
  chose to dial, operator-configured peers before referred ones. It is spread
  across netgroups taken from observed socket addresses, never self-advertised
  ones. Outbound candidates can come from peer referrals, and behind a proxy
  every inbound peer shares one observed address. So observed diversity can be
  empty, and the reservation then reduces to the peers the node dialed.
- **P5: Stalled means no known provider can serve.** A tally counts as stalled
  on availability only when none of the providers known for its frontier can
  serve it, not when one provider is slow or times out. Under partial synchrony
  a slow honest peer and a staller look the same, so one timeout proves nothing.
  An attacker who registers as a provider for honest CIDs cannot make those CIDs
  stalled while an honest provider is known.

**What the properties give.** For every offer the node is tallying, the
pivotality rule means the node computes the head it would compute if it had
kept that offer. P1 and P2 extend this to released offers. Released work is
still known as a lower bound attached to CIDs. It counts against every further
release, so an honest wide branch cannot be released away one piece at a time.
And it can be resumed by CID from any known provider. So for any offer the node
still holds a tally or release record for, the head differs from the
kept-everything head only while that work is being fetched. That is an
availability gap. P3 and P5 keep an attacker from halting tallying or forcing
the release of an honest tally while an honest provider is known.

**What remains.** The resumable record is itself bounded by the operator's
budget, and it does not survive a restart:

- **Eviction.** Evicting a record is node-local cache eviction, the same kind of
  operator-budget reclamation this project already uses for losing-fork state.
  After eviction the node no longer knows that work exists.
- **Restart.** After a restart, work known only through records comes back only
  if it is offered again. Live announcements re-offer peers' tips. Each new
  session's frontier pull re-offers that peer's most recently admitted leaves,
  one page, newest first. A released side branch that is neither a tip nor among
  some peer's newest leaves is not re-offered until something descending from it
  is announced. Whether any provider still keeps it at all is availability:
  under [operator-finality](operator-finality.md), a fork survives only while
  someone keeps it.
- **The head effect.** While such work is unknown, the node's head can differ
  from that of a node that holds it. It differs only in a comparison that the
  forgotten work would itself have decided. That is the same standing as a
  branch the node never received.

In plain terms, against the two rules this has to live with:

- **Protocol.md** forbids a filter on work that can reach fork choice: a rule
  that makes nodes judge the same known work differently. The gate applies no
  such rule. Every piece of work it still has a record of is inside the
  pivotality accounting above. What it can do is forget, under a storage
  budget, work it held only as a record and never counted. That is a retention
  decision with the effect of not having received the work, not a filter on
  work the node knows.
- **Weight-first-acquisition** says a missing input is "retried indefinitely".
  Eviction and restart are where "indefinitely" ends for released work. A node
  retries what it still remembers. Beyond its budget, or after a restart, it
  relies on the network offering the work again, as every node already does for
  branches it never heard of. This is a real weakening for released work, and
  the operator chooses how much of it to accept: a node that keeps every record
  gives up nothing.

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
- **Uncombined tallies.** A subtree can be heaviest only through its side
  branches. A tally that sees only a main chain, or sums its pieces separately,
  would never cross the bar. The shared record combines work by grind identity
  and counts spine and sides together. Its budget has to fit an honest subtree's
  width, which follows the real fork rate.
- **Choosing by claim.** Picking whom to sync from by claimed height prefers a
  tall cheap branch over a shorter, heavier one. Claims only order tallies and
  never decide what is kept, so a truthful heavier offer is kept on its proof,
  whatever anyone announced.
- **A poisoned lower bound.** An attacker could announce an honest leaf, stall
  its ancestry, and try to have that partial tally stand in for the whole
  branch. Partial tallies stay open and are extended by later offers. If budget
  pressure releases one, P1 keeps its frontier, so the honest offers still
  resume it.
- **Cascading releases.** After a partition heals, an honest wide branch could
  be released piece by piece, each piece far from the margin on its own, so its
  work never adds up. That case is exactly what GHOST exists for, so it is not
  rare. Under P2, released work counts against every further release, and
  under P1 it combines by grind identity and resumes by CID.
- **A tallying halt.** If budget pressure could stop all tallying, an attacker
  could fill the budget with tallies that never attach. P3 pauses peers, not the
  node, and ranks them by work whose proof is already verified. P5 defines a
  stall by provider availability rather than by one timeout. P4 keeps the
  reserved share with peers the node chose.
- **Catch-up and fresh nodes.** The bar is measured over validated weight, and
  during catch-up validated weight lags the weighed tip. So the bar stays near
  zero for the whole catch-up, not only at genesis. The same holds at a fork
  after the node has reorged onto a branch it has not yet validated. A node in
  that state keeps nearly every attached offer, cheap branches included. It is
  not stranded, because the honest chain is heavier and crosses the bar. But it
  pays for the cheap branch and keeps paying on every boot. The no-attachment
  shortcut measures against weighed-inclusive totals, so it fires rarely here
  and does not let unattached deep offers be kept during catch-up. Those offers
  still run their tally walks under the budget. Bitcoin closes the remaining
  gap with a built-in minimum chain work. Here that could only be the operator's
  own choice, and a minimum set above the real chain's work would strand the
  node, so such a minimum must defer and report, never decline.

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
  own ancestry. A branch attached at genesis, below the first block any
  filtering miner produced, starts at the maximum target no matter what honest
  miners do.
- **The filter raises the bar, not the schedule.** Each block's next target is
  recomputed from its actual target and the observed solve times, with no clamp
  unless the chain commits one. Blocks mined harder than scheduled arrive more
  slowly, so the schedule settles back to what the network's hashrate supports.
  The filter does not permanently make blocks near the tip more expensive. What
  it does raise is the incumbent's work in each block it covers, and with it the
  bar a cheap deep branch must reach.
- **The filter makes height a worse proxy.** Blocks mined harder than scheduled
  make an honest chain shorter for the same work. Any acquisition choice based
  on height becomes easier to exploit with a tall, cheap branch, which is one
  more reason the gate orders and keeps by proven work.

## Boundaries

- **Consensus is untouched.** No validity rule, work measure, comparison,
  exclusion or tier changes. An offer below the bar is neither valid nor
  invalid. Once kept, it is admitted exactly as today.
- **Same head over what the node remembers.** A gating node computes the head it
  would compute if it had kept every offer it still holds a tally or release
  record for. The only difference is the time taken to fetch that work by CID.
  Work whose record was evicted, or lost at a restart, has the standing of work
  never received, as set out under Budget pressure.
- **Weight preservation is unchanged.** Eviction never drops counted work
  ([operator-finality](operator-finality.md)), and the gate never counts work it
  has not kept. The two fit together: eviction decides what a node stops
  keeping, this design decides what it starts keeping, and neither changes a
  counted fact.
- **No punishment.** Nothing below the bar lowers a peer's standing. Pausing a
  peer's tallies under budget pressure is resource budgeting, not reputation,
  and ends when budget frees. Bytes that do not match what was advertised can
  still be attributed to their sender, as today.
- **Operator settings.** The margin, the tally and record budgets, any reserved
  share, and any minimum required before keeping are node configuration with
  sensible defaults. The default never tallies an honest live-edge block, and
  "keep everything" is a conforming setting.
- **The node's own blocks and parent facts are not gated.** A block this node
  produced is kept as today. Genesis and continuity facts issued by the parent
  carry no work, and the [process trust model](process-trust-model.md) governs
  them, not this gate. Securing-work evidence does carry work and is gated as an
  offer.
- **Child chains use the same bar and measure.** A child block's weight is
  inherited securing work, so tallying it needs the securing-work proof. That
  proof is the per-sibling round trip [operator-finality](operator-finality.md)
  leaves open. Where a child node already holds the parent carriers, it can
  prove that weight without the network
  ([bulk-sync-stream](bulk-sync-stream.md)).
- **What remains exposed.** Offers that are not blocks at all, such as
  fabricated CIDs or roots nobody serves, carry no work for any gate to act on.
  They belong to transport and peer accountability: binding content to the
  exact announcer, and attributing deficient content. The tally record means a
  branch that has been completely tallied is not walked again when re-announced,
  but a stream of fresh cheap CIDs still costs one probe each. That cost scales
  with the attacker's bandwidth, not with any work, and it too belongs to peer
  accountability.
