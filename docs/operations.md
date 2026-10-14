# Operations runbook

## Deployment model

Run one `lattice-node` process for the configured Nexus-rooted tree. The
process owns:

- one long-lived identity key;
- one Ivy overlay listener;
- one loopback operator RPC;
- optionally one public-read listener (GET-only unless public submit is on);
- one `state.db` and `volumes.db` recovery unit.

Run mining outside the node with `lattice-mining-coordinator` and one or more
workers. Use a supervisor for both processes.

## Preflight checklist

Before exposing a node:

1. Build or install one reviewed revision and run its tests.
2. Create `lattice.json` with `lattice init`; do not reuse an older schema.
3. Protect `identity/Nexus.key` as mode `0600` and back it up separately.
4. List hosted paths parent first and keep each child spec immutable.
5. Configure at least two independent bootstrap peers.
6. Set `externalAddress` when the observed source address is not dialable.
7. Keep RPC on loopback. Use `publicRead` or the checked-in nginx allowlist for
   public reads.
8. Configure a mining recipient for every chain that should pay rewards.
9. Reserve enough disk for unbounded fact history and retained content, or
   set `blockBodies` and `state` (see "What a node keeps").
10. Test a clean shutdown, restart, and recovery before accepting traffic.

## How a node finds the network

Every hosted chain, Nexus and each child alike, keeps its own peers by the
same routine. A chain's current peers are the open sessions that serve it:
every session for Nexus, since every node hosts it; for a child, the sessions
whose peer says it hosts that chain. Sessions themselves are shared: one
connection to a peer serves every chain that peer hosts.

On each maintenance pass, each chain in turn, Nexus first:

1. **Counts its current peers.**
2. **Dials peers it remembers** for that chain (`peers.json`, below), up to
   four, while it has fewer than eight current peers or has stopped
   progressing.
3. **Discovers.** A child chain with no current peer, or one that has stopped
   progressing, looks up its rendezvous among its parent's peers and dials up
   to four of the hosts named there (see "Discovery and peer health").
4. **Dials its seeds**, only while it still has fewer than two current peers.
   Nexus's seeds are the built-in ones: by name, `seed1.lattice.build` to
   `seed4.lattice.build` on port 4001, then the same seeds at fixed addresses
   for when names cannot be resolved. A child's seeds are the list its
   operator gave it, if any.

A peer is dialled once however many chains want it. The two thresholds are
operator choices, applied to each chain on its own: `--peer-target` (8) and
`--peers-before-seeds` (2).

The levels differ only in where discovery asks. A child asks the peers of its
parent who serves it; Nexus has no parent, so its seed list stands in for one.

A seed is an introduction, not a peer the node depends on. A chain that
already knows its network rejoins through what it remembers and does not ask
a seed at all, so the seeds shape the network as little as possible and carry
only the nodes that need them. Left with fewer than two Nexus peers at any
time, the node looks again within seconds rather than at the next maintenance
interval.

### Configured peers

`peers` in `lattice.json` is keyed by chain path:

```json
"peers": {
  "Nexus": ["<public-key>@node.example:4001"],
  "Nexus/Alpha": ["<public-key>@alpha-host.example:4001"]
}
```

- **Nexus's list** replaces the built-in seeds: those peers are dialled from
  the start and kept, and that is all the node is told. An empty list means
  connect to no one. Absent, Nexus uses the built-in seeds.
- **A child chain's list** is extra seeds for that chain, beside what it
  finds through its parent: dialled only on need, as step 4 above, and
  remembered like any other peer once reached. An empty list is the same as
  none. The chain must be hosted.
- An array, `"peers": ["<public-key>@node.example:4001"]`, is Nexus's list.

Going back to an older node: a node from before chains had peers of their own
reads `peers` only as an array, and refuses to start on the keyed form. The
file is written keyed only once a child chain has a list, so a host that never
gave a child a list can go back as it is. Otherwise keep a copy of
`lattice.json` from before the upgrade, or rewrite `peers` as Nexus's array
(dropping the child lists) before starting the older node.

### Seed names

Each name is a DNS alias the project keeps, pinned to the identity of the host
behind it; the binary never names a hosting provider.

