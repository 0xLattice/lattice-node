# Correctness invariants

The node-level claims that still hold on the node runtime. Each entry names
the check that enforces it after every simulated step (`Sources/LatticeNodeSim`)
or the test that pins it. The consensus invariants (weighed graph, executed
set, GHOST, continuity) are the architecture doc's and are checked by
`Invariants.checkTree` and `LevelInvariants.checkLevel`.

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

- **NODE-STORAGE-002.a** — A step's content (headers, specs) is stored and
  retained before the facts that name it, and a flush's post-states before
  the verdicts that name them. Enforced by `SimBodies.checkStatesStored` (at
  each of `Simulator`'s flushes, every verdict names a whole stored state;
  it stores a state when its execution runs, so the order of the flush's
  two writes is kept by `NodeStorage.flush`, not checked) and
  `Invariants.checkTree` ("weighed block … has no durable content").
  `DerivedCacheRestartTests.testACrashAtEachPointRestartsToTheSameTipAndState`
  restarts from what the first write alone leaves.
- **NODE-STORAGE-002.b** — No block is published, served, relayed or
  streamed before it is durable. What its execution decided is a cache over
  it, published from memory and durable at the next flush: after a crash
  the act-on tip may be the last flush's, below the one published. Enforced
  by `Simulator` and `LevelSimulator` ("published tip … is not durable",
  "served … before it was durable", "relayed … before it was durable").
- **NODE-STORAGE-002.c** — Content stays because a scope names it, and a
  start leaves pins as it finds them: nothing is rebuilt from the facts.
  A block's body is named by that block on its chain, what executions read
  and create by the chain. A start sweeps what no scope names. Pinned by
  `RetentionRulesTests`,
  `ChildLevelRestartTests.testAStartKeepsWhatAScopeNamesAndDropsTheRest`,
  `ChildLevelRestartTests.testAWeighedUnexecutedChildGenesisSurvivesARestart`
  and `NodeRuntimeTests.testJoinerSyncsHeadersAndExecutesBodiesOverLoopbackIvy`.
- **NODE-STORAGE-002.f** — Content a fact names and the store lacks is no
  fault. The node starts on its facts, with the Nexus genesis block stored
  again; executing a block and building on one read the post-states held
  for the next flush, this store, a block's header record, then peers,
  checked against the CID; what peers served
  reaches the Volume store only as the Volumes this node derives when it
  stores a block, and only once the block's execution found it valid (a
  fetched body is read into memory until then, and read again whole from
  peers if memory let it go); retaining a root that is gone retains the rest.
  Content the store holds damaged is not lacked: the store serves this
  node's own reads it unhashed, and the read that checks it against its CID
  fails rather than falling through to peers. What the node sends, to a
  peer or a public reader, is checked first, and damaged content is
  answered as not held. The checks anyone
  can cause (a submitted transaction, a public read) read what this node
  holds alone: the post-states held for the next flush, then this store.
  Pinned by `AbsentContentTests` and
  `SafetyNetCorruptStoreTests.testBootOpensAStoreWhoseVolumesAreGone`.
- **NODE-STORAGE-002.g** — With `blockBodies: none` the node lets go of a
  body it executed once another block is its chain's tip as of the last
  flush, and never of a
  genesis block. A tip the chain moves back onto after its body went is
  not fetched again. Transactions of the blocks a move leaves are returned
  to the pool from this store, and from peers for a body it let go of; one
  no peer serves is not returned. State and facts are untouched, and the node builds
  on a block whose body is gone. Pinned by `BlockBodiesTests`
  (`testAMinerOnNoneHoldsOnlyItsTipsBody` holds each body until a flush).
