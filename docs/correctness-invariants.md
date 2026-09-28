# Correctness invariants

Each invariant is a set of claims: a bullet `- **NODE-AREA-NNN.x** — …`
under its heading, its own lines indented. A claim is established by the
tests whose doc comment says `/// Establishes: <claim>`, on a zero-argument
test method of an XCTest class. A claim no test establishes yet carries an
indented `Gap:` line and the issue that will. `SafetyNetInvariantRegistryTests`
fails on a claim with neither or with both, a claim outside its heading or
declared twice, a gap that names no issue or belongs to no claim, a
claim-shaped ID outside a well-formed bullet, and an annotation that names
no claim or sits on anything but such a test method.

A test establishes a claim only if it fails when the claim is broken. Each
annotation was checked when it was added, by planting a bug that breaks the
claim where the test looks and watching the test fail. A claim enforced in
several places is established only where a test covers it; the other
places are their own claim until a test covers them too.

## NODE-SEMANTICS-001 — every import outcome has one node meaning

- **NODE-SEMANTICS-001.a** — `canonicalized`, `acceptedSide`, `carrier`,
  `duplicate`, `unavailable`, `temporarilyInvalid`, `invalid`, and
  `localFailure` remain distinct at the node boundary: `NodeImportDecision`
  maps every import result and error to exactly one of them.
- **NODE-SEMANTICS-001.b** — A child chain's genesis bootstrap in
  `ChainProcess.importBlock`, which maps its own results and carrier-link
  failures without `NodeImportDecision`, gives each the same meaning.
  Gap: #212

## NODE-SEMANTICS-002 — side validity is not canonicity

- **NODE-SEMANTICS-002.a** — The process's import decision for a block
  accepted off the canonical path is `acceptedSide`, not `canonicalized`.
- **NODE-SEMANTICS-002.b** — The process hands its canonical-commit
  publisher an import's commit only when the decision is `canonicalized`: an
  `acceptedSide` import publishes nothing and the tip stays where it was.
- **NODE-SEMANTICS-002.c** — `acceptedSide` is an accepted decision
  (`isAccepted`), as `canonicalized` and `duplicate` are and no other
  decision is.
- **NODE-SEMANTICS-002.d** — The service maps the process's decisions to its
  own dispositions case for case: a side block stays a side block.
- **NODE-SEMANTICS-002.e** — The service's relay of an accepted block, its
  child-genesis links and the submit-work `accepted` flag, which each decide
  by their own switch rather than `isAccepted`, count `acceptedSide` as
  accepted.
  Gap: #212

## NODE-SEMANTICS-003 — availability is retriable, not punishable

- **NODE-SEMANTICS-003.a** — `unavailable` is retried: a missing body or
  evidence when the evidence or the providers change, and by the execution
  walk on a timer; a missing parent fact (genesis or state continuity) on a
  timer.
  Gap: #213
- **NODE-SEMANTICS-003.b** — `unavailable` never penalizes the supplying peer.
  Gap: #213

## NODE-SEMANTICS-004 — local durability is not peer behavior

- **NODE-SEMANTICS-004.a** — `localFailure` is a local observation, not a
  verdict: the attempt is retried and its parent evidence is kept.
  Gap: #214 (today a local verification failure is terminal: its
  parent-evidence inbox entry is consumed and the carried hold released)
- **NODE-SEMANTICS-004.b** — A local failure or a store error never penalizes
  a peer.
  Gap: #213
- **NODE-SEMANTICS-004.c** — The portable-attachment decision blames on the
  bytes alone: an attachment that verifies is never blamed, even when the
  runtime generation or the session changed while it was checked.

## NODE-SEMANTICS-005 — only obtained invalid evidence is punishable

- **NODE-SEMANTICS-005.a** — Only a complete `invalid` same-chain candidate is
  attributed, and only to its sole supplier.
  Gap: #213
- **NODE-SEMANTICS-005.b** — Authenticated parent evidence establishes parent
  facts; it never vouches for a child transition, and a child-chain block
  rejected without a carrier link blames no one.
  Gap: #213

## NODE-STORAGE-001 — peers and persistence exchange complete Volumes

- **NODE-STORAGE-001.a** — An object the session lacks is requested as its
  own Volume root, and one it already holds is never requested again.
- **NODE-STORAGE-001.b** — `content(rootCID:cids:)` never serves a selection
  of entries.
- **NODE-STORAGE-001.c** — `IvyRootContentSource.Session.fetch` makes a Volume
  visible only when its root is present and every entry's bytes match its
  CID; a Volume that fails is attributed to its supplier.
- **NODE-STORAGE-001.d** — A response is accepted only for the root requested.
  Gap: #218
- **NODE-STORAGE-001.e** — A root's member set cannot change once stored.
  Membership is not checked against the root's DAG: a supplier may add
  correctly addressed entries, bounded by the session's member and byte
  limits.
  Gap: #218
- **NODE-STORAGE-001.f** — `IvyRootContentSource.response(_:from:)` passes a
  peer-served response only from the peer it asked (a failure passes
  through, whoever reported it).
- **NODE-STORAGE-001.g** — A complete Volume may span several bounded Ivy
  frames.
  Gap: #218
- **NODE-STORAGE-001.h** — Chunks from different requests, authenticated
  sessions, or runtime generations never combine.
  Gap: #218
- **NODE-STORAGE-001.i** — Partial assembly is never visible: a fetch returns
  every requested object or none.
  Gap: #218