| Name | Alias of | Fixed address | Identity (public key) |
|---|---|---|---|
| `seed1.lattice.build` | `lattice-mainnet-iad.fly.dev` | `137.66.36.149` | `139b8f36…7995fe64` |
| `seed2.lattice.build` | `lattice-mainnet-ams.fly.dev` | `137.66.14.188` | `35edf67b…5be6eb7d` |
| `seed3.lattice.build` | `lattice-mainnet-sjc.fly.dev` | `137.66.16.78` | `9cace839…065acd4e` |
| `seed4.lattice.build` | `lattice-mainnet-testnet.fly.dev` | `169.155.61.57` | `57f80deb…7bb22d0f` |

Each record is a DNS-only `CNAME` (no HTTP proxy in front: the overlay is not
HTTP). A seed is dialled by name or address and accepted by key, so whoever
answers without the pinned key is refused.

- Moving a seed to another host is a change to its record, with the identity
  key moved along with it. No release is needed for nodes to follow.
- The fixed address is each host's dedicated address at release time. It
  cannot follow a host that moves, so it is refreshed with a release; a stale
  one costs a failed dial and nothing else.
- A different key behind a name needs a release, because the key is what a
  node accepts.

The deployed hosts list each other by the same names
(`deploy/read-replica/entrypoint.sh`), so a host that moves is found by
everyone through one record.

### Remembered peers

A node keeps the peers it has reached in `peers.json`, in its data directory
beside the store: one book per hosted chain, each under the same rules. A
chain dials some of the peers in its own book when the node starts, or when
that chain runs short of peers or stops progressing.

- A peer is in the book of each chain it said it hosts. Its claim decides
  whom to dial and whom to ask, never what to accept: content is verified the
  same whoever sent it.

- Only an address the node dialled itself and reached the peer at is kept.
  Never one merely heard about, and never the address a peer advertises for
  itself: that is a claim, and it is wrong for any host whose outbound address
  is not the one it listens on.
- Per chain: one address per identity, at most 256, at most 8 per network
  group, none unseen for 30 days, and none that refused ten dials in a row.
  A failed dial counts in every book holding that peer.
- A remembered peer is dialled like any discovered peer and accepted only by
  its key. It is never treated as configured.
- Configured peers and the node's own identity are not written to it. A seed
  the node reached is: it is a peer like any other.
- A node started with no peers (`"peers": []`) neither reads nor writes it.
- A peer that no longer serves a chain is not refreshed in that chain's book
  and ages out of it.
- The book of a chain the node no longer hosts is dropped at the next start.
- A file written before chains had their own books is read as Nexus's book.
- An older node reads the per-chain file as an empty book and starts as if
  it remembered no one; nothing fails, and it relearns its peers.
- The file is advisory. Deleting it costs nothing but the next start's head
  start; a damaged one is ignored.

## Process lifecycle

```bash
lattice up --root /var/lib/lattice
lattice status --root /var/lib/lattice
lattice down --root /var/lib/lattice
```

For systemd, install the checked-in units and a topology:

```bash
install -m 0644 deploy/lattice-node.service \
  /etc/systemd/system/lattice-node.service
install -m 0644 deploy/lattice-mining-coordinator.service \
  /etc/systemd/system/lattice-mining-coordinator.service
systemctl daemon-reload
systemctl enable --now lattice-node
```

The coordinator unit requires `/etc/lattice/mining.env`:

```bash
install -d -m 0750 /etc/lattice
cat >/etc/lattice/mining.env <<'EOF'
RECIPIENT_ARGS=--recipient Nexus=<address> --recipient Nexus/Alpha=<address>
EOF
chmod 0640 /etc/lattice/mining.env
systemctl enable --now lattice-mining-coordinator
```

## Network surfaces

| Surface | Default | Exposure |
|---|---:|---|
| Ivy tree overlay | `4001/tcp` | Public when accepting inbound peers |
| Browser peers | `4002/tcp` and `4002/udp` | Public when accepting browsers; `--websocket-port 0` turns it off |
| Operator RPC | `8080/tcp` | Loopback only; the daemon rejects other bind addresses |
| Public reads | disabled | Public only when explicitly configured |

A browser cannot open the overlay's TCP connection, so it reaches a node over
WebSocket, at `ws://<host>:4002/ivy`. Two browsers cannot accept a connection
from each other either: they meet through a node both reach, which relays
between them, and then connect to each other directly. For that each needs
the address the other can reach it at, and it asks the node, by STUN on the
same port over UDP. No other server is involved.