- **NODE-STORAGE-002.h** — With `state: recent` what a flush stored of an
  execution is named by its chain and its block's height, and is let go of
  once the chain's tip as of the last flush is a state window or more above
  it
  (`--state-window`, 64 blocks unless the operator sets one, per chain or
  for every chain); `none` is a window of one block, and on `recent` a
  window is let go of only once the chain's counts reached the tip. A start
  lets go of the scopes and counts earlier versions kept a tip's state
  under. State the store lacks is read from peers by execution, preflight
  and state reads alike. Pinned by `StateWindowTests`.
- **NODE-STORAGE-002.k** — With `state: recent`, once a chain's counts are
  in place, its counted scope counts each node for every place it holds in
  the state of the act-on tip as of the last flush, plus every place a
  block above the cursor
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
- **NODE-STORAGE-002.i** — With `state: recent` or `none` what a stored
  block reads is named by that block until a flush writes its execution or
  its exclusion (a start lets go of what the scope of a block executed as
  of the last flush still names). Pinned
  by `StateWindowTests.testANodeOnNoneSyncsAndKeepsValidatingHoldingNoState`.
- **NODE-STORAGE-002.j** — A Volume the operator pins is named by the
  operator scope until it is unpinned, whatever the other rules keep. Pinned
  by `OperatorPinTests` and `DaemonHTTPTests.testOperatorPinRoutes`.
- **NODE-STORAGE-002.d** — What a step weighed commits across every level
  in one transaction, and a flush's verdicts likewise: a crash never leaves
  a child's execution durable without the parent's it read. Enforced by
  `LevelSimulator.checkReplay`; pinned by
  `DerivedCacheRestartTests.testAChildChainOnlyThisNodeHostsExecutesAgainFromItsOwnStore`.
- **NODE-STORAGE-002.e** — Replaying the store as of a flush reproduces the
  trees; replaying it after a crash gives every block weighed, executed as
  of the last flush, and the node executes the rest again from what it
  stores, reading no clock but for a genesis. Enforced by
  `Simulator.checkReplay` and `LevelSimulator.checkReplay` at flush points,
  on stores that keep of an execution only its verdict, as the node's does
  (`SimStore.flush`); pinned by `DerivedCacheRestartTests`.

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
- **NODE-MEMPOOL-001.d** — The local journal holds the pool's local set: a
  row is durable before any later effect of its admission, and the row of a
  transaction that left the pool goes with the next flush unless the
  transaction is pooled again first (geth's journal holds the pool's
  locals at `rotate`), so between flushes the journal may also hold rows
  the pool let go of, never fewer. A start judges each chain's rows once
  that chain has executed again the blocks it holds, or found it cannot
  from what the node holds, and its parent chain's replay is over
  (Bitcoin's `LoadMempool` after `ActivateBestChain`), on the tip they
  reach rather than the last flush's; the transactions of a block it did
  not execute again go back to the pool, as a reorganization's do. Enforced by
  `TxWorkload.checkOrder` and `TxWorkload.checkInvariants` ("journal …
  diverged", on the pool's deltas). Pinned by
  `ChainCoreMiningTests.testTheJournalWaitsForWhatTheStartExecutesAgain`,
  `ChainCoreMiningTests.testABlockTheStartLeftGivesItsTransactionsBack`,
  `ChainCoreMiningTests.testABlockTheStartCannotExecuteDoesNotHoldTheJournal`,
  `DerivedCacheRestartTests.testAJournaledTransactionIsJudgedOnceTheStartHasExecutedAgain`,
  `DerivedCacheRestartTests.testAChildsJournalWaitsForItsParentsReplay`,
  `DerivedCacheRestartTests.testAChildsJournalIsJudgedOnceItsParentsReplayLeftTheCarrier`,
  `DerivedCacheRestartTests.testAConfirmedTransactionsJournalRowGoesWithTheFlush`
  and `DerivedCacheRestartTests.testARowStaysWhenItsTransactionIsPooledAgainBeforeTheFlush`.
- **NODE-MEMPOOL-001.e** — A transaction goes to the pool of the chain it
  names. Pinned by `MergedMiningTests.testOneGrindAdvancesNexusAndItsHostedChild`.
