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
  `ChainProcess.importBlock`, whose accepted and carrier arms set their
  decision by hand (its rejected arm uses `NodeImportDecision`), gives each
  the same meaning.
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

- **NODE-SEMANTICS-003.a** — Candidate admission's resolution
  (`candidateResolution`) turns an `unavailable` outcome with no missing
  same-chain ancestor into a wait, never a decision: a body no provider
  served waits for a provider (`.wait(.content)`), a missing parent fact
  (genesis or state continuity) waits on a timer (`.wait(.later)`), and any
  other missing evidence waits for new evidence (`.wait(.evidence)`).
- **NODE-SEMANTICS-003.b** — Candidate admission's outcome blame
  (`candidateBlame`) never names the supplier of an `unavailable` outcome,
  whatever it waits for. Reporting bytes that fail their CID is separate and
  follows the bytes.
- **NODE-SEMANTICS-003.c** — An `unavailable` import error thrown out of
  candidate admission, rather than returned as its outcome, is resolved by
  the same rule.
  Gap: #213 (the catch path waits for evidence on every thrown
  `unavailable`, a missing parent fact included; Lattice throws none today)
- **NODE-SEMANTICS-003.d** — The execution walk retries a block whose body or
  evidence is unavailable on a timer.
  Gap: #213

## NODE-SEMANTICS-004 — local durability is not peer behavior

- **NODE-SEMANTICS-004.a** — `localFailure` is a local observation, not a
  verdict: the attempt is retried and its parent evidence is kept.
  Gap: #214 (today a local verification failure is terminal: its
  parent-evidence inbox entry is consumed)
- **NODE-SEMANTICS-004.b** — Candidate admission's outcome blame
  (`candidateBlame`) never names the supplier of a `localFailure` outcome.
- **NODE-SEMANTICS-004.c** — The portable-attachment decision blames on the
  bytes alone: an attachment that verifies is never blamed, even when the
  runtime generation or the session changed while it was checked.
- **NODE-SEMANTICS-004.d** — A store error thrown out of candidate admission
  never penalizes a peer.
  Gap: #213

## NODE-SEMANTICS-005 — only obtained invalid evidence is punishable

- **NODE-SEMANTICS-005.a** — Candidate admission blames only a complete
  `invalid` outcome, only its sole remote supplier, only while that
  supplier's session is ready, and only on Nexus or when the outcome carries
  a parent carrier link.
- **NODE-SEMANTICS-005.b** — A child-chain candidate rejected as `invalid`
  without a parent carrier link blames no one.
- **NODE-SEMANTICS-005.c** — Authenticated parent evidence establishes parent
  facts; it never vouches for a child transition.
  Gap: #213

## NODE-STORAGE-001 — peers and persistence exchange complete Volumes

- **NODE-STORAGE-001.a** — An object the session lacks is requested as its
  own Volume root, and one it already holds is never requested again.
- **NODE-STORAGE-001.b** — `content(rootCID:cids:)` never serves a selection
  of entries.
- **NODE-STORAGE-001.c** — `IvyRootContentSource.Session.fetch` makes a Volume
  visible only when its root is present and every entry's bytes match its
  CID; a Volume that fails is attributed to its supplier.
- **NODE-STORAGE-001.d** — `IvyRootContentSource.Session` accepts a response,
  fetched or initial, only for the root requested.
- **NODE-STORAGE-001.e** — A root's member set cannot change while the root
  is stored in the process's Volume store; eviction forgets it, so a root
  stored again after pruning is checked afresh. Membership is not checked
  against the root's DAG: a supplier may add correctly addressed entries,
  bounded by the session's member and byte limits.
- **NODE-STORAGE-001.f** — `IvyRootContentSource.response(_:from:)` passes a
  peer-served response only from the peer it asked (a failure passes
  through, whoever reported it).
- **NODE-STORAGE-001.g** — A complete Volume may span several bounded Ivy
  frames.
- **NODE-STORAGE-001.h** — Chunks from different requests, authenticated
  sessions, or runtime generations never combine.
  Gap: #218
- **NODE-STORAGE-001.i** — Partial assembly is never visible:
  `IvyRootContentSource.Session.fetch` returns every requested object or
  none.
- **NODE-STORAGE-001.j** — A session's initial response is checked as `fetch`
  checks a response: it is visible only when every entry's bytes match its
  CID, and one that fails is attributed to its supplier.
- **NODE-STORAGE-001.k** — `ChainProcessIvyContentSource` refuses every
  entry-level content request, and serves a Volume over the byte budget
  whole or not at all.
- **NODE-STORAGE-001.l** — The overlay transaction-Volume path refuses a
  Volume any of whose entries' bytes fail their CID, even an entry the
  transaction never references.
- **NODE-STORAGE-001.m** — The checks the other acquisition paths make before
  a session sees a response accept only the peer asked, the root requested
  and bytes that match their CIDs: the exact-peer source initializers' peer
  filter (the child-proof and attachment fetches use it), the candidate
  fetch source, the candidate initial-response check, and the peer and root
  checks of the transaction-Volume path.
  Gap: #218
- **NODE-STORAGE-001.n** — `IvyRootContentSource.Session` requests and
  stores each root at most once; a fetch of a root already in flight
  returns nothing rather than requesting it again.

## NODE-STORAGE-002 — a durable fact never outruns its content

- **NODE-STORAGE-002.a** — Block import merges its Volume roots into retention
  before it stages the fact batch that references them.