- Open the port for both TCP and UDP. A node that listens here relays
  between its peers: signalling only when the two then connect directly, and
  their traffic when they cannot.
- Left unset, the node listens on 4002 if it can bind it and starts without
  it, with a line on standard error, if it cannot; a second node on one
  machine needs a port of its own. With `--websocket-port` given (topology:
  `webSocket`), failing to bind is an error.
- There is no TLS in the node, and a page served over `https` may only open
  `wss`. Terminate it in a proxy in front. STUN does not pass through that
  proxy: a browser asks at the host and port it dialled, so UDP on that port
  has to be forwarded to the node's.

### Nodes behind NATs

A node that accepts no inbound connections, as one behind a home router does
not, still connects to other such nodes. When it cannot dial a peer it asks
a peer it is connected to for a route to it. Only a peer whose hello said it
relays is asked, which is every node that listens for browsers. The two then
tell each other where they are and both connect at the same moment, each
from a port it named, so each one's first packet opens its own router for
the other's. The session that results is direct, and the relaying peer
carries nothing more for the pair.

- Nothing is configured, and nothing is opened on the router.
- It works where the router keeps a connection's port, which most home
  routers do. Behind one that gives each connection another port, or with
  no public address known, the pair cannot connect: the relayed session is
  let go, and each keeps the peers it can reach.
- A node learns its own public address as before: from `--external-address`
  or from the STUN servers its overlay asks at start.
- A relaying node carries a pair only while they try, some seconds.

The public-read listener serves the bounded GET routes and never registers
operator status, metrics, or mining handlers; it registers
`POST /transactions` only with public submit on (below). Set all three read-rate controls to
zero only behind a proxy that supplies its own per-client and global limits
(`--public-submit-rate` is a fourth ceiling; it bounds only `POST /transactions`).
The example Fly read replica uses nginx as the public boundary.

## Discovery and peer health

Every peer follows Nexus on the same overlay, so every open session is a
Nexus peer and its seed list is where Nexus discovers. A node names each
child chain it hosts in its session hello (`host:<path>`), and periodically
announces one provider record per hosted child chain, its rendezvous:
`lattice.chain-peers.v1:<nexus genesis>:<path>`. A child is keyed by path, not genesis, so a joiner is findable and can search
before it holds any of the child's blocks, and competing geneses share one
rendezvous. Provider records name chain availability, not individual blocks or
states. A node that declares a public read URL also announces each hosted
child under that child's read-endpoint key (below).

A node announces what it hosts on every announcement turn and whenever a
session opens. Each announcement, a hosted chain's or an operator pin's,
lasts `announceLifetime` seconds (`--announce-lifetime`, default 1200); the
turns renew them at least every 10 minutes, so a shorter lifetime leaves
gaps in which peers cannot find the node as a provider. A child chain's current peers are the sessions whose hello
named it, and those its rendezvous names, so a peer on a build that predates
the hello's claim still counts. Each hosted child chain searches its own
rendezvous while it has no current peer - looked at at those same moments - and when it has not progressed since boot or for `peerSearchInterval`:
the node asks the DHT for that chain's providers and dials up to four, drawn
at random, that it is not already connected to. Peers that host only other
chains cannot sync it. When Nexus is the stalled chain, the node re-dials
configured bootstrap endpoints without a live session.

On the first attempt at a child chain's block, its bundle is asked of the
bundle-capable sessions named under the chain's rendezvous before the other
capable sessions. Nothing else is routed by the rendezvous: Volumes fetched one
at a time, and every retry, go to peers in the overlay's ordinary order. The
record is only a hint for whom to ask: content is verified the same whoever
sent it, a named session that has no bundle costs one round trip before the
others are asked, one that does not end its bundle is chosen for no further
bundle that session (requests already waiting for it when that is learned are
still sent, at most one window of blocks, once per session), and no peer is
refused service for what it announced.

The trigger uses the locally verified tip, never a remote height claim. Set it
to `0` only for an intentionally isolated node.

Useful checks:

```bash
curl -s http://127.0.0.1:8080/health | jq
# Every operator route but /health needs the node's cookie (docs/rpc-api.md):
curl -s --user "$(cat <root>/chains/Nexus/.cookie)" http://127.0.0.1:8080/status | jq
curl -s --user "$(cat <root>/chains/Nexus/.cookie)" http://127.0.0.1:8080/metrics
```

For a child, append a URL-encoded `chainPath` query to supported reads:

```bash
curl -s 'http://127.0.0.1:8080/health?chainPath=Nexus%2FAlpha' | jq
```

## Listing a chain on an explorer

Anyone can make a chain they run readable on a public explorer such as
lattice.build, at any depth, without asking anyone:

1. Run a node that hosts the chain (`hostedChains` lists it and its
   ancestors).
2. Expose that node's public reads at an https URL (`publicRead` behind a TLS
   terminator, or a proxy with the read allowlist).
3. Declare the URL: `"publicReadURL": "https://reads.example.org"` in
   `lattice.json` (or `--public-read-url`). One URL per host; it covers every
   level the host serves, selected with `?chainPath=`.

The rule is the same at every level. A node that hosts the parent `P` of a
chain `P/D` answers `GET /api/chain/endpoints?chainPath=P/D`: it checks that
`P`'s recent canonical blocks commit a block under `D`, finds the hosts that
announced `P/D`'s read-endpoint key, and asks a bounded number of them over
the overlay for their declared URL. A node answers that question only for a
level it hosts. The URLs come back unverified, beside the committed child
block; a reader accepts a URL only if it serves that block at `?chainPath=P/D`.
The explorer starts from its configured Nexus nodes and repeats this one step
per level, so a chain appears once a node hosting its parent can reach a
declaring host.

Check a declaration from the parent's side:

```bash
curl -s 'https://<parent-reads>/api/chain/endpoints?chainPath=Nexus/Alpha' | jq
curl -s 'https://reads.example.org/api/block/<committedBlock>?chainPath=Nexus/Alpha' | jq .hash
```

## Running a public submit endpoint

