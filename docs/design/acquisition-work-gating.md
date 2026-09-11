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

**Validity and the fork-choice rule are untouchable.** The node boundary says
so directly: "No node-local work floor exists: any filter on work that can
reach fork choice would be consensus-relevant, so the chain's own target is the
only work gate" ([protocol.md](../protocol.md)). The specification allows one
kind of local preference: a node "may apply its own root-work floor before
spending resources on acquisition, but that is a non-punitive local preference
and never changes validity" (Lattice spec §5.4). A gate may control what a node
spends resources on. It may never decide whether a block is valid or how much
it weighs. It can affect which head a node selects only by releasing, under an
operator budget, verified work it never counted, and then being unable to
obtain that work again. That is a bounded deviation, set out under
[The deviation](#the-deviation), and this document does not claim the rules
quoted here already allow it.

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
document does not choose the mechanism. It states the requirements any
budget-pressure policy must meet, what they guarantee, and the one deviation
they cannot remove.

- **P1: A release can be resumed by any route.** A released tally leaves a
  record from which it can be resumed without being offered again. The record
  resumes as soon as its frontier becomes available by any route: a re-offer, a
  new provider, or the missing ancestor arriving through range sync or through
  another keep. A record counts as stalled only when no known provider can serve
  its frontier. One provider timing out proves nothing, because under partial
  synchrony a slow honest peer and a staller look the same.
- **P2: Released work stays counted by identity, never as a bare number.** A
  release leaves an entry naming the frontier it stopped at and the work proven
  behind that frontier. Entries are grouped by the comparison the work would
  enter. A released tally that has not attached enters no comparison yet, so its
  entry stands on its own frontier until it attaches. Re-releasing a frontier
  that is already recorded replaces its entry rather than adding to it, so
  replaying the same offer can never add its work twice. An entry is removed
  when its work is kept or tallied again, so the accounting falls as well as
  rises. Entries are bounded per comparison and in total; when the bound is
  reached the entries farthest from mattering are dropped (P6), and dropped work
  falls under [The deviation](#the-deviation). Nothing is ever collapsed into a
  number that can only grow. Entry work can still over-count overlaps between
  distinct frontiers, so entries are used for exactly two things: blocking
  further release, and triggering the resumption in P3. They are never used for
  keeping and never for fork choice.
- **P3: Reaching a margin obliges resumption.** When known unkept work plus
  recorded released work entering a comparison reaches its margin, the node must
  resume that comparison's released tallies and re-solicit that comparison's
  branches from its peers. This is an obligation, not an option. It draws budget
  from tallies far from any margin, and peer pausing never blocks it.
  Re-solicitation is bounded per comparison and bounded in total across
  comparisons, and that global budget is spent in order of the real unkept work
  at each comparison, so comparisons an attacker has inflated cannot crowd out
  an honest one. What gets kept is still decided only by work that has been
  tallied again. No existing overlay request can ask for this: the frontier pull
  returns a peer's newest leaves, the legacy leaf descent walks every leaf in
  CID order, and range sync pages only a peer's main chain. A request for the
  branches of a peer's accepted graph that descend from a named block is
  therefore a requirement of this design. It must be bounded the way the
  existing leaf page is, with a page limit, a cursor and a fixed admission
  snapshot so a changing forest cannot move a branch behind the cursor, and it
  answers only what that peer retains. It is also a new wire topic: peers that
  predate it cannot answer, so until the fleet has upgraded, re-solicitation
  reaches only upgraded peers and the deviation lasts longer.
- **P4: Pressure falls on peers, never the node.** When the budget is full, the
  node may stop starting tallies for its lowest-ranked peers and may release
  their existing tallies, each release meeting P1 and P2. It never stops
  tallying as a whole. A peer's rank must reflect verified work on its tallies
  that are still making progress. That work stops counting once a check on it
  fails or its tally stops progressing, and a block's work counts toward only
  one peer's rank. Otherwise one real heavy grind on a fabricated parent, or one
  CID claimed by many sybils, could shield a flooding peer. Rank may count work
  whose proof is verified before its schedule checks complete, so an honest
  top-down walk is not ranked as if it had proven nothing.
- **P5: Reserved budget cannot be captured from outside.** Any share reserved
  against inbound pressure favours peers the node chose to dial. A peer learned
  only through another peer's referral does not count as the node's own choice
  the way an operator-configured peer does. Diversity is measured on addresses
  the node observed, never on addresses peers advertise. Where observed
  diversity collapses, as behind a proxy, the reservation reduces to the peers
  the node dialed.
- **P6: The adversary does not set the horizon.** Entries and records are
  dropped in order of distance from mattering, farthest first. For attached
  work, that distance is the gap between a comparison's known plus recorded work
  and its margin. Unattached work enters no comparison, so its distance is the
  work it proves: an unattached record holding more work is dropped later,
  because that is what could matter once it attaches. A flood of cheap releases
  therefore pushes out the attacker's own far-from-margin entries before an
  honest entry near a margin.

When every release that would relieve the budget is blocked by P2, the node
keeps the blocked offers. It does not halt and it does not forget. At that
comparison the gate falls back to today's behaviour. **That fallback is decided
by real unkept work alone.** Recorded released work may block a release, but it
can never be the thing that makes the node keep an offer, so replaying releases
cannot buy an attacker permanent storage at a comparison of its choosing.

**What the requirements give.** Three guarantees follow:

- **Work the node can still obtain.** For every offer the node is tallying, or
  holds a record for and can still fetch, the node computes the head it would
  compute if it had kept that offer. It differs only while that work is being
  fetched. This follows from the pivotality rule, from P1, and from P3's
  obligation to resume.
- **Work the node cannot obtain.** Released work that no peer will serve again
  falls under [the deviation](#the-deviation), whether or not its record
  survives.
- **No attacker control.** An attacker cannot halt tallying (P4, P5), cannot
  choose what is dropped (P6), and cannot get junk kept by replaying releases
  (P2 and the fallback rule above).

### The deviation

These requirements do not make fork choice identical to that of a node that
retained everything it verified, and this document does not claim they do. A
counterexample:

1. A gating node and a node that keeps everything both verify branch B. B
   attaches at fork F, far below F's margin.
2. Under budget pressure the gating node releases B, keeping an entry for it.
3. B's only provider then goes offline for good.
4. An exclusion removes validated incumbent weight at F, and F's comparison
   narrows. Known work on B's side still falls short of the margin, but known
   work plus B reaches it.
5. The node that kept everything switches head. The gating node's accounting
   reaches the margin and it re-solicits, but nobody serves B, so it does not
   switch.

Losing the entry is not required: a node that still holds B's record but can
find no provider is in the same position. Nor is exclusion the only way a
margin narrows; new grind locations narrow margins too (§9.4). What the
deviation needs is only that verified work was released and cannot be fetched
again.

This is not an availability gap under the project's rules, because the
comparison those rules use is a node that retained B:

- operator-finality requires that "A node's fork choice must be identical to
  that of a node which retained everything it has ever verified". It warns that
  otherwise nodes "could compute different heaviest branches purely as a
  function of their retention policy". That comparison node keeps the *weight
  facts*, not the bytes, and it "may select a head it has not yet re-acquired",
  so the loss of a provider does not excuse the gating node.
- modular-admission-pipeline rules out work floors because "two nodes with
  different floors could select different tips". Two nodes with different tally
  budgets could too.
- protocol.md treats any filter on work that can reach fork choice as
  consensus-relevant.
- weight-first-acquisition says a missing input is "retried indefinitely". Here
  the work is retried only when it becomes pivotal, and only by re-solicitation,
  which after a drop cannot even name what was lost.

The per-comparison accounting cannot be promoted into fork choice to close this.
It has no grind identity, so real arrivals would double-count against it (§9.1);
it is reachable by replay, so it would hand an attacker a way to move a head;
and making it exact against dropped work needs exactly the identities that are
gone, which is the durable-skeleton option below.

The deviation is bounded in five ways:

- **Scope.** It concerns only verified work the node released and never counted,
  attached or not, whether or not its record survives, and only while no peer
  will serve that work again.
- **Trigger.** It changes a head only when released work is pivotal: known work
  entering a comparison falls short of the margin, and known plus released work
  reaches it.
- **Duration.** It lasts only while no provider serves the work when it is
  re-solicited. Any provider ends it. Until peers support the fork-point-scoped
  request above, re-solicitation reaches fewer of them, which lengthens it.
- **Zero cases.** It is zero for a node that never releases a verified tally,
  and for every offer the node never released. Keeping every record durably is
  not sufficient: a record whose work nobody will serve cannot be re-fetched.
  Zero requires that released work is either never released or counted, as in
  the alternatives below.
- **Restart.** A restart does not create a new kind of deviation. The tally
  record does not survive a restart but the released-work entries do, so a
  restart turns records into entries. After a restart the frontier pull re-offers
  only each peer's newest leaves, and only once the node is at the live edge
  with that peer. A node still catching up gets no frontier pages until then,
  and re-solicitation covers what the frontier pull does not.

**Building releases as specified requires first rewording** operator-finality's
weight-preservation rule, protocol.md's work-floor sentence and
modular-admission-pipeline's floor sentence, so that they admit this bounded
deviation for verified work that was never counted. That is a decision for the
maintainer. There are two alternatives with no deviation at all:

- **Durable skeleton records.** A release keeps each released block's identity,
  parent link and verified work durably, without its bytes, and **counts** that
  work once it becomes pivotal, as operator-finality already counts evicted
  weight. Counting it, not merely recording it, is what removes the deviation.
  The cost is that the entry count cannot be bounded: an attacker can mint cheap
  blocks at an eased schedule, have them tallied and released, and each one
  leaves a permanent entry. Capping the record would bring the deviation back in
  a worse form, over work the node had already counted. So this option means
  permanent per-block metadata for every block ever offered, which is most of
  the permanent per-block cost the gate exists to avoid. It also needs a
  specification change to count work that was verified from bytes the node held
  but never staged.
- **Never release verified work.** Budget pressure only pauses new tallies, and
  an existing tally that cannot fit is kept. Fork choice is then identical. The
  cost is that an attacker who fills the tally budget forces keeping at whatever
  rate it can fill it, and what is kept is kept permanently, so the storage cost
  is permanent rather than lasting only while the budget is full.

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
  pressure releases one, P1 keeps it resumable by any route.
- **Cascading releases.** After a partition heals, an honest wide branch could
  be released piece by piece, each piece far from the margin on its own, so its
  work never adds up. That case is exactly what GHOST exists for, so it is not
  rare. Under P2 each released piece stays counted by its own frontier identity,
  against every further release, and an unattached piece is counted on its
  frontier until it attaches. Under P3 the node must resume and re-solicit once
  the accounting reaches a margin. What remains is
  [the deviation](#the-deviation).
- **A tallying halt.** If budget pressure could stop all tallying, an attacker
  could fill the budget with tallies that never attach. Under P4, pressure
  pauses and releases the lowest-ranked peers' tallies, ranked by verified work
  that is still progressing, and never stops the node. A stall is defined by
  provider availability rather than by one timeout (P1). P5 keeps the reserved
  share with peers the node chose. A release that P2 blocks falls back to
  keeping, decided by real unkept work.
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
  invalid. Once kept, it is admitted exactly as today. Head outcomes can differ
  only as set out under [The deviation](#the-deviation).
- **Same head, except the stated deviation.** A gating node computes the head it
  would compute if it had kept every offer it is tallying, or holds a record for
  and can still obtain, apart from the time taken to fetch that work. Beyond
  that, heads can differ only as set out under [The deviation](#the-deviation).
- **Weight preservation is unchanged for counted work.** Eviction never drops
  counted work ([operator-finality](operator-finality.md)), and the gate never
  counts work it has not kept. The deviation relaxes operator-finality's rule
  only for verified work the gate never counted.
- **No punishment.** Nothing below the bar lowers a peer's standing. Pausing a
  peer's tallies under budget pressure is resource budgeting, not reputation,
  and ends when budget frees. Bytes that do not match what was advertised can
  still be attributed to their sender, as today.
- **Operator settings.** The margin, the tally and record budgets, any reserved
  share, and any minimum required before keeping are node configuration with
  sensible defaults. The default never tallies an honest live-edge block.
  "Keep everything" is a conforming setting, and a node that never releases a
  verified tally has no deviation.
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
  accountability. Releases of distinct cheap frontiers can also raise a
  comparison's recorded released work. That blocks release at that comparison
  and triggers rate-bounded re-solicitation, so the cost is a fall back to
  keeping there, decided by real unkept work, plus a bounded stream of requests.
