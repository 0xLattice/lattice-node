# Sync Is Header-Graph Acquisition; Bodies Are Deferred

> **Supersedes** the earlier "ordered stream" framing of this document. The
> stream framing solved the right diagnosis (below-the-tip is not the live
> edge) with a heavier mechanism than needed. The model here is simpler and
> composes with two designs already in the repo:
> [weight-first-acquisition](weight-first-acquisition.md) (deferred execution)
> and cashew's targeted retrieval.

## Model

Any peer may lie, withhold, stall, serve valid-but-irrelevant data, or be
honestly pruned; there is no honest-majority assumption among peers, and
security comes from per-item verification plus objectively comparable
cumulative work, under partial synchrony — in which a slow peer and a
stalling peer are indistinguishable, so rotation is a local timing policy
that never implies blame. The one non-peer trust edge is the receiver's own
configured immediate parent, which alone answers genesis and parent-state
continuity questions on the hierarchy plane.

## The insight

A block has two independent halves, and consensus only ever needed the first:

- A **header** — the block's cashew *root node*: parent CID, target,
  `nextTarget`, height, timestamp, nonce, and the CIDs of its sub-bodies
  (transactions, state roots, children trie). One targeted content-addressed
  retrieval. Proof of work is computable from the root alone (the PoW preimage
  hashes the inline scalars plus the *CID strings* of the references, never
  their contents). The consensus graph is **already header-only**:
  `ConsensusBlockInput`/`submitBlock`/fork choice read the header fields and
  the claimed state CIDs, and never the body or materialized state.
- A **body** — transactions, the executed state transition, the children
  trie. Needed to *validate* the block (re-execute and check the declared
  `postState`) and to *use* it (build on its tip, serve its state).

So a block can **count for fork choice on its header alone** — possess the
root, verify PoW, its work is real — while its body is fetched and executed
**later, and only if the block turns out to matter**. Below the tip, most
accepted blocks are losing siblings (measured ~74% on the live child): they
are weighed from headers and their bodies are **never retrieved or executed**.

This is exactly [weight-first-acquisition](weight-first-acquisition.md)'s two
tiers — **weighed** (possess + structurally verify, work counts) and
**validated** (executed, may be acted on) — with the weighed tier resolved at
*header* granularity. Headers-first is the download half; deferred execution
is the execution half; together they are the whole model. Neither is a
foreign graft — both are already the design's own.

## What sync becomes

Sync stops being a subsystem. It is: **acquire headers into the weight graph;
let fork choice run on them; retrieve and execute a body only when its fork is
a canonical candidate.** The height-blind sweeps, the per-block evidence
solicitation fired from inside failed admissions, and the single admission
slot shared with live traffic all exist because sync today acquires and
*executes* whole blocks through the live-edge machinery. When the weighed tier
is header-only, that machinery is not needed for bulk: sync unifies with the
live edge, and root sync and child sync are the same operation — the
"unified adopt" principle.

### 1. Establish the start: common-ancestor negotiation

Sync begins by negotiating a **common ancestor**, not at the receiver's
frontier. The receiver offers a **locator** — its own accepted main-chain CIDs
newest-first at exponentially widening gaps, genesis last — and the peer
returns the highest entry on *its* main chain plus the headers forward from
it. A proposed start is valid only because it is one of the receiver's own
accepted blocks, so negotiation can never rewind a receiver past its verified
history. Three outcomes, distinct on the wire: a shared ancestor with headers
forward (stream), a shared ancestor with nothing forward (genuinely caught
up), or no shared ancestor at all (disjoint retention — end this peer, rotate,
never punish). An empty page is never again conflated with "caught up." This
is the Bitcoin block-locator convention, and it is the mandatory, SOTA-shared
part of the design regardless of everything below.

### 2. Acquire the header graph and weigh it

From the common ancestor, retrieve block **headers** (targeted root
retrievals) and, per header, verify proof of work. A verified header's work
enters fork choice immediately — no body, no execution. Headers may be
acquired from many peers in parallel and out of order; a header's *place* is
its parent CID, so assembly is trivial. Fork choice ranks whole subtrees over
this header/weight graph exactly as it does today (it is already state-blind).

