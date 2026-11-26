# Lattice node correctness invariants

The node-level claims that hold on the node runtime, each with a stable ID.
Each entry names the check that enforces it after every simulated step
(`Tools/LatticeNodeSim`) or the test that pins it.

The consensus invariants (weighed graph, executed set, GHOST, continuity)
are not listed here. They are the
[Lattice specification](https://github.com/0xLattice/Lattice/blob/59.3.0/docs/spec.md)'s
(§9.9 and §12), and the simulators check them with `Invariants.checkTree`
and `LevelInvariants.checkLevel`.

| ID | Claim |
|---|---|
| [NODE-SEMANTICS-003](#node-semantics-003--availability-is-retriable-not-punishable) | Availability is retriable, not punishable (a to e) |
| [NODE-SEMANTICS-005](#node-semantics-005--only-obtained-invalid-evidence-is-punishable) | Only obtained invalid evidence is punishable (a, b) |
| [NODE-STORAGE-002](#node-storage-002--content-is-stored-before-the-facts-that-name-it-and-a-fact-never-depends-on-it-being-held) | Content is stored before the facts that name it, and a fact never depends on it being held (a to l) |
| [NODE-MEMPOOL-001](#node-mempool-001--the-mempool-is-tip-relative-not-consensus) | The mempool is tip-relative, not consensus (a to e) |

IDs are stable and are not renumbered, which is why the numbering has
gaps.

## NODE-SEMANTICS-003 — availability is retriable, not punishable

- **NODE-SEMANTICS-003.a** — Content that cannot be resolved is no verdict:
  the block parks and its body is asked for again after a backoff, or at
  once when it may now be had (a block on it, or a new host); it is never
  excluded. Enforced by `Invariants.checkTree` ("excludes …, ground
  truth …": only invalid bodies are excluded) and `SimBodies.checkBodies`
  (every window block is asked for or parked, a parked body has a wake).
- **NODE-SEMANTICS-003.b** — A missing body, header or proof blames no peer;
  a stall frees the slot. Enforced by the simulators' "disconnected honest
  peer" check (`Simulator`, `LevelSimulator`), with withholders and lossy
  links in every run.
- **NODE-SEMANTICS-003.c** — A child block whose parent state its parent
  level has not executed waits, unvalidated, and wakes when it is.
  Enforced by `LevelInvariants.checkExecutionStop` (a stop is only at a
  block awaiting a fact its parent lacks; a held fact is a lost wake).
- **NODE-SEMANTICS-003.d** — A node-local failure while executing is
  retriable, never an exclusion. Pinned by
  `ChainCoreBodyTests.testALocalFailureIsNeverAnExclusion`.
- **NODE-SEMANTICS-003.e** — A child level asks its peers for nothing (no
  stream page, no header) while its parent level has not latched
  `headersSynced`: weighed a peer's whole log, whatever of it is executed
  (top-down weighing). The latch is one-way. Enforced by
  `LevelInvariants.checkLevel` ("a child level reads its peers before its
  parent weighed a whole log") and `LevelSimulator` ("still holds its peers
  back after its parent weighed a whole log"); pinned by
  `DerivedChildGrindTests.testASlowParentBodyDoesNotLatchSyncedAndTheChildOpens`,
  `DerivedChildGrindTests.testATransientBodyFailureDoesNotLatchSyncedAndTheChildOpens`,
  `DerivedChildGrindTests.testAPeerWhoseLogIsReplacedHasNotBeenReadToItsEnd`,
  `DerivedChildGrindTests.testAChildOpenedBeforeItsParentExecutesRunsOnceItDoes`,
  `DerivedChildGrindTests.testAChildLevelAsksItsPeersNothingWhileItsParentCatchesUpThenSyncsFully`
  and `DerivedChildGrindTests.testAfterTheLatchANewParentBlockDoesNotPauseTheChild`.

## NODE-SEMANTICS-005 — only obtained invalid evidence is punishable

- **NODE-SEMANTICS-005.a** — Only a proof-of-work failure blames: a header
  whose own work fails, or a peer-sent child proof that does not verify.
  Enforced by the simulators' "disconnected honest peer" check and the
  liar scripts (`LevelSimulationTests.testAZeroWorkProofIsNeverWeighedAndItsSenderIsBlamed`).
- **NODE-SEMANTICS-005.b** — Everything else malformed is dropped without
  blame, including a child genesis spec that is not the one it names and a
  proof check the shell cannot run. Pinned by
  `ChildGenesisSpecTests`.

## NODE-STORAGE-002 — content is stored before the facts that name it, and a fact never depends on it being held

- **NODE-STORAGE-002.a** — A step's content (headers, post-states, specs)
  is stored and retained before the facts that name it. Enforced by
  `SimBodies.checkStatesStored` and `Invariants.checkTree` ("weighed block
  … has no durable content").
- **NODE-STORAGE-002.b** — Nothing is published, served, relayed or
  streamed before it is durable. Enforced by `Simulator` and
  `LevelSimulator` ("published tip … is not durable", "served … before it
  was durable", "relayed … before it was durable").
- **NODE-STORAGE-002.c** — Content stays because a scope names it, and a
  start leaves pins as it finds them: nothing is rebuilt from the facts.
  A block's body is named by that block on its chain, what executions read
  and create by the chain. A start sweeps what no scope names. Pinned by
  `RetentionRulesTests`,
  `ChildLevelRestartTests.testAStartKeepsWhatAScopeNamesAndDropsTheRest`,
  `ChildLevelRestartTests.testAWeighedUnexecutedChildGenesisSurvivesARestart`
  and `NodeRuntimeTests.testJoinerSyncsHeadersAndExecutesBodiesOverLoopbackIvy`.
- **NODE-STORAGE-002.d** — Levels write parent before child; a crash
  between them restores with the child behind, never ahead. Pinned by
  `ChildLevelRestartTests.testACrashBetweenLevelWritesRestoresTheParentAhead`.
- **NODE-STORAGE-002.e** — Replaying the store reproduces the trees.
  Enforced by `Simulator.checkReplay` and `LevelSimulator.checkReplay`.
- **NODE-STORAGE-002.f** — Content a fact names and the store lacks is no
  fault. The node starts on its facts, with the Nexus genesis block stored
  again; executing a block and building on one read this store, a block's
  header record, then peers, checked against the CID; what peers served
  reaches the Volume store only as the Volumes this node derives when it
  stores a block, and only once the block's execution found it valid (a
  fetched body is read into memory until then, and read again whole from
  peers if memory let it go); retaining a root that is gone retains the rest.
  Content the store holds damaged is not lacked: the store serves this
  node's own reads it unhashed, and the read that checks it against its CID
  fails rather than falling through to peers. What the node sends, to a
  peer or a public reader, is checked first, and damaged content is
  answered as not held. A public read of a
  block body, or of content by CID, reads this store alone; a submitted
  transaction is checked against this store first, and state of the tip the
  store lacks is then read from peers (002.h).
  Pinned by `AbsentContentTests` and
  `SafetyNetCorruptStoreTests.testBootOpensAStoreWhoseVolumesAreGone`.
- **NODE-STORAGE-002.g** — With `blockBodies: none` the node lets go of a
  body it executed once another block is its chain's tip, and never of a
  genesis block. A tip the chain moves back onto after its body went is
  not fetched again. Transactions of the blocks a move leaves are returned
  to the pool from this store, and from peers for a body it let go of; one
  no peer serves is not returned. State and facts are untouched, and the node builds
  on a block whose body is gone. Pinned by `BlockBodiesTests`.
- **NODE-STORAGE-002.h** — With `state: recent` what a step's executions
  stored is named by its chain and the height of the step's newest block,
  and is let go of once the chain's tip is a state window or more above it
  (`--state-window`, 64 blocks unless the operator sets one, per chain or
  for every chain); `none` is a window of one block, and on `recent` a
  window is let go of only once the chain's counts reached the tip. A start
  lets go of the scopes and counts earlier versions kept a tip's state
  under. State the store lacks is read from peers by execution, preflight
  and state reads alike. Pinned by `StateWindowTests`.
- **NODE-STORAGE-002.i** — With `state: recent` or `none` what a stored
  block reads is named by that block until it executes or is found invalid
  (a start lets go of what an executed block's scope still names). Pinned
  by `StateWindowTests.testANodeOnNoneSyncsAndKeepsValidatingHoldingNoState`.
- **NODE-STORAGE-002.j** — A Volume the operator pins is named by the
  operator scope until it is unpinned, whatever the other rules keep. Pinned
  by `OperatorPinTests` and `DaemonHTTPTests.testOperatorPinRoutes`.
- **NODE-STORAGE-002.k** — With `state: recent`, once a chain's counts are
  in place, its counted scope counts each node for every place it holds in
  the act-on tip's state plus every place a block above the cursor
  replaced, the cursor on the tip's chain a window below the tip or higher;
  a move of the tip never lowers the cursor (a state sync may set it lower);
  every node it counts is held. The counts move with the tip in one
  adjustment under their marker; counts that cannot follow, that the store
  refuses, or that a check (at a start, and at a maintenance pass once they
  moved) finds do not match the store are
  replaced whole by a state sync, committed moved to the tip in one
  adjustment, the old ones serving until then. Pinned by
  `StateWindowTests.testTheCountsFollowEveryMoveOfTheTip` and the other
  `StateWindowTests` that check the counts.
- **NODE-STORAGE-002.l** — A chain the configuration does not host has its
  data let go of, live once its level stops and at every start (after
  `state.db` is validated): first its content, its own Volume store with
  everything in it, then its facts in one transaction. Content goes
  before facts, as a fact naming absent content is no fault (002.f): a
  release a stop or a failure cuts short leaves the chain's facts, which
  name it for the next start. What another chain needs is in its own
  store; the operator's pins are in the root's. A chain the configuration
  lists that did not start keeps its data. A running node lets go once
  the chain's level has stopped and its running jobs have ended; its
  queued jobs never run, and a write that comes for the chain after its
  store went finds none and writes nothing. Pinned by
  `HostChainsRuntimeTests.testAChainRemovedFromTheConfigurationHasItsDataLetGoOf`,
  `HostChainsRuntimeTests.testAChainAStartDoesNotHostHasItsDataLetGoOf`,
  `HostChainsRuntimeTests.testAReleaseCutShortIsFinishedAtTheNextStart`,
  `HostChainsRuntimeTests.testAChainDroppedWhileItsBlockExecutesIsLetGoOfAfter`,
  `OperatorConfigTests.testAChainThatDidNotStartIsDroppedWhenNoLongerListed`,
  `RetentionCrashTests.testACrashWhileAChainIsLetGoRecoversOnTheNextStart`
  and `LatticeCtlE2ETests.testAChildChainIsCreatedMergeMinedTransactedAndResumedThroughTheCLI`.

## NODE-MEMPOOL-001 — the mempool is tip-relative, not consensus

- **NODE-MEMPOOL-001.a** — Templates and preflights build on the executed
  tip, never a heavier weighed one. Enforced by `TxWorkload.checkInvariants`
  ("mining builds on a tip that is not the executed tip") and the template
  check ("template issued off the executed tip").
- **NODE-MEMPOOL-001.b** — A pool entry already on the executed chain is
  removed. Enforced by `TxWorkload.checkInvariants` ("pool holds …, already
  on the executed chain").
- **NODE-MEMPOOL-001.c** — The pool holds one transaction per first signer's nonce
  and stays within its limits. Enforced by `TxWorkload.checkInvariants`.
- **NODE-MEMPOOL-001.d** — The local journal is the pool's local set, and a
  pool change is durable before any later effect. Enforced by
  `TxWorkload.checkOrder` and `TxWorkload.checkInvariants` ("journal …
  diverged").
- **NODE-MEMPOOL-001.e** — A transaction goes to the pool of the chain it
  names. Pinned by `MergedMiningTests.testOneGrindAdvancesNexusAndItsHostedChild`.
