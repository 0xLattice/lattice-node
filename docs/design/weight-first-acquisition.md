# Deferred Execution (Weigh on Possession, Execute on Selection)

## Model

Any peer may lie, withhold, stall, or be honestly pruned; a withholding
miner is normal operation, not an edge case. Security comes from per-item
verification plus objectively comparable work, under partial synchrony.
The one non-peer trust edge is the node's own configured immediate parent.
Publishing a block's bytes is, and remains, the price of being weighed:
this design never weakens the network's data-availability enforcement,
which today lives — easily missed — inside the admission gate itself.

## Problem

Acceptance is one gate today: a block enters the accepted graph and
contributes fork-choice weight only after its body is fetched, every
transaction resolved, and its state transition executed and checked
against the declared post-state. The gate is sound (nothing invalid is
ever accepted) but it prices *weighing* a block at the cost of *using* it.

The expensive parts are not the bytes. A block's own volume is
skeleton-sized (~1 KB), and a losing sibling's transactions are largely
the same content-addressed objects as its canonical rival's — already
held, deduplicated by CID. What each accepted block actually costs is the
state execution, the materialized state it durably stores, and its
occupancy of the single sequential admission lane. On the live testnet
child, ~74% of the accepted graph is losing same-height siblings: the
majority of execution and state-storage work is spent on blocks whose
only consensus contribution is their weight — which never required
executing them. (On a fork-free chain this design saves nothing; every
block is spine and must be executed before anyone builds on it.)

## Concept

**A node weighs a block when it possesses and structurally verifies it,
and executes it only when the block matters.** Two tiers of belief:

- **Weighed**: the node holds the block's bytes — header, transactions,
  referenced proof material — and has verified everything verifiable
  without execution: the proof of work over the header, parent linkage,
  size and structural validity, and for a child block its securing-work
  proof and reference-level continuity. The block's work counts. Its
  declared post-state is recorded as an unverified claim.
- **Validated**: the state transition has been executed and the declared
  post-state checked. Only now may the node *use* the block — build
  templates at its tip, serve its state, or issue the parent-side
  continuity facts children consume. The complete acted-on set, which
  additionally covers asserting a head externally, is enumerated under
  Pivotality below.

Execution runs when a block becomes *load-bearing*, under two triggers:

- **Selection**: fork choice selects a branch; the node validates it
  forward from its last validated ancestor before producing on or serving
  its tip.
- **Pivotality**: unvalidated weight may not decide anything the node
  acts on — where "acts on" means, exhaustively: building templates,
  serving state, issuing continuity facts, and asserting a head
  externally (head announcements, read and status views of the canonical
  tip — never possession inventory, which advertises what the node holds
  and is governed by the possession boundary, not by pivotality).
  A comparison is safe to act on only when the total unvalidated weight
  on the winning side is strictly less than its margin over the
  alternative; where it is not, blocks are validated until it is.
  Pivotality is a property of the residual unvalidated *set*, never of a
  single block — subtree aggregation lets many individually-immaterial
  blocks be collectively decisive. The asymmetry that makes deferral
  work is structural: unvalidated weight on the *losing* side of a
  comparison is never pivotal (excluding it only widens the margin), and
  every losing sibling sits on the losing side at its own fork base — so
  the measured majority is deferrable by construction. The validation
  loop terminates: each round validates or permanently excludes a block,
  both monotone over a finite set. Its cost is margin-driven, not
  constant — as fork-choice margins narrow, more winning-side weight
  becomes pivotal, and a sustained near-tie (roughly half the network's
  work) degrades deferral back toward validate-everything. The
  amplification an adversary buys is bounded by fork depth, not by one
  block: one grind atop an existing near-tie fork forces execution of
  the branch prefix since the last validated ancestor, on both sides if
  alternated — only recent forks sit within a block of canonical, so
  depth stays small.

Invariants:

- **Acted-on decisions are uniform over obtained bytes.** Every decision
  a node acts on is identical to that of a node which validated every
  block whose bytes it obtained. Computed weight may permanently include
  work a validating node would have excluded; the pivotality rule
  guarantees such weight never reaches an action. A validate-at-admission
  node and a deferred-execution node therefore differ only in *when*
  work is examined, never in any decision either acts on, and the two
  interoperate on one network.
- **Deferral without the seam is forbidden.** No implementation may count
  weight it has not validated unless it can exclude what it later proves
  invalid; deferring execution is only safe together with the exclusion
  seam below.
