# Correctness invariants

The node-level claims that still hold on the node runtime. Each entry names
the check that enforces it after every simulated step (`Sources/LatticeNodeSim`)
or the test that pins it. The consensus invariants (weighed graph, executed
set, GHOST, continuity) are the architecture doc's and are checked by
`Invariants.checkTree` and `LevelInvariants.checkLevel`.

## NODE-SEMANTICS-003 — availability is retriable, not punishable

- **NODE-SEMANTICS-003.a** — Content that cannot be resolved is no verdict:
  the block parks and its body is asked for again after a backoff; it is
  never excluded. Enforced by `Invariants.checkTree` ("excludes …, ground
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

- **NODE-STORAGE-002.a** — A step's content (headers, post-states, specs)
  is stored and retained before the facts that name it. Enforced by
  `SimBodies.checkStatesStored` and `Invariants.checkTree` ("weighed block
  … has no durable content").
- **NODE-STORAGE-002.b** — Nothing is published, served, relayed or
  streamed before it is durable. Enforced by `Simulator` and
  `LevelSimulator` ("published tip … is not durable", "served … before it
  was durable", "relayed … before it was durable").
- **NODE-STORAGE-002.c** — Content stays because a scope names it, and a
  start leaves pins as it finds them: nothing is rebuilt from the journal.
  A block's body is named by that block, what executions read and create
  by the chain, a block this node built by a name of its own until a fact
  records it. A start gives a recorded built block its body's name, lets go
  of one no fact records, and sweeps what no scope names. Pinned by
  `RetentionRulesTests`,
  `ChildLevelRestartTests.testAStartKeepsWhatAScopeNamesAndDropsTheRest`,
  `ChildLevelRestartTests.testAWeighedUnexecutedChildGenesisSurvivesARestart`
  and `NodeRuntimeTests.testJoinerSyncsHeadersAndExecutesBodiesOverLoopbackIvy`.
- **NODE-STORAGE-002.f** — Content a fact names and the store lacks is no
  fault. The node starts on its facts, with the Nexus genesis block stored
  again; executing a block and building on one read this store, a block's
  header record, then peers, checked against the CID; what peers served
  reaches the Volume store only as the Volumes this node derives when it
  stores a block; retaining a root that is gone retains the rest. The checks anyone
  can cause (a submitted transaction, a public read) read this store alone.
  Pinned by `AbsentContentTests` and
  `SafetyNetCorruptStoreTests.testBootOpensAStoreWhoseVolumesAreGone`.
- **NODE-STORAGE-002.g** — With `blockBodies: none` the node holds a body
  only while its block waits to execute or is its chain's tip, and each
  genesis block always; a body a job is reading goes when the job has read
  it. State and facts are untouched, and the node builds on a block whose
  body is gone. Pinned by `BlockBodiesTests`.
- **NODE-STORAGE-002.d** — Levels write parent before child; a crash
  between them restores with the child behind, never ahead. Pinned by
  `ChildLevelRestartTests.testACrashBetweenLevelWritesRestoresTheParentAhead`.
- **NODE-STORAGE-002.e** — Replaying the store reproduces the trees.
  Enforced by `Simulator.checkReplay` and `LevelSimulator.checkReplay`.

## NODE-MEMPOOL-001 — the mempool is tip-relative, not consensus

- **NODE-MEMPOOL-001.a** — Templates and preflights build on the executed
  tip, never a heavier weighed one. Enforced by `TxWorkload.checkInvariants`
  ("mining builds on a tip that is not the executed tip") and the template
  check ("template issued off the executed tip").
- **NODE-MEMPOOL-001.b** — A pool entry already on the executed chain is
  removed. Enforced by `TxWorkload.checkInvariants` ("pool holds …, already
  on the executed chain").
- **NODE-MEMPOOL-001.c** — The pool holds one transaction per signer nonce
  and stays within its limits. Enforced by `TxWorkload.checkInvariants`.
- **NODE-MEMPOOL-001.d** — The local journal is the pool's local set, and a
  pool change is durable before any later effect. Enforced by
  `TxWorkload.checkOrder` and `TxWorkload.checkInvariants` ("journal …
  diverged").
- **NODE-MEMPOOL-001.e** — A transaction goes to the pool of the chain it
  names. Pinned by `MergedMiningTests.testOneGrindAdvancesNexusAndItsHostedChild`.