Whether a node accepts transactions from the public is its operator's choice;
nothing in the protocol requires or forbids it, and it is off by default.
Turn it on with `"publicSubmit": true` in `lattice.json` (or `--public-submit`;
requires `publicRead`). The public-read listener then also accepts
`POST /transactions` for every hosted level, with the same answers and named
refusals as the operator route (see [rpc-api.md](rpc-api.md#public-submit)).

What it costs and what it does not change:

- one mempool policy for every source: a public submit is admitted under the
  same fee-rate eviction, replacement and minimum rules as peer gossip, is
  never journaled, and cannot displace the operator's own submits except by
  paying a better fee rate, which any peer transaction could do too;
- its own rate budget (`--public-submit-rate`, default 10/s listener-wide,
  plus each client's expensive read budget), so submit load never spends the
  read budget and the reverse;
- with `publicReadURL` declared, the host also declares that it accepts
  submits; `GET /api/chain/endpoints` lists it in `submitEndpoints`, and
  wallets can confirm with `GET /api/chain/info` (`acceptsSubmit`).

Behind a proxy that collapses client addresses (fly-proxy), set the per-client
read rates to 0 as for reads; the submit listener budget still applies.

## Health interpretation

`/health` returns:

- `phase: active` when the selected level has an executed tip;
- `phase: awaitingGenesis` for a hosted child with no executable genesis yet;
- `tipCID`, `height`, and `revision` for the selected level;
- the pinned Nexus genesis CID and absolute chain path.

An unknown or unhosted chain path is 404. It is not an internal error.

For a nested child stuck at `awaitingGenesis`, check in order:

1. every ancestor path is in `hostedChains`;
2. the spec file exists and decodes;
3. the immediate parent has executed at least one non-genesis block;
4. the parent has a positive reward or transactions that actually change its
   state;
5. the mining recipient and worker are configured for the parent and child.

## Mining

The recommended production command is equivalent to:

```bash
lattice-mining-coordinator \
  --node http://127.0.0.1:8080 \
  --rpc-cookie-file <root>/chains/Nexus/.cookie \
  --worker-executable /usr/local/bin/lattice-miner \
  --workers 2 \
  --recipient Nexus=<address> \
  --recipient Nexus/Alpha=<address>
```

The node fingerprints the complete hosted tree. A new transaction, child
candidate, or accepted child block invalidates stale work even when the Nexus
tip did not change. Submitted work is persisted only for child levels whose
target the hash actually meets.

Alert when:

- the coordinator reports no usable template for longer than one expected
  block interval;
- a round deadline is exceeded;
- rewards are intentionally or accidentally burning because a recipient is
  absent;
- a parent intended to host a nested child has stopped changing state.

## Storage, backups, and recovery

The tree storage directory contains:

```text
state.db
volumes.db
volume-bundles.db
storage.lock
```

`state.db` holds path-keyed facts, weighed headers, saved child proofs,
indexes, durable sync cursors, and the local mempool journal. `volumes.db`
holds content and retained roots. Those two are the recovery unit.
`volume-bundles.db` is a cache of which Volume roots are served together for a
block: it may be lost or deleted while the node is stopped, and is rebuilt
from local content.

Persistence order is:

1. store the content in one `volumes.db` transaction (a block's Volumes
   together, once its execution found it valid or it was mined here; a
   step's post-states together), then retain it. A body fetched from peers
   is read into memory until then (and read again from peers if memory
   let it go), and a node does not serve it before;
2. commit the complete multi-level `NodeBatch` (headers, child proofs, facts,
   and cursors) in one `state.db` transaction;
3. publish the new snapshots.

Every commit is synchronous (`synchronous=FULL`): nothing is announced,
served, or built on before the write that makes it durable returns.

### What a node keeps

Facts and headers are kept for good. Content is kept because a rule says so.
Two rules are built in: a node always holds each hosted chain's genesis
block, and the body of each chain's tip, so that a new block can be passed
on. A body fetched for a block waiting to execute is read into memory, not
stored: it is stored once the block's execution finds it valid. A body
is a block's own Volume and its transactions'.

`blockBodies` in `lattice.json` (`--block-bodies`) says which bodies it keeps
beyond those:

- `all`, the default: every body it executed.
- `none`: no others it executed. A body is let go of once another block is
  its chain's tip.

State, chain specs and policy modules are not bodies. What the node weighs
and which tip it selects do not depend on this setting, and it goes on
executing, mining and answering state reads on a block whose body it let go
of, from the header record it keeps for every block.

A body a node let go of is gone from that node:

- it answers `404` for that block and its transactions on the read routes,
  and "not held" to a peer that asks for it;
- the explorer routes that place a transaction or a deposit in a block
  report it unplaced;
- when the chain moves to another branch, the transactions of the blocks
  it left go back into the pool. Their bodies have been let go of, so they
  are read from peers, and a transaction of a block that no peer serves is
  not returned;
- a block the chain moves back onto after its body went is not fetched
  again: it confirms nothing out of the pool, and the node cannot pass it
  on until another block is the tip.

A node that mines on `none` lets go of each block it built as soon as it
builds the next. A peer that has not fetched that block by then cannot get
it from this node, and a chain whose only miner is on `none` cannot be
synced by anyone. Run `all` on a node that mines a chain others should be
able to follow.

A node that executes a chain from its genesis needs every body from some
peer, so a network needs nodes on `all`; people with a stake in a chain have
their own reason to run one. Keep `all` on a node an explorer reads.

`state` in `lattice.json` (`--state`) says which state it keeps:

- `all`, the default: the state of every block it executed.
- `tip`: the state of each chain's tip. State a newer block replaced is
  let go of.
- `none`: none between blocks. What a block reads is held until it has
  executed, and what the last execution touched until the next one.

Executing a block is the node's own work: state it reads and does not
hold comes from peers. What anyone can cause, a submitted transaction's
check and a state read, uses only what the node holds.

On `tip` the node answers state reads at its tip, and `404` for what an
older block's state held and the tip's does not. When the chain moves to
another branch, state the branch it left had changed is needed again. A
block that reads it reads it from peers; the node holds it again once a
block changes it. Until then reads of it answer `404`, and a transaction
that needs it is pooled unchecked and is mined by a peer, not by this node.
The first start on `tip` counts the whole state of each tip; state reads
are answered meanwhile, while submissions and mining wait for it.

On `none` the node answers state reads only for what the last block
touched. A submitted transaction is checked against what this node holds:
one that needs other state is pooled unchecked, relayed, and mined by a
peer, not by this node.

A node that is the only holder of a state and lets it go has lost it, so a
network needs nodes on `all`. Switching to `tip` or `none` applies to state
stored from then on: what a run on `all` stored stays until the node is
synced again.

Switching `blockBodies` to `none` takes effect at the next start, which lets go of every
executed body but the tips' and the genesis blocks' before the node answers
anything: the time that takes grows with the number of bodies it held.
Bodies stored by a version before this setting are not let go of: sync the
node again to drop them. Switching back to `all` keeps every body from then
on and brings none back. `volumes.db` does not shrink: the
space is reused.

Content outside the chain, such as a file an application names by CID, is
kept when the operator pins it: `POST /pins` on the operator port (see
`rpc-api.md`). The operator provides the bytes of a Volume the node does not
hold: the node never stores a pin a peer sent. An application that keeps
someone else's media reads it with `GET /fetch/:cid`, which stores nothing,
validates it, and then pins it. It serves it, announces it,
and keeps it across restarts until `DELETE /pins/:cid`.
Only the Volume the CID names is kept: Volumes it links to are not.

Back up only while the process is stopped, and snapshot both databases
together. The identity and child specs need separate backups.

```bash
systemctl stop lattice-mining-coordinator lattice-node
tar -C /var/lib/lattice -czf lattice-tree-backup.tgz \
  lattice.json identity specs chains/Nexus
systemctl start lattice-node lattice-mining-coordinator
```

Startup fails closed when:

- the schema epoch or Nexus genesis does not match;
- a journal/index audit disagrees;
- a hosted child chain's genesis spec is in neither `volumes.db` nor the
  node's own `specs`, or one of the node's own pending transactions is
  missing from `volumes.db`;
- saved child proofs do not decode or do not match their index;
- another process owns the storage lock.

Do not repair or combine database files by hand. Restore one matched snapshot
or perform the documented wipe.

## Upgrades and flag days

There are no migrations, compatibility readers, or mixed-version operation.
For an incompatible release:

```bash
systemctl stop lattice-mining-coordinator lattice-node
# Preserve identity, lattice.json, and specs. Remove the complete runtime tree.
lattice wipe --root /var/lib/lattice
# Install all four binaries from the same release.
systemctl start lattice-node lattice-mining-coordinator
```

The pinned Nexus genesis is recreated deterministically. Child roots are
reacquired or re-mined according to their specs and network availability.

## Observability

`/metrics` is operator-only Prometheus text. Monitor at least:

- process restarts and clean-shutdown failures;
- connected peer count;
- Nexus and child act-on heights;
- time since the last accepted Nexus block;
- mempool size and template errors;
- storage growth, free space, and backup age.

Set `LATTICE_SYNC_TRACE=1` for temporary stderr tracing, or set it to a file
prefix. The trace includes absolute chain paths and can grow without bound;
enable it only for diagnosis and rotate or remove it afterwards.

## Common failures

### `wipe required`

The store belongs to another schema epoch or Nexus genesis. Stop the complete
tree and use `lattice wipe`; there is no migration path.

### `missingMaterializedVolume`

A hosted child chain's genesis spec is in neither `volumes.db` nor this
node's own `specs`, or a transaction in the node's own pending journal is
absent from `volumes.db`. Restore the whole backup set or wipe.

Other content a fact names may be absent without stopping the node. It
starts on its facts, stores the Nexus genesis block again, and reads what it
needs to execute a block or build a template from its peers, each entry
checked against its CID. A `state.db` copied without its `volumes.db`
therefore runs, but it holds only what the blocks it has executed and mined
since have stored:
the public read routes and the check of a submitted transaction answer from
this store alone, so they report content it lacks as not found and leave
such a transaction pooled. Resync it to hold the rest.

### Saved proof corruption

Startup refuses to serve child headers without their recorded proof evidence.
Restore the matched backup or wipe the tree.

### Peers connected but height does not advance

Confirm the local tip really is stale, configured endpoints are reachable,
provider discovery is enabled, clocks are sane, and all nodes use the same
wire revision and Nexus genesis.

### Public reads return 429

Determine whether the code listener or nginx produced the response. Behind an
L4 proxy that collapses source addresses, disable the node's per-client rates
and keep a listener-wide rate plus trusted proxy-side client limits.