For a **root** chain a header's own PoW is its work, self-contained. For a
**child** chain a header's weight is *inherited* — it is the securing work of
the parent grind that committed to it, which needs the securing proof. That
proof is not fetched per child block: the child's securing weight is
**regenerated locally from the parent carriers** the node holds
("proofs are regenerated from the retained closure when it exists"). So the
hierarchy syncs **top-down** — acquire the Nexus header graph first; a child
header is then weighed against the Nexus carriers already held. Regenerating a
securing proof does read parent carrier *sub-bodies* (the children trie of the
committing carrier), so child weighing is heavier than root weighing, but far
cheaper than a per-block child-evidence download, and it is the carrier owner's
own retained data.

### 3. Retrieve and execute a body only on candidacy

Fork choice selects a branch from the header graph. **Only then** are that
branch's bodies retrieved (independently, per block, in parallel) and executed
forward from the last validated ancestor — the **validated** tier. Losing
forks are weighed and never touched. A body that is a canonical candidate but
whose parts are not yet available is an **availability gap**: retried
indefinitely, never a verdict, and the node keeps acting on its last validated
tip meanwhile. Execution that completes and *fails* — a deterministic mismatch
of the declared `postState`, or a committed validity rule — records an
**invalidity exclusion**: the proven-invalid subtree is removed from this
chain's own effective weight and fork choice re-projects.

### The data-availability linchpin

Header-weight **ranks**; only **validated** blocks are **acted on** — built
upon, served, exported, asserted as head (the acted-on set is enumerated in
[weight-first-acquisition](weight-first-acquisition.md)). A miner can publish a
heavy header chain (real work) and withhold its bodies; it ranks first but is
**never acted on** — the node keeps building on its heaviest *validated* tip
and retries the missing bodies as an availability gap. This is the *same*
withholding surface as a secret-then-released heavy chain today; header-weight
adds **no new attack**, *provided* "rank on headers, act only on validated" is
implemented exactly. Get it wrong and a heaviest-but-invalid or
heaviest-but-unavailable path could be acted on, or nodes with different body
availability could split. This is the one part to model adversarially first.

## Boundaries

- **Consensus is untouched at the machinery level.** The consensus graph is
  already header-only (`ConsensusBlockInput` excludes the body and state). The
  only coupling is that admission (`ChainLocalAdmission.prepare`) refuses to
  emit a block's weight fact until its execution succeeds. The change is to
  split that: emit a *weighed* block fact from root + PoW with the declared
  `postState` recorded as an unverified claim, and add the invalidity-exclusion
  fact and a validated-subgraph notion. This is consensus-adjacent and is
  treated with that gravity — the spec (§9) is amended: "accepted" means
  *weighed*; validity is a second recorded, deterministic judgment; continuity
  is computed over the validated subgraph; exclusion is not pruning and
  excluded facts remain served.
- **Deferral without the exclusion seam is forbidden.** Weight may not enter
  fork choice pre-execution unless a proven-invalid subtree can be excluded
  from what the chain acts on. The two land as one unit.
- **Availability never judges.** Failure to obtain a body is an availability
  gap, retried forever, excluding nothing. Only a *completed* deterministic
  check records invalidity.
- **Wire compatibility is additive.** The strict-canonical wire evolves by new
  message types, never mutated ones. Peers that do not speak the new topics
  keep serving the existing pages; receivers fall back — slow, never wrong.
- **Possession stays ungated.** Serving a block whose bytes match their CID is
  never a fault, validated or not; possession/serving surfaces
  (`forwardMainChainRange`, by-CID reads) are not gated on validation.
- **The unavailable tail is unsyncable by the same rule as today.** A chain
  whose facts no parent tracks and no peer retained cannot be synced; the model
  changes the *cost* of availability, never its existence.

## Composition

The three designs compose: **eviction is weight-preserving**
(operator-finality), **acquisition is header-first with a negotiated start**
(this document), and **execution is deferred to load-bearing blocks**
(weight-first-acquisition). Acquire headers, rank on work, execute exactly the
chain that matters.