- **NODE-STORAGE-001.j** — Every other acquisition path (a source's initial
  response, the exact-peer source initializers, the candidate and
  child-proof fetch sources, overlay transaction Volumes) checks bytes
  against CIDs the same way and accepts only the peer it asked.
  Gap: #218
- **NODE-STORAGE-001.k** — Entry-level content requests are refused before
  they reach `content(rootCID:cids:)`, and a Volume over the byte budget is
  served whole or not at all.
  Gap: #218

## NODE-STORAGE-002 — a durable fact never outruns its content

- **NODE-STORAGE-002.a** — Block import merges its Volume roots into retention
  before it stages the fact batch that references them.
- **NODE-STORAGE-002.b** — Every other durable reference (issued evidence,
  parent-evidence inbox, issued child proof) is written after its complete
  Volume is stored and retained.
  Gap: #216
- **NODE-STORAGE-002.c** — Import pruning protection only grows while the node
  is live.
- **NODE-STORAGE-002.d** — Issued-hierarchy pruning protection only grows while
  the node is live.
  Gap: #216
- **NODE-STORAGE-002.e** — Prepared proof storage and its SQLite capacity
  eviction are serialized through one gate, which leaves exactly the kept
  proofs retained.
  Gap: #216 (the current test passes with the gate removed)
- **NODE-STORAGE-002.f** — The prepared retained set is advanced inside that
  gate, never after it is released.
  Gap: #216
- **NODE-STORAGE-002.g** — Contextual child offers live in a durable LRU in
  the store: touching an offer (`touchContextualCandidate`, or offering it
  again) makes it the newest, and the order survives reopening the store.
- **NODE-STORAGE-002.h** — An offer's roots are pinned before its index row is
  written.
  Gap: #216
- **NODE-STORAGE-002.i** — Offer eviction removes the oldest offer, whole.
- **NODE-STORAGE-002.j** — Offer eviction never touches a candidate marked as
  a handoff.
- **NODE-STORAGE-002.k** — Import takes ownership of a handoff's roots before
  the handoff is released.
  Gap: #216
- **NODE-STORAGE-002.l** — Storing a new offer sheds the oldest handoffs beyond
  the handoff budget.
- **NODE-STORAGE-002.m** — No parent reserves anything at a child, and no
  acknowledgement gates parent progress.
  Gap: #216
- **NODE-STORAGE-002.n** — Canonicity never changes admission retention or
  exclusion. The validated marker is a cache, not validity (002.o).
  Gap: #216
- **NODE-STORAGE-002.o** — The validated tier is a cache: an off-chain
  validated block beyond the operator's retention budget loses its validated
  marker and pin.
- **NODE-STORAGE-002.p** — A root shared by several offers stays pinned until
  the last of them is released.
- **NODE-STORAGE-002.q** — An accepted block's roots stay owned after the
  handoff that brought them is released.
  Gap: #216
- **NODE-STORAGE-002.r** — Proof acquisition is independent of offers and
  handoffs.
  Gap: #216 (no enforcement point identified)
- **NODE-STORAGE-002.s** — A candidate the parent's evidence names carried is
  marked as a handoff.
  Gap: #216
- **NODE-STORAGE-002.t** — Re-offering a stored candidate and booting the node
  also shed handoffs beyond the budget.
  Gap: #216
- **NODE-STORAGE-002.u** — The process touches an offer each time a template
  carries it again.
  Gap: #216

## NODE-MEMPOOL-001 — the mempool is tip-relative, not consensus

- **NODE-MEMPOOL-001.a** — A pool entry that fails the state transform
  (`StateErrors`) never suppresses a template: a failing chunk of
  transactions is bisected, and the valid rest is kept.
- **NODE-MEMPOOL-001.b** — The pool may retain, order, relay, replace, or retry
  transactions; only Lattice validation against the validated tip makes a
  transaction part of a template.
  Gap: #217
- **NODE-MEMPOOL-001.c** — A local submission stores its complete transaction
  Volume before its SQLite reference.
  Gap: #216
- **NODE-MEMPOOL-001.d** — `ChainService.restoreLocalTransactions` brings every
  journaled local submission that still passes preflight back into the pool
  after a reopen; one that no longer does is dropped from the journal.
  Gap: #217 (the restart test journals a single transaction)
- **NODE-MEMPOOL-001.e** — Every pooled root holds exactly one live-pool pin,
  synced from the pool's current roots after every change: admission,
  replacement, eviction, inclusion, reorg re-add, and reset.
  Gap: #217
- **NODE-MEMPOOL-001.f** — Removing a local transaction removes its durable
  pin.
- **NODE-MEMPOOL-001.g** — Startup clears the live-pool owner.
- **NODE-MEMPOOL-001.h** — Restored local roots are pinned again after the
  live-pool owner is cleared.
  Gap: #217
- **NODE-MEMPOOL-001.i** — Only durable local roots are restored: a peer
  submission is never recovery authority.
- **NODE-MEMPOOL-001.j** — A peer submission stays serveable while pooled.
  Gap: #217
- **NODE-MEMPOOL-001.k** — A local transaction that leaves the pool (inclusion,
  replacement, eviction) leaves the durable journal and loses its durable pin.
  Gap: #217
- **NODE-MEMPOOL-001.l** — Booting the node (`Node.build`) restores local
  submissions before the pool admits anything else.
  Gap: #217
- **NODE-MEMPOOL-001.m** — An entry failing withdrawal validation
  (`MiningCandidateValidationError`) or a proof (`ProofErrors`) is bisected
  out the same way.
  Gap: #217
