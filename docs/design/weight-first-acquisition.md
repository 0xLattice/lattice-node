# Deferred execution (weigh on possession, execute on selection)

> **Status:** Proposal, implemented. The rule is in the Lattice
> specification,
> [§9.9](https://github.com/0xLattice/Lattice/blob/59.3.1/docs/spec.md#99-deferred-execution-weighed-and-validated-tiers);
> the node's mechanism is `HeaderSync` plus `BodyPipeline`, described in
> [Body acquisition](block-fetching.md).
> **Purpose:** Why the node weighs a block from its header and executes it
> only when it matters, and the invariants the design had to keep. For the
> rule itself read the spec; for the mechanism read Body acquisition.

## The problem it solved

Acceptance used to be one gate: a block entered the accepted graph and
contributed fork-choice weight only after its body was fetched, every
transaction resolved, and its state transition executed and checked against
the declared post-state. The gate was sound (nothing invalid was ever
accepted) but it priced *weighing* a block at the cost of *using* it.

The expensive parts were not the bytes:

- A block's own Volume is skeleton-sized (~1 KB), and a losing sibling's
  transactions are largely the same content-addressed objects as its
  canonical rival's, already held and deduplicated by CID.
- What each accepted block cost was the state execution, the materialized
  state it durably stored, and its occupancy of the single sequential
  import lane.

On the testnet child chain measured for the proposal, about 74% of the
accepted graph was losing same-height siblings: most execution and
state-storage work was spent on blocks whose only consensus contribution
was their weight, which never required executing them. On a fork-free chain
the design saves nothing: every block is on the spine and must be executed
before anyone builds on it.

## The decision

**A node weighs a block when it possesses and structurally verifies it, and
executes it only when the block matters.** The spec defines the two tiers,
*weighed* and *validated*, and the act-on tip (§9.9).

The threat model behind it: any peer may lie, withhold, stall, or be
honestly pruned, and a withholding miner is normal operation, not an edge
case. Security comes from per-item verification plus objectively comparable
work, under partial synchrony. The one non-peer trust edge is the node's
own co-hosted immediate parent.

### When a block is executed

Execution runs when a block becomes *load-bearing*:

- **Selection.** Fork choice selects a branch; the node validates it
  forward from its last validated ancestor before producing on or serving
  its tip. A heavier branch takes over at its fork once its first block
  there is executed. Until then the node keeps acting on the branch it has
  validated, and does not retreat to the fork point on headers alone.
- **Pivotality.** Everything the node acts on is the act-on tip and its
  ancestry, all executed. The acted-on set is exhaustive: building
  templates, serving state, issuing continuity facts, and asserting a head
  externally (head announcements, read and status views of the canonical
  tip). Possession inventory is not in it: it advertises what the node
  holds.

A block that could change the act-on tip is one that matters. At each fork
on the chain the node acts on, every child heavier than the executed one it
follows (at the tip, every child) is asked for and executed when its body
is held. Whichever executes is followed; a heavier one is followed once it
executes.

### Why deferral pays, and what it costs

- A losing sibling sits on the losing side at its own fork base and never
  needs executing, so the measured majority is deferrable by construction.
- The cost is at forks: each alternative that arrives heavier than those
  executed before it is executed too, so a fork whose children arrive
  lightest first executes more than one of them.
- A stale sibling's descendants are not executed unless it becomes the tip.
- Weighing a child block still requires its securing-work proof, so the
  per-sibling round trip for that proof is unchanged.

## Invariants the design keeps

| Invariant | Meaning | Rule |
|---|---|---|
| Acted-on decisions are uniform over obtained bytes | Every decision a node acts on is identical to that of a node which validated every block whose bytes it obtained. A validate-at-import node and a deferred-execution node differ only in *when* work is examined, so the two interoperate on one network. | Spec §9.9 |
| Deferral without the seam is forbidden | No implementation may count weight it has not validated unless it can exclude what it later proves invalid. | Spec §9.9 |
| Availability never judges | Invalidity is recorded only from a *complete* judgment: every named input resolved and verified against its CID, the transition executed, the declared post-state mismatched (or a chain-committed validity rule failed). Failure to obtain an input is an availability gap, retried indefinitely, excluding nothing. | Spec §9.9; NODE-SEMANTICS-003 in [Correctness invariants](../correctness-invariants.md) |
| Exclusion is chain-local and never touches work | A proven execution-invalid block's subtree keeps its weight, but the excluding chain's own descent never steps into it. The exclusion is a staged, durable, replayed fact, so a restart selects the same head. Work facts the chain serves are unaffected, and the runs it serves only grow. | Spec §9.9, §9.10 |
| Children consume continuity from the validated subgraph only | A weighed block's declared post-state is an unverified claim, so parent-state continuity is computed over validated blocks alone. Carrier securing-work proofs are exempt: carriers need not be valid. | Spec §9.5 |
| Child genesis must not defer silently | A child genesis anchored in an unselected carrier is real: canonicity never changes child validity. Whatever serves child discovery must account for every possessed block, not only the validated spine. | |

### Continuity and off-branch carriers

The continuity constraint is narrower than it first appears. A child binds
to its carrier's *pre*-state, which is the carrier's predecessor's
post-state, so a carrier that forks one block off the validated spine
already names a state the parent holds. The residual coupling is that a
parent level validates the branch prefixes its hosted child's carriers
name, regardless of the parent's own fork choice. The cost of this coupling
is liveness for deep-off-branch carriers, never child safety.

## Boundaries

- **Weight comparison and heaviest selection were untouched.** What changed
  is what acceptance *asserts*: the accepted graph records possessed,
  structurally verified work, and validity is a second, recorded,
  deterministic judgment. This is consensus-adjacent, so the specification
  was amended rather than the node alone changed (§9.9, and the continuity
  rule of §9.5).
- **Data availability never judges and never un-weighs.** A withheld branch
  keeps its header weight and is simply never acted on, because the act-on
  tip follows executed blocks only. Honest work chains on the act-on tip
  meanwhile, so withholding buys what a secret chain already buys and no
  more.
- **No surface promises a tier the node has not reached.** Recovery and
  boot invariants hold per tier; no index, page or advertisement promises a
  tier the node has not reached for that block.
- **Serving a block whose bytes match their CID is never a serving fault,**
  whether or not its transition later proves invalid. Minting a PoW-valid,
  execution-invalid block is available to anyone, so relaying one
  attributes nothing to the relayer. Attribution is reserved for bytes that
  do not match what was advertised.
- **Durable formats evolve additively or by flag day.** The
  interoperability claim above is behavioral (same decisions, different
  timing), not a license to skip that discipline.

## Where the implementation differs from the proposal

- The proposal required the inputs that proved an exclusion to be retained
  as an obligation. The node keeps the exclusion as a durable fact and lets
  go of the body of a block found invalid
  ([Node architecture](../architecture.md#what-keeps-content)).
- Component names and measurements in the proposal described an earlier
  prototype. The current components are `HeaderSync` and `BodyPipeline`.
