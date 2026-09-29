# Process trust model

## One process, one chain tree

One `lattice-node` process hosts a chain tree: one level per absolute
Nexus-inclusive chain path, each child co-hosted with its whole ancestry
(`ChainHost`). The levels come from `lattice.json` (`--config`); a node spawns
no other processes.

The levels follow direct chain relationships without collapsing them into one
chain runtime:

```text
Nexus level  ── in-process facts; evidence dialed on loopback ──▶  Nexus/Payments level
```

The parent level owns only its own chain. The child level owns only its own
chain. Neither grants the other database access, enumeration, mutation, or
consensus authority. A child reads its parent facts through the narrow
`ParentLevel` view, and a parent reads a child only through `ChildLevel`
(its latest candidate, and enqueue-only notifications). An accepted direct
relationship may request an exact set of CAS objects by CID; those read-only
bytes are protocol availability, not access to the level's storage interface.

## Co-hosted parent level

A non-Nexus chain runs only in the same `lattice-node` process as its whole
ancestry. The host wires its parent endpoint to the co-hosted parent level's
hierarchy plane, dialed on loopback, which carries only child evidence. The
listener binds all interfaces, so firewall the hierarchy port.

The co-hosted parent level answers two narrow facts from its own validated
state, read in-process: exact child deployment and forward state continuity
(a state the parent executed from genesis). They are local reads, not signed or
portable certificates. Nexus has no parent level because it is the single
root.

## Verify content independently

Transport identity and content validity answer different questions:

- The host answers: "did this parent-chain verdict come from my co-hosted
  parent level?" It is the node's own validation of its own parent chain.
- CIDs, proof of work, child-inclusion proofs, recursively validated state
  transitions, and consensus validation answer: "are these bytes valid?"

Arbitrary peers provide only content-addressed Volumes. They cannot provide a
parent verdict. The parent level derives a verdict only after validating its
own connected chain; the child never accepts a peer's claim that data was
validated. Because every child is co-hosted with its ancestry, the node
validates its own parent chains recursively to Nexus; there is no remote
parent to trust.

## Separate planes

Same-chain overlay traffic and parent/child evidence use separate Ivy
instances. The hierarchy plane is dialed on loopback between co-hosted levels
(the listener binds all interfaces, so firewall the hierarchy port), disables
relay, and carries only child-evidence delivery; parent facts, run
reports, and candidates pass in-process. A public overlay peer therefore
cannot become a parent merely by claiming a path.

Direct children authenticate and advertise their absolute path on the
hierarchy plane. The parent grants the child role only to the process key of
the child level the host runs for that directory, whose path equals
`parentPath + [directory]`; any other key claiming a child path is refused.
The parent publishes a proof only to that child.

Exact-CID exchange is explicitly enabled only on this private Ivy plane. A
connection must complete its own compatible hierarchy hello before it may read
content; reconnecting with the same key does not inherit the previous
connection's authorization. Requests cannot enumerate storage and must name a
complete bounded selection. The response is non-secret content-addressed
availability: the receiver verifies every CID and all Lattice evidence before
the bytes can affect state.

The hierarchy receiver gives its co-hosted parent level a narrow
transport-liveness exemption from its local Tally bucket. That exemption is
limited to the private plane's exact parent key; it does not
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
back to its parent. Downstream, the parent level maintains run state for the
directories it hosts (spec §9.10) and hands each carrier's run to that
directory's child level in-process, beside proof publication; upstream, it
learns nothing but each hosted child's latest candidate. The child owns the exact vertical relation used for
consensus projection.
## Genesis authority

Nexus has no parent, so its genesis is constructed locally and pinned by CID:

`bafyreifvxwhqbwvnrtr2plvtmlvpceqxnexyayjs7klgy6dbkj7yppdsz4`

The CID is checked before configured root bootstrap, never used as a
peer-admission signature permit. Every child genesis is self-contained content
that commits to the empty parent state. It becomes authoritative only after an
accepted parent block stores the exact `GenesisAction(directory, childCID)`.
The co-hosted parent level answers for the exact tuple
`(directory, childCID, empty parent state)` from its durable accepted facts
before the child imports that genesis. The answer is a local read: unsigned,
non-portable, and never persisted by the child as peer authority.

Signature and signer fields inside a genesis block carry no authority and need
no special empty shape. The exact genesis CID is the authorization: local
configuration for Nexus and the parent action commitment for a child. Ordinary
transactions after genesis remain signature-strict.

## Parent-state continuity and work

For a non-genesis child candidate, equal parent-state references need no fact.
Otherwise the child reads, from its co-hosted parent level, whether the parent
executed from its genesis a block producing the candidate's `parentState`.
Parent canonicity does not affect this immutable fact. A fact the parent
level does not hold yet parks the candidate until the parent's tip moves; it
is retryable unavailability, never a refusal.

Grandparent validity is induction, not evidence relay. A parent block enters the
parent's durable graph only after the parent level has applied this same rule
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
proof Volumes, while each chain level independently validates its own blocks.
## Operational consequence

Treat the co-hosted parent level as the only source of immediate-parent
validity; its loopback endpoint is one route for availability. Other peers may
supply identical Volumes, but they cannot replace the parent level's fact
needed for a new parent-state movement. Keep each level's identity key stable,
firewall the hierarchy port (no remote peer needs it), and back up identity separately from
wipeable chain storage.

A child trusts its parent level as it trusts its own binary: a bug in parent
validation reaches the child directly, with no second implementation in
between. There is no remote parent whose answer could differ between child
nodes, and no light-client certificate.
