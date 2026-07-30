# Process trust model

## One process, one chain

Each process owns one absolute Nexus-inclusive chain path. External
orchestration decides which processes run; a node starts and supervises no
descendant processes.

The process topology follows direct chain relationships without collapsing
them into one runtime:

```text
Nexus process  ── authenticated facts ──▶  Nexus/Payments process
```

The parent owns only its own chain. The child owns only its own chain. Neither
process grants the other database access, enumeration, mutation, or consensus
authority. An accepted direct relationship may request an exact set of CAS
objects by CID; those read-only bytes are protocol availability, not access to
the process's storage interface.

## Configured parent route

A non-Nexus process must be started with both:

- its complete path, such as `Nexus/Payments`; and
- its immediate parent fact endpoint, such as
  `<nexus-process-key>@parent.example:4002`.

The configured endpoint is the authenticated immediate-parent process. It
serves two narrow local verdicts from its recovered graph of connected,
validated blocks: exact child deployment and forward state continuity. Those
verdicts are session-bound acknowledgements, not signed or portable
certificates. Nexus rejects a parent configuration because it is the single
root.

## Verify content independently

Transport identity and content validity answer different questions:

- The configured key answers: "did this local parent-chain verdict come from my
  configured immediate-parent process?"
- CIDs, proof of work, child-inclusion proofs, recursively validated state
  transitions, and consensus validation answer: "are these bytes valid?"

Arbitrary peers provide only content-addressed Volumes. They cannot provide a
parent verdict. The parent process derives a verdict only after validating its
own connected chain; the child never accepts a peer's claim that data was
validated. A deployment should normally run and validate its own parent process
recursively to Nexus. If an operator instead configures a remote parent process,
that process is an explicit trust boundary: authentication proves identity, not
honesty.

## Separate planes

Same-chain overlay traffic and parent/child facts use separate Ivy instances.
The hierarchy plane disables relay and carries only direct relationship facts.
This prevents a public overlay peer from becoming a parent merely by claiming a
path.

Direct children authenticate and advertise their absolute path on the hierarchy
plane. The parent may request a candidate or publish a proof only for an
immediate child whose path equals `parentPath + [directory]`.

Exact-CID exchange is explicitly enabled only on this private Ivy plane. A
connection must complete its own compatible hierarchy hello before it may read
content; reconnecting with the same key does not inherit the previous
connection's authorization. Requests cannot enumerate storage and must name a
complete bounded selection. The response is non-secret content-addressed
availability: the receiver verifies every CID and all Lattice evidence before
the bytes can affect state. Any accepted replica for a locally issued direct
child path may participate; a path claim remains routing, not branch authority.

During one bounded child-candidate round, the parent also serves the exact
provisional carrier only when that carrier CID is the request root. The lease
is reference-counted, scoped to the runtime generation, and removed after the
round. It is never persisted and cannot be smuggled into a request rooted at
unrelated durable content.

The hierarchy receiver gives its one configured immediate parent a narrow
transport-liveness exemption from its local Tally bucket. That exemption is
limited to the private plane's exact configured bootstrap key; it does not
weaken the hierarchy hello, path, authenticated-parent, fact, or Lattice
validation gates. Overlay peers and all other hierarchy peers remain
Tally-gated.

## Direct-edge retention, one-way authority

A direct parent-child commitment has one root-independent identity: parent
carrier CID, child directory, child CID, and canonical one-hop sparse proof.
The parent retains an edge when it issues that commitment. The child retains the
incoming edge after validation and may relay complete content-verified root
Volumes to same-chain peers.

No child sends an edge inventory, accepted topology, coverage claim, or work
back to its parent. The parent is child-agnostic outside bounded candidate and
proof publication. The child owns the exact vertical relation used for
consensus projection.
## Genesis authority

Nexus has no parent, so its genesis is constructed locally and pinned by CID:

`bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`

The CID is checked before configured root bootstrap, never used as a
peer-admission signature permit. Every child genesis is ordinary content bound
to a parent state. A prepared child intent becomes authoritative only after an
accepted parent block stores the exact `GenesisAction(directory, childCID)`.
The authenticated immediate-parent process acknowledges the exact tuple
`(directory, childCID, deploymentBlock.prevState)` from its durable accepted
facts, and the child requires its genesis `parentState` to equal that entering
state. The acknowledgement is unsigned, non-portable, and never persisted by
the child as peer authority.

Signature and signer fields inside a genesis block carry no authority and need
no special empty shape. The exact genesis CID is the authorization: local
configuration for Nexus and the parent action commitment for a child. Ordinary
transactions after genesis remain signature-strict.

## Parent-state continuity and work

For a non-genesis child candidate, equal parent-state references need no fact.
Otherwise the child asks its authenticated immediate-parent process whether the
new reference is transitively reachable from the predecessor's reference in
that process's connected, validated block graph. Parent canonicity does not
affect this immutable reachability fact. The response is a positive,
session-bound acknowledgement of the exact request; silence or timeout remains
retryable unavailability.

Grandparent validity is induction, not evidence relay. A parent block enters the
parent's durable graph only after the parent process has applied this same rule
against its own immediate parent. The child therefore never receives a
grandparent path or verdict. Recovery replays node-owned immutable
`ChainBlockFact`s and recomputes fork choice; it never restores a remote
certificate.

Work is not a parent assertion. Lattice derives it from the candidate's
content-addressed directory proof: the root grind must beat the terminal target
and commit uniquely to that child along the directory path. One grind counts at
most once at a chain-local location, independent grinds sum, and work affects
fork choice only after the terminal child is accepted and connected.

The parent therefore publishes no work totals, revisions, readiness marker, or
child topology. Data availability remains separate: Ivy and VolumeBroker move
proof Volumes, while each chain process independently validates its own blocks.
## Operational consequence

Treat `--parent` as the authenticated process boundary for immediate-parent
validity and as one route for availability. Other peers may supply identical
Volumes, but they cannot replace the live parent verdict needed for a new
parent-state movement. Keep process identity keys stable, restrict the hierarchy
port to intended relationships, and back up identity separately from wipeable
chain storage.

The parent acknowledgement authenticates a process identity, not honesty. It
is unsigned and non-portable by design, so a Byzantine configured parent can
equivocate between child nodes — reachable to one, silent to another — without
leaving cryptographic evidence. Accepting that residual is the price of
refusing light-client certificates; operators who cannot accept it run their
own parent processes recursively to Nexus.
