# Testing

Run the complete node, daemon, coordinator, and worker suite with:

```sh
swift test
```

The suites are grouped by the boundary they actually cross:

- `NodeStoreTests`: atomic admission, crash recovery, retained hierarchy
  evidence, immutable-index audit, and Volume ownership.
- `ChainProcessTests`: one-path admission, restart, child bootstrap, proof composition, cancellation, and explicit local-versus-network acquisition boundaries.
- `NetworkTrustTests`: real-network integration tests, not E2E. They exercise
  overlay/fact-plane separation, bounded/canonical wire input, real
  peer-to-runtime async delegate delivery, root-scoped content attribution,
  per-connection hierarchy authorization, lifecycle fencing, proof
  distribution, and session-bound immediate-parent fact authentication.
- `MultichainInvariantTests`: direct-parent-only package acceptance, ancestor-path rejection, and durable exact-edge recovery across process reopen.
- `ChainServiceTests`: transaction, child-deploy, template, work-submission, reconciliation ordering, and publication despite optional hierarchy availability failures.
- `DaemonHTTPTests`: real loopback HTTP route contracts.
- `LatticeNodeE2ETests`: black-box independent node processes. Tests may only
  start, stop, suspend, and configure shipped processes; call public HTTP
  endpoints; run the shipped miner/coordinator; or participate as a real Ivy
  peer. A transparent TCP fault proxy may cut and heal a real node link without
  inspecting or altering its protocol bytes. Tests never instantiate
  `ChainProcess`, mutate stores, install runtime callbacks, or seed internal
  consensus state. They exercise direct-child
  bootstrap/restart, proof availability from same-chain peers, parent-fact
  retry across disconnect, reopen with every source offline, three-level proof
  traversal, a suspended
  non-responsive authenticated sibling, durable side-branch bootstrap after a
  reorg, same-path higher-work and segment-base-tie convergence, and a live competing-genesis
  reorg followed by noncanonical parent descendants that must remain at their
  own locations instead of flowing through an ancestor carrier; a second
  same-path replica reconnects late and reaches the same result from its
  durable cursor and the parent's current export. The exchange
  scenarios run real Nexus and child
  daemons: one pits wrong-withdrawer, replay, and overclaim withdrawals against
  a fee-prioritized valid variable-rate claim, while another settles two child
  chains through one co-signed Nexus transaction, moves Nexus to a strictly
  heavier conflicting-nonce branch that excludes the settlement, and spends
  both already-withdrawn child proceeds from the winning parent branch. These
  tests use only public HTTP APIs and Ivy sockets; they do not inject parent
  packages in-process. The operator-CLI scenarios (`LatticeCtlE2ETests`,
  opt-in with `E2E_CTL=1`, their own CI lane) drive the shipped `lattice`
  verbs with real CPU mining: multichain hosts that sync, child and grandchild
  token swaps, deploy interruption and resumption, and §9.10 run attribution
  through three nodes across a middle-chain outage — full Nexus blocks mined
  by hand through the coordinator's RPC carry both descendants, Nexus then
  mines alone while the middle chain's node is down, the returning node is
  credited that work and pushes it to the grandchild, and the grandchild's
  credit survives a crash restart
  (`testNexusWorkReachesTheGrandchildAcrossAMiddleChainOutage`). The
  coordinator is stopped for that phase because it hunts the easiest target
  and so also produces child-only carriers, whose child blocks have no chain
  committer to be credited through. A second scenario keeps the coordinator
  mining and stops the middle chain's node mid-round, the deploy case that
  cut a deferred parent-carried block off from its retry: after the restart
  the node must be credited the outage work, which only that block's
  committer can deliver
  (`testChildStoppedDuringCoMiningIsCreditedAfterRestart`).
- `LatticeMinerCoreTests` and `LatticeMiningCoordinatorTests`: nonce search, work allocation, staleness, subprocess cancellation, and current RPC payloads.

The test bar is boundary-focused rather than timing-focused. Tests inject missing
content, blocked acquisition, cancellation, restart, and publication failure at
the component that owns the consequence. In particular, they preserve these
cross-component invariants:

- only traced network admission may acquire remote content; RPC, mining, and
  reconciliation fail locally rather than fetching peers;
- securing work comes only from a verified directory proof, while
  parent-state continuity comes only from an exact authenticated reachability
  fact; neither data availability nor parent canonicity substitutes for either;
- each root-scoped acquisition gets an independent cashew coalescer, so one
  candidate cannot inherit another candidate's Ivy attribution;
- a hierarchy connection cannot read CAS content before its own compatible
  hello, and a provisional carrier can be served only as its leased request
  root and is never persisted;
- a durable canonical commit reserves reconciliation before a later template
  or transaction can observe the new chain state;
