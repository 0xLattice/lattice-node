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
  packages in-process.
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
- a durable canonical commit reserves reconciliation before a later template,
  transaction, or child intent can observe the new chain state;
- optional child-proof materialization never suppresses canonical publication;
- one physical grind contributes at most its strongest target-derived quantity
  to one chain-local location; distinct grinds sum, and replay cannot multiply
  weight;
- evidence inventories retain their exact cursor across
  transient Ivy/Tally pressure on a live parent session;
- a failed hierarchy hello or durable evidence hint recycles only that exact
  session; reconnect repeats authorization and the complete evidence index;
- proof recovery on a connected noncanonical carrier is announced after an
  already-completed empty index without changing the parent's canonical tip;
- a parent remains child-agnostic: child topology and derived weight stay in
  the child process and are never returned upstream;
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
- parent-state continuity is reflexive and transitive over connected accepted
  parent history, including noncanonical branches, and exact parent facts may
  be relayed by same-chain peers after restart;
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