- **Availability never judges.** Execution invalidity is recorded only
  from a *complete* judgment: every named input resolved and verified
  against its CID, the transition executed, the declared post-state
  mismatched (or a chain-committed validity rule failed). The verdict is
  a pure function of content-addressed inputs, identical on every node
  that reaches it regardless of which prefix that node validated. Failure
  to obtain an input is never a verdict — it is an availability gap,
  retried indefinitely, excluding nothing. The durable record of an
  exclusion is the evidence of the failing check, sufficient to re-derive
  the verdict, and the inputs that proved it are retained as an
  obligation — an unre-derivable marking is not a judgment. Anything
  short of a completed deterministic check is retryable, never recorded.
- **Exclusion is chain-local and never touches exported work.** A proven
  execution-invalid block's subtree is excluded from the excluding
  chain's *own* effective weight, and fork choice re-projects — a staged,
  durable, replayed fact like any other, so a restart recomputes the same
  head. But a securing grind's contribution to a child chain is
  independent of carrier validity, so the work facts the chain *serves*
  are unaffected: exported inherited weight remains monotone. Nothing is
  ever pruned — verified work facts and invalidity evidence are both kept
  forever; exclusion changes what the chain's own head computation
  counts, not what the chain knows or serves.
- **Children consume continuity from the validated subgraph only.** A
  weighed block's declared post-state is an unverified claim, so
  parent-state continuity paths are computed over validated blocks alone.
  Carrier securing-work proofs are exempt — carriers need not be valid,
  by spec. The binding constraint is narrower than it first appears: a
  child binds to its carrier's *pre*-state, which is the carrier's
  predecessor's post-state — so a carrier that forks one block off the
  validated spine already names a state the parent holds. The residual
  coupling: a parent that *tracks* a child validates the branch prefixes
  that child's carriers name, regardless of the parent's own fork choice
  — the same tracked-child obligation eviction already carries. For
  untracked children, the general guarantee only. The cost of this
  coupling is liveness for deep-off-branch carriers, never child safety.
- **Child deployments must not defer silently.** A child genesis anchored
  in an unselected carrier is real — canonicity never changes child
  validity — and discovering it requires the carrier's transaction
  bodies. Whatever surface serves child discovery must account for every
  possessed block, not only the validated spine.

The prior "declining work cheaply" companion (operator-finality) is
narrowed, not subsumed: this design removes execution and state storage
for unselected blocks, but weighing a child block still requires
soliciting its securing-work proof, so the per-sibling round trip that
companion worries about is unchanged and remains the open question, under
the boundaries operator-finality states.

The three designs compose: **eviction is weight-preserving
(operator-finality), transport is an ordered stream (bulk-sync-stream),
and execution is deferred to load-bearing blocks — weigh what you hold,
move bytes in order, execute exactly what matters.**

## Boundaries

- Weight comparison, heaviest selection, and monotone inherited weight
  are untouched. What changes is what acceptance *asserts*: the accepted
  graph records possessed, structurally-verified work; validity becomes a
  second, recorded, deterministic judgment. The consensus spec must be
  amended explicitly, at minimum: the meaning of "accepted" in the
  effective-work invariant (and its new "not within a proven-invalid
  subtree" rider); the never-prunes invariant's rider that exclusion is
  not pruning and excluded facts remain served; the admission procedure's
  split into per-tier gates with per-tier durability ordering, the
  invalidity marking included; and continuity's "connected accepted
  graph" becoming the validated subgraph. The sibling fork-choice doc's
  description of deferred execution as "consensus-neutral" is corrected
  by the same change — this is consensus-adjacent and is treated with
  that gravity.
- Data availability is enforced exactly as today: no possession, no
  weight. A withheld branch weighs nothing anywhere, so the design adds
  no new withholding leverage and no permanent-skeleton inflation beyond
  what a publishing attacker could already buy.
- Recovery and boot invariants hold per tier; no index, page, or
  advertisement promises a tier the node has not reached for that block.
  Served surfaces already advertise possession truthfully — possession
  and acceptance coincide at the weighed tier by construction.
- Serving a block whose bytes match their CID is never a serving fault,
  regardless of whether its transition later proves invalid — minting a
  PoW-valid, execution-invalid block is available to anyone, so relaying
  one attributes nothing to the relayer. Attribution is reserved for
  bytes that do not match what was advertised.
- Durable formats evolve additively or by flag day per the standing
  compatibility constraint; the interoperability claim above is behavioral
  (same decisions, different timing), not a license to skip that
  discipline.