- optional child-proof materialization never suppresses canonical publication;
- a verified observation of one physical grind whose root hash clears the
  terminal child's target credits exactly `workForTarget` of the root-most
  target it cleared along that proof, raised if greater by the terminal
  child's own (never a max over every cleared target; Lattice 35.0.1, spec
  §9.5); an observation that does not clear the terminal target credits
  nothing; one chain-local location holds the strongest such observation;
  distinct grinds sum, and replay cannot multiply weight;
- evidence inventories retain their exact cursor across
  transient Ivy/Tally pressure on a live parent session;
- a failed hierarchy hello or durable evidence hint recycles only that exact
  session; reconnect repeats authorization and the complete evidence index;
- proof recovery on a connected noncanonical carrier is announced after an
  already-completed empty index without changing the parent's canonical tip;
- nothing flows upstream: child topology and derived weight stay in the child
  process and are never returned to a parent; a parent maintains run state only
  for the directories it hosts (spec §9.10) and serves it downstream;
- a child restarted after acknowledging a contextual candidate reservation
  still serves that exact candidate from durable Volumes; more than one
  offer window of abandoned parent carriers cannot evict an issued candidate,
  and a later exact snapshot releases obsolete offers and reservations;
- parent admission hands each committed child CID off in the authenticated
  reservation update before release, so asynchronous proof delivery and
  garbage collection cannot race away the candidate;
- successor attachments received before child genesis wait on their exact
  same-chain predecessor instead of being misclassified as malformed genesis;
- a suspended authenticated direct child cannot block a healthy sibling's
  bounded root round;
- parent-state continuity is reflexive and transitive over connected, executed
  parent history, including noncanonical branches, and exact parent facts may
  be relayed by same-chain peers after restart;
- a parent's run report is credited only at the child block it commits, bound
  to the child's own directory and to one of the committer's grinds already
  credited there, as `runWork − ownWork` under an identity keyed by the
  committer and directory, once — a repeat is refused, never doubled — and the
  credit survives the child's restart from its durable fact log
  (`testParentRunWorkIsCreditedAtTheChildBlockItCommits` in the multichain
  invariants), and admitting a block a parent block carried asks the parent
  for that committer's run, so a push made before the block was held here,
  or one missed while away, never waits for the next parent block; a
  parent-carried block is admitted weighed on its proof, its relay link
  persisted with the acceptance (child-proof recovery composes from that
  evidence and reads the link beside it; a link it does not find is not a
  reason to refuse to boot), and until an
  admission decides it its evidence stays in the parent-evidence inbox — a
  deferral persists nothing, the entry survives a restart and the block is
  accepted once the rule is met; a carrier refused for good is relayed and
  consumed and never re-admitted; a refusal with no carrier link to relay is
  consumed all the same, and decided is exactly the set the acquirer never
  retries; a restarted child admits the block from its inbox alone,
  weighed, with content served by the parent; no admission of a block
  reached through an overlay portable attachment is eager
  (`testDeferredCarriedBlockKeepsItsEvidenceInTheInboxAcrossRestart`,
  `testCarrierRefusedForGoodIsDecidedAndConsumed`,
  `testDecidedRefusalWithoutACarrierLinkIsConsumed`,
  `testDecidedIsExactlyWhatTheAcquirerNeverRetries`,
  `testRestartedChildAdmitsTheParentCarriedBlockFromItsInboxWeighed`,
  `testPortableAttachmentsKeepDistinctRootsForTheSameChildWhileAdmissionIsBlocked`);
  a child whose reservation was refused or timed out is asked again — the
  next reconcile visits every dirty child, whether or not anything is
  desired of it (`testRefusedReservationLeavesTheChildAskableAgain`); a
  handed-off candidate's children are relayed down only while the handoff
  is in flight, not once the candidate is an accepted block
  (`testCompletedHandoffStopsRelayingItsChildren`); a run
  flows through every level — what Nexus attributes to the middle chain's
  committing block reaches the grandchild, and the middle chain's service
  pushes the run that credit changed to its own children without waiting
  for a re-ask (`testParentRunWorkPropagatesTwoLevelsDown`);
- staged facts and retained Volume roots reopen together, or recovery fails
  closed.

Keep concurrency tests deterministic: assert explicit latches, persisted
facts, or recorded content requests. Cashew owns the lower-level best-effort
batching algorithm tests; lattice-node tests the source and root boundaries
that decide which content is allowed to batch.

Consensus validation and signature compatibility live in the Lattice dependency and are tested in that repository; the direct process E2E additionally confirms that a legacy body-CID signature still reaches that validator through public node ingress. Storage and transport primitives are likewise tested in VolumeBroker, cashew, Ivy, and Tally. This repository pins those released revisions and tests their node-facing integration; their complete suites remain owned by their own release gates.

During release-bundle assembly, `.github/scripts/smoke-lattice-node.sh` runs
against the bundle's node, coordinator, and miner. After the archive is
assembled, the release workflow extracts it and reruns `LatticeNodeE2ETests`
against the archived `lattice-node` executable. The smoke test verifies the
exact Nexus genesis, mines and persists one block through the external mining
pipeline, then restarts the shipped node and verifies the same tip.