- **NODE-STORAGE-002.b** — Every other durable reference (issued evidence,
  parent-evidence inbox, issued child proof) is written after its complete
  Volume is stored and retained.
- **NODE-STORAGE-002.c** — Import pruning protection only grows while the node
  is live.
- **NODE-STORAGE-002.d** — Issued-hierarchy pruning protection only grows while
  the node is live.
- **NODE-STORAGE-002.e** — Prepared proof storage and its SQLite capacity
  eviction are serialized through one gate, which leaves exactly the kept
  proofs retained.
- **NODE-STORAGE-002.f** — The prepared retained set is advanced inside that
  gate, never after it is released.
- **NODE-STORAGE-002.g** — Contextual child offers live in a durable LRU in
  the store: touching an offer (`touchContextualCandidate`, or offering it
  again) makes it the newest, and the order survives reopening the store.
- **NODE-STORAGE-002.h** — An offer's roots are pinned before its index row is
  written.
- **NODE-STORAGE-002.i** — Offer eviction removes the oldest offer, whole.
- **NODE-STORAGE-002.j** — Offer eviction never touches a candidate marked as
  a handoff.
- **NODE-STORAGE-002.k** — Admission releases a handoff
  (`removeContextualCandidateIfAdmitted`) only once its admission batch owns
  every one of the handoff's roots; a batch that owns only some of them
  releases nothing. The handoff budget (002.l, 002.t) sheds handoffs without
  any admission.
- **NODE-STORAGE-002.l** — Storing a new offer sheds the oldest handoffs beyond
  the handoff budget.
- **NODE-STORAGE-002.m** — No parent reserves anything at a child, and no
  acknowledgement gates parent progress.
  Gap: #216 (no enforcement point: an absence across the hierarchy runtime)
- **NODE-STORAGE-002.n** — Canonicity never changes admission retention: a
  side block, and a block a reorg moves off the main chain, keep the
  retention their admission took, live and across a restart. The validated
  marker is a cache, not validity (002.o).
- **NODE-STORAGE-002.o** — The validated tier is a cache: an off-chain
  validated block beyond the operator's retention budget loses its validated
  marker and pin.
- **NODE-STORAGE-002.p** — A root shared by several offers stays pinned until
  the last of them is released.
- **NODE-STORAGE-002.q** — An accepted block's roots stay owned after the
  handoff that brought them is released.
- **NODE-STORAGE-002.r** — Proof acquisition is independent of offers and
  handoffs.
  Gap: #216 (no enforcement point identified)
- **NODE-STORAGE-002.s** — A candidate the parent's evidence names carried is
  marked as a handoff.
- **NODE-STORAGE-002.t** — Booting the node also sheds the oldest handoffs
  beyond the budget, row and pins together, as storing a new offer does
  (002.l).
- **NODE-STORAGE-002.u** — The process touches an offer each time a template
  carries it to the process again (`storeContextualCandidate`).
- **NODE-STORAGE-002.v** — `NodeImportStorage` records a Volume root only after
  its store returns: a store that throws leaves no root to retain or stage.
- **NODE-STORAGE-002.w** — Canonicity never changes exclusion.
  Gap: #216
- **NODE-STORAGE-002.x** — A template the service rebuilds from unchanged
  inputs reuses its cached candidate without reaching the process
  (`miningCandidate`), so that carry touches nothing. The cached candidate is
  the last one whose build completed; a build that stores its offer and then
  fails (`prepareChildProofs` throws) leaves a newer offer than the one the
  cache carries.
  Gap: #216

## NODE-MEMPOOL-001 — the mempool is tip-relative, not consensus

- **NODE-MEMPOOL-001.a** — A pool entry that fails the state transform
  (`StateErrors`) never suppresses a template: a failing chunk of
  transactions is bisected, and the valid rest is kept.
- **NODE-MEMPOOL-001.b** — Template assembly (`buildMiningTemplate`) builds on
  the validated tip, never on a heavier merely weighed canonical tip: a Nexus
  template and a child candidate both take the validated tip as parent and its
  height plus one.
- **NODE-MEMPOOL-001.c** — A local submission stores its complete transaction
  Volume before its SQLite reference.
- **NODE-MEMPOOL-001.d** — `ChainService.restoreLocalTransactions` brings every
  journaled local submission that still passes preflight back into the pool
  after a reopen; one that no longer does is dropped from the journal.
  Gap: #217 (the restart test journals a single transaction)
- **NODE-MEMPOOL-001.e** — Every pooled root holds exactly one live-pool pin,
  and no other root holds one, synced from the pool's current roots after
  every change: admission, replacement, eviction, inclusion, reorg re-add, and
  reset.
- **NODE-MEMPOOL-001.f** — Removing a local transaction removes its durable
  pin.
- **NODE-MEMPOOL-001.g** — Startup clears the live-pool owner.
- **NODE-MEMPOOL-001.h** — Restored local roots are pinned again after the
  live-pool owner is cleared.
- **NODE-MEMPOOL-001.i** — Only durable local roots are restored: a peer
  submission is never recovery authority.
- **NODE-MEMPOOL-001.j** — A peer submission stays serveable while pooled.
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
- **NODE-MEMPOOL-001.n** — The pool may retain, order, relay, replace, or retry
  transactions; only Lattice validation against the validated tip makes a
  transaction part of a template: admission, reconciliation and restore
  classify pool entries against the validated tip, not a weighed one.
  Gap: #228
- **NODE-MEMPOOL-001.o** — A local transaction a reorg returns to the pool is
  still local: it is journaled again and regains its durable pin.
  Gap: #227
