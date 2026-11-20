# Operations runbook

## Deployment model

Run one `lattice-node` process for the configured Nexus-rooted tree. The
process owns:

- one long-lived identity key;
- one Ivy overlay listener;
- one loopback operator RPC;
- optionally one public-read listener (GET-only unless public submit is on);
- one `state.db` and `volumes/` recovery unit (a Volume store per hosted chain).

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
7. Keep RPC on loopback. Use `publicRead` or a proxy allowing no more than it
   for public reads.
8. Configure a mining recipient for every chain that should pay rewards.
9. Reserve enough disk for unbounded fact history and retained content, or
   set `blockBodies` and `state` (see "What a node keeps").
10. Allow open files for the chains hosted: each chain's Volume store holds
    about thirteen (its file, log and shared memory, and four read
    connections), beside the overlay's sockets. The node raises its own soft
    limit to the hard limit at start (on macOS, to the kernel's per-process
    maximum, usually 10,240 or more) and logs the result as `open files
    allowed`; the shipped systemd unit sets `LimitNOFILE=65536`. Only a hard
    limit set low by the host bounds the chains a node can host.
    Each store also keeps up to 64 MiB of write cache and 16 MiB of read cache
    in memory, filled as its chain is used.
11. Test a clean shutdown, restart, and recovery before accepting traffic.

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
   to four of the hosts named there (see "Discovery and peer health"). One
   with fewer than eight current peers does the same at most once per
   `peerSearchInterval`.
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

The deployed hosts list each other by the same names, so a host that moves
is found by everyone through one record.

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
lattice up --root /var/lib/lattice        # runs the node in the foreground
lattice status --root /var/lib/lattice    # from another shell
lattice down --root /var/lib/lattice
```

The node is run by a process manager, which starts it again after a failure.
It exits 0 when asked to stop (`lattice down`, SIGTERM), 75 when asked to
restart (`lattice restart`, `lattice wipe`) and 78 when its configuration
does not check. The manager restarts it on a failure: systemd
`Restart=on-failure` (the checked-in unit, and `lattice emit-systemd`),
launchd `KeepAlive` with `SuccessfulExit` false (`lattice emit-launchd`),
Docker `--restart on-failure`. Only systemd can be told to leave 78 alone
(`RestartPreventExitStatus=78`); launchd and Docker restart it on 78 too,
throttled, and it exits 78 again until the configuration is fixed. On Fly,
every exit but 0 counts toward the Machine's restart limit (`max_retries`,
10 by default), so run the node from an entrypoint that starts it again on
75 itself ([Operator CLI](operator-cli.md#systemd-launchd-containers)). Give
an orderly stop time: systemd `TimeoutStopSec=90`, Fly `kill_timeout` of
60 s or more with `[[restart]] policy = "on-failure"`. The
node logs to standard error, which the manager keeps (`journalctl`, `docker
logs`, `fly logs`); `lattice logs` reads the running node's last lines from
its memory.

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
  no public address known, the pair cannot connect directly: they keep the
  relayed session, as libp2p's DCUtR does. A direct connection is tried
  when a relayed session is made, by each end at most once.
- A node learns its own public address as before: from `--external-address`
  or from the STUN servers its overlay asks at start.
- A relaying node carries a pair while they try, and after, when they
  cannot connect directly. It carries at most 64 routes, 8 asked by any
  one peer, and lets a route go once it is idle.

The public-read listener serves the bounded GET routes and never registers
operator status, metrics, or mining handlers; it registers
`POST /transactions` only with public submit on (below). Its rate limits are
listener-wide ceilings: `--public-read-max-rate` (default 200/s) for reads and
`--public-submit-rate` for `POST /transactions`. Set them to zero only behind a
proxy that supplies its own limits.
The lattice-ops read replica uses nginx as the public boundary.

A Volume a public reader asks for that the node does not hold is read from
peers, at most `--public-read-fetches` at once (fewer when half of
`--serving-max-in-flight-volume-bytes` does not fit that many 64 MiB archives;
the node prints the number at start). Past that, readers wait in arrival
order for a read to end, and readers of the same Volume share one read. A
waiting reader holds no archive memory, so the memory these reads take stays
at the number at once times 64 MiB. A reader that closes its connection
leaves the queue; one still waiting after 30 seconds (a proxy in front may
hold a connection its client closed), or whose read found the node's own
content budget full, gets 503 with `Retry-After` (see
[`GET /volumes/:cid`](rpc-api.md#read-routes)).

## Discovery and peer health

Every peer follows Nexus on the same overlay, so every open session is a
Nexus peer and its seed list is where Nexus discovers. A node names each
child chain it hosts in its session hello (`host:<path>`), sends the hello
again on its open sessions when it starts or stops hosting a chain while
running, and periodically
announces one provider record per hosted child chain, its rendezvous:
`lattice.chain-peers.v1:<nexus genesis>:<path>`. A child is keyed by path, not genesis, so a joiner is findable and can search
before it holds any of the child's blocks, and competing geneses share one
rendezvous. Provider records name chain availability, not individual blocks or
states. A node that declares a public read URL also announces each hosted
child under that child's read-endpoint key (below).

An announcement walks the DHT to the peers closest to its key, wherever
they are, so a node announces a key when it starts hosting or pinning it,
and on a later turn only when the record would lapse within one and a half
turns. A node that loses every session announces everything again when the
next one opens. A key it stops hosting, or a Volume it unpins, stops being provided;
records peers already hold lapse at their expiry. Each announcement, a
hosted chain's or an operator pin's, lasts `announceLifetime` seconds
(`--announce-lifetime`, default 1200, 1 to 86400: peers drop announcements
that last longer). Turns run about every 10 minutes, later when a turn is
slow, so a lifetime up to two and a half turns renews on every turn and one
near a turn leaves gaps in which peers cannot find the node as a provider.
`--provider-walk-sessions` (default 64) bounds the sessions those walks may
dial, never into the reserved outbound slots; 0 keeps them among the
sessions already open, and then the node announces everything on every turn
and whenever a session opens, since only those peers hear it. A child chain's current peers are the sessions whose hello
named it, and those its rendezvous names, so a peer on a build that predates
the hello's claim still counts. Each hosted child chain searches its own
rendezvous while it has no current peer - looked at at those same moments - when it has not progressed since boot or for `peerSearchInterval`, and, once per `peerSearchInterval`, while it has fewer current peers than the target (`peerTarget`, eight):
the node asks the DHT for that chain's providers and dials up to four, drawn
at random, that it is not already connected to. Peers that host only other
chains cannot sync it. When Nexus is the stalled chain, the node re-dials
configured bootstrap endpoints without a live session.

On the first attempt at a child chain's block, its bundle is asked of the
bundle-capable sessions named under the chain's rendezvous before the other
capable sessions. A child's Volumes fetched one at a time, on every attempt,
are likewise asked of the chain's current peers first (one at a time, those
that have been timing out last and then the least loaded, leaving out a peer
already reported for that Volume) and then of peers in the overlay's ordinary
order, which may ask those peers again; a Nexus Volume goes straight to the
ordinary order, since every peer hosts Nexus. The record is only a hint for
whom to ask: content is verified the same whoever sent it, a named session
that has no bundle or Volume costs one round trip before the others are asked
(one that does not answer costs a request timeout, after which it is asked
after the others: for a Volume no answering host holds, each silent one costs
a timeout, and the ordinary order may ask it again), one that does not end its bundle is chosen for no further
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
chain `P/D` answers `GET /api/chain/endpoints?chainPath=P/D`: it finds the
hosts that announced `P/D`'s read-endpoint key (the chain's rendezvous) and
asks a bounded number of them over the overlay for their declared URL. A node
answers that question only for a level it hosts. The URLs come back
unverified; a reader checks what each serves at `?chainPath=P/D`. What `P`
commits never decides whether `P/D` is found: a committed child block can be
one the child chain did not keep, or one nobody serves. The explorer starts
from its configured Nexus nodes and repeats this one step per level, so a
chain appears once a node hosting its parent can reach a declaring host.

Check a declaration from the parent's side:

```bash
curl -s 'https://<parent-reads>/api/chain/endpoints?chainPath=Nexus/Alpha' | jq
curl -s 'https://reads.example.org/api/chain/info?chainPath=Nexus/Alpha' | jq .chain
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
- its own rate budget (`--public-submit-rate`, default 10/s listener-wide),
  so submit load never spends the read budget and the reverse;
- with `publicReadURL` declared, the host also declares that it accepts
  submits; `GET /api/chain/endpoints` lists it in `submitEndpoints`, and
  wallets can confirm with `GET /api/chain/info` (`acceptsSubmit`).

## Serving standing

Serving is free while a slot is free. Under contention, waiting requests
share freed slots by weight, which grows with the peer's standing: bytes the
operator credited it plus verified content it served this node, less the
Volume archive bytes this node served it (every one, contended or not), never
below zero. Standing does not decay and is not capped.

The operator credits standing with `POST /serving-credit` on the operator
port (see [rpc-api.md](rpc-api.md#serving-standing)), by hand or through a
sponsor such as lattice-sponsor. Every standing is kept in
`<data-directory>/serving.json`, restored before the overlay starts and
written after each credit, on every maintenance pass and at a clean stop; a
crash loses only the changes since the last write, never a credit. Carry the
file with the data directory (blue/green moves, restores), or its standings
are lost. A file there that cannot be read stops the node from starting.

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
candidate, or accepted child block changes the template digest, sending the
coordinator for new work, even when the Nexus tip did not change. Work already
issued stays submittable; a solution on an old tip is a side block. Submitted work is persisted only for child levels whose
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
volumes/            one Volume store per hosted chain, <hash>.db (below)
volume-bundles.db
storage.lock
```

`state.db` holds path-keyed facts, weighed headers, saved child proofs,
indexes, durable sync cursors, the state diffs of the state window, and the
local mempool journal. `volumes/` holds each hosted chain's content and
retained roots, one file per chain; the root chain's file also holds the
constants, the operator's pins and the mempool's. Those two are the recovery unit.
`volume-bundles.db` is a cache of which Volume roots are served together for a
block: it may be lost or deleted while the node is stopped, and is rebuilt
from local content.

Persistence order is:

1. store the content in one transaction of its chain's Volume store (a block's Volumes
   together, once its execution found it valid or it was mined here; a
   step's post-states together), then retain it. A body fetched from peers
   is read into memory until then (and read again from peers if memory
   let it go), and a node does not serve it before;
2. commit the complete multi-level `NodeBatch` (headers, child proofs, facts,
   and cursors) in one `state.db` transaction;
3. publish the new snapshots.

Every commit is synchronous (`synchronous=FULL`): nothing is announced,
served, or built on before the write that makes it durable returns.

### Batched execution

A node executes ready blocks of one chain in batches: each block's previous
block is executed (or earlier in the batch) and, on a child chain, the parent
state it names is in the parent chain's executed set. A block whose parent
state is not executed yet is not run; it waits, and no other block waits on
it. A batch is a run of consecutive blocks on one chain, the heavier branch
first at a fork; each block reads the state the one before it produced from
memory. Its valid blocks are stored and committed together, by the order
above: one transaction of the chain's Volume store for their bodies, then one step's
post-states and facts. The batch ends at its first block without a valid
verdict. Bitcoin Core connects up to 32 blocks per `ActivateBestChainStep`,
and geth's `insertChain` writes a batch at once.

`connectBatch` in `lattice.json` or a `config.d` fragment
(`--connect-batch`; default 32, at least 1) is the most blocks one batch
executes; the body window (64 blocks ahead) bounds it too. A larger batch
commits less often while a node catches up and
holds more executed state in memory until its commit. A crash loses at most
the batch being executed: the node restarts at the last batch committed and
runs it again. A change takes effect on restart.

### What a node keeps

Facts and headers are kept while their chain is hosted, and so is each
credited child proof unless it no longer reads back (an entry it names is
gone, or a row is damaged): then it is deleted when read, the block is served without it,
and a peer's copy is taken again while the block still waits for proof.
They grow with the number of blocks weighed, as Bitcoin's block index
does. Content is kept because a rule says so.
Two rules are built in: a node always holds each hosted chain's genesis
block, and the body of each chain's tip, so that a new block can be passed
on. A body fetched for a block waiting to execute is read into memory, not
stored: it is stored once the block's execution finds it valid. A body
is a block's own Volume and its transactions', and, for a child block with
withdrawals, its receipt witness: the nodes of the parent chain's state on
the path to each withdrawal's receipt, which its execution reads. The
witness is kept, served and let go of with the body, so a node that fetches
an old withdrawal's body executes it though every node let go of that
parent state.

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
- `recent`: the whole current state of each chain, and what its last
  `stateWindow` blocks (`--state-window`, counting the tip) replaced. 64
  blocks unless set; `stateWindows` (or `--state-window Nexus/Alpha=500`)
  sets one chain. `tip`, the earlier name, means `recent`.
- `none`: a window of 1: what the executions at each chain's tip height read
  and created (and of side blocks above it, until the tip passes them), and
  what a block reads, until it has executed. `--state-window` applies to
  `recent` only; set with `all` or `none` it is refused.

On `recent` and `none` a node keeps each chain's spec and the policy modules
the spec names for as long as it hosts the chain, as `all` does: every block
of the chain reads them, so they are not state that a window lets go of.

On `recent` a node counts, for each chain, the places each node holds in the
state of the chain's tip, plus the places the blocks above a cursor replaced,
and keeps every node it counts, and the state diff of each block it executed
within the window (in `state.db`): the counts are kept in the chain's Volume store, written
with the cursor and the tip they were moved to in one transaction, so a stop
never leaves them half moved. As the tip moves, the counts follow it in one
write once it has climbed a window above them, at once when it is on another
branch, and at each start and maintenance pass: so while the counts follow the
tip the node holds at most two windows of executions' state and diffs, and
pays for a move once per window of blocks rather than per block. Each move adds what the
blocks entering the chain created, and takes away what the blocks leaving it
created and what each block the cursor passes replaced, the cursor a window
below the tip (a move of the tip never takes it down; a state sync may set it lower). A node a block replaced
is so kept until the tip is a window past that block, and a reorganization
that does not reach below the cursor is undone from the counts.

Counts that cannot follow the tip (a reorganization below the cursor, a fact
or a block's diff missing) or that the store refuses (a count below zero), and a chain with none
(the first start on `recent`, a chain newly hosted), are replaced by a state
sync: the node walks the state of a block a few below its tip, node by node,
reading what it lacks from peers, then replaces the counts with that state's
in one write and moves them on to the tip with the diffs of the blocks
between. When one of those blocks kept no diff (the node kept all state or
none when it executed it, or it is on a fork whose window went) the node
walks the tip's own state instead, and there is nothing to move on. A node the counts would start
counting and the store lacks is read from peers first, then the counts move.
What a state sync or such a read fetched is held until the counts name it,
and a state sync that fails lets go of what it held beyond where it reached.
Until the new counts are written the old ones stay, and while the counts are
behind the tip no window is let go of. A state sync or read that fails (at a
first start, before any peer has connected) runs again when a peer connects,
or at the next maintenance pass; a write the store failed runs again when the
tip next moves or at the next maintenance pass. A state sync whose counts the
store refuses waits for a new peer or the next maintenance pass before it runs
again. At each start, and at each maintenance pass for a chain whose counts
moved since they were last checked, the counts are checked against the store,
walking the tip's state from the store alone; counts that do not match it (as
facts an older version wrote with an inexact diff may leave them) are replaced
by a state sync.

The configuration is what the node hosts, and what it keeps: a chain the
merged configuration does not host has its data let go of, however it left
(`lattice child unhost`, a fragment edited or deleted, a SIGHUP re-read, a
start without it). A running node does so once the chain's level has
stopped and its running jobs have ended (its queued ones never run); the
change does not wait for the chain's running jobs. Every start does so
for any chain it holds data of and does not host, found by its facts, its
per-chain scopes and the names of its blocks' bodies and reads (one name
per kept block, held in memory while the start lists them: 30,000 list in
about 16 ms). One that the configuration lists and that did not start keeps
its data.

Its content goes first: from `volumes.db` its blocks' bodies and what they
read, its state windows, spec and policy modules, counts and what its state
sync held, and its pooled transactions; its local transactions (their rows
in `state.db` and what they pinned); and its Volume bundles from
`volume-bundles.db`. Then, in one `state.db` transaction, its facts and
block index, cursors, state diffs and child proofs go, with the header
records and proof entries no other chain's rows name. A fact whose content
is gone is no fault (it is read again from peers), so content goes first: a
stop or a failure in between leaves the chain's facts, a store the node
runs on, and the next start finishes the release. Each chain let go of, or
not, is a line in the node's log, naming it. Content another scope also
names stays: an operator pin, another chain's block, and on `state: all`
the state its executions stored, which is kept with every chain's. Child
indexes stay too: a leaf chain's blocks all share one, with every other
block that carries no child; a parent chain's may be its own. Hosting the
chain again syncs it from peers like any new chain.

Two writes can land after a running node let go of a chain, and go at the
next start: the chain's block body that a mined block's storing step,
begun before the chain stopped, stores under the chain's own body scope;
and a child block that the build-child-block RPC stores after passing its
hosted check before the chain stopped.

Letting go holds the node's loop while it runs: about 45 µs per block kept
with its bodies (a 10,000-block chain takes about 0.45 s, a 100,000-block
one about 4.5 s), plus a pass over every child proof the node keeps when the
chain's proofs named entries of their own (about 0.7 s with 100,000 proofs
of other chains). Its pooled transactions cost one read each of the
transactions in the pool.

Letting go frees space for the node's later writes, not for the system:
`state.db`, `volumes.db` and `volume-bundles.db` are SQLite files without
`auto_vacuum`, so deleted rows' pages go to each file's free list and are
reused by later writes, and the files do not shrink. Nor does
`state.db-wal`: a checkpoint reuses it from its start, and it is not
truncated.

Kept state is a cache, not a promise: execution, a submitted transaction's
check, and state reads all read the state this node does not hold from
peers, so `recent` and `none` answer what `all` answers, and a read of state
they let go of costs a fetch. A submitted transaction is first checked
against what this node holds, and only one that passes those checks (its
signatures, chain, fee and size) reads further state from peers. On `recent`
blocks, transactions and reads of the current state run without fetching once
a chain's counts are in place, as does a reorganization within the window; on
`none` blocks that touch recent state do. Block bodies (a block's transactions and children) and
anything asked for by CID are answered from this node's store alone: which
bodies it keeps is `blockBodies`, and a reader cannot make it fetch whatever
it names.

A start after a version that kept exactly the tip's state (`tip`) moves that
state into each chain's window at its tip, so it goes a window later like
any state, and forgets its counts. What a node kept for a chain it no longer
hosts goes when it stops hosting it, as every chain's data does.
Switching from `recent` to `all` keeps what the counts held with the chain;
switching to `none` lets it go.

A node that is the only holder of a state and lets it go has lost it, so a
network needs nodes on `all`. Switching to `recent` or `none` applies to state
stored from then on: what a run on `all` stored stays until the node is
synced again.

Switching `blockBodies` to `none` takes effect at the next start, which lets go of every
executed body but the tips' and the genesis blocks' before the node answers
anything: the time that takes grows with the number of bodies it held.
Bodies stored by a version before this setting are not let go of: sync the
node again to drop them. Switching back to `all` keeps every body from then
on and brings none back. A Volume store does not shrink: the
space is reused.

Content outside the chain, such as a file an application names by CID, is
kept when the operator pins it: `POST /pins` on the operator port (see
`rpc-api.md`). The operator provides the bytes of a Volume the node does not
hold: the node never stores a pin a peer sent. An application that keeps
someone else's media reads it with `GET /fetch/:cid`, which stores nothing,
validates it, and then pins it. It serves it, announces it
(unless started with `--no-announce-pins`),
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
- a stored fact does not decode, or a hosted level's facts do not restore;
- a hosted child chain's genesis spec is in neither the Volume stores nor the
  node's own `specs`, or one of the node's own pending transactions is
  missing from the root chain's Volume store;
- another process owns the storage lock.

Do not repair or combine database files by hand. Restore one matched snapshot
or perform the documented wipe.

## Node-local finality

This is an operator setting. Lattice has no protocol finality, and the
default is off.

`finalityWindow` in `lattice.json` (`--finality-window`, in blocks; absent or 0
by default) gives the node its own finality at every level it hosts. It is
node policy, not a consensus rule: nodes with different windows, or none,
agree on every block's validity. `finalityWindows` sets chains apart, by chain path, over
that default: `{"Nexus/Alpha": 500}`, or `--finality-window Nexus/Alpha=500`;
0 turns it off for that chain.

A header more than the window below a chain's best tip, by height, is
declined: not stored, not weighed, never blamed, and not asked for again. So
is new work crediting such a block. A header carries its own height, so an
orphan is judged on arrival, and a fork from a block deeper than the window
can never connect. The tip's next height is never past the window, so a chain
that stalled can always be extended. When the best tip moves to a lower
height, the window moves down with it: what was declined is forgotten and
judged again when it next arrives.

A fork `d` blocks deep is at most `2^(d / halfLife)` cheaper than the chain's
current difficulty, so a window of a few half-lives keeps out every nearly
free block — the siblings under genesis and the forks from old blocks. Nexus's
half-life is 120 blocks: a window of 240 caps a fork's discount at about 4×.

The cost is this node's alone: it does not follow a reorganization deeper
than the window, even a heavier one. A node partitioned or offline for longer
than its window stays on its side until its operator intervenes, and a miner
in that state mines the losing side.

Guidance:

- Leave it off on miners, backbones, and nodes that explorers read.
- A leaf or wallet node that wants to keep out cheap deep forks should use at
  least 240 on Nexus: 240 blocks is two half-lives (120 blocks each) at a 1 h
  block time, about 10 days, and a fork 240 deep costs at most about 4× less
  than the tip. Choose a window far longer than any outage you expect. The
  window does not bound storage: it declines new forks below it, and deletes
  nothing. What a node stores grows with the blocks it weighs; `blockBodies`
  and `state` bound bodies and state.
- Give each child chain a window at least as long as its parent's: a parent
  reorganization can reorganize the child.

`GET /api/chain/info` reports a chain's effective window as `finalityWindow`
(absent when off).

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

`/metrics` is operator-only Prometheus text. Per hosted chain path (label
`chain`) it reports:

- `lattice_chain_tip_height{tier="validated"|"weighed"}`: the acted-on tip
  and the best header;
- `lattice_chain_tip_advanced_timestamp_seconds`: when the acted-on tip
  last moved;
- `lattice_chain_blocked_on{on=...}`: what the tip waits on, one series per
  reason, 1 for the current one (`/status`'s `sync.blockedOn`) and 0 for the
  rest, so a reason that ends reads 0 rather than vanishing;
- `lattice_chain_synced`, `lattice_chain_headers_synced`: its latches;
- `lattice_chain_jobs_queued`: its jobs waiting for a worker;

and node-wide `lattice_overlay_peers`, `lattice_mempool_transactions` and
`process_start_time_seconds`.

`deploy/prometheus/lattice-alerts.yml` has alert rules on these: a chain
behind and still, a chain stalled with no reason, content no peer serves,
a chain not caught up an hour after start, no peers, and a restart loop.
Their thresholds are starting points. Monitor also storage growth, free
space and backup age, which the host's own exporter reports.

Set `LATTICE_SYNC_TRACE=1` for temporary stderr tracing, or set it to a file
prefix. The trace includes absolute chain paths and can grow without bound;
enable it only for diagnosis and rotate or remove it afterwards.

## Common failures

### `wipe required`

The store belongs to another schema epoch or Nexus genesis, or a Volume store
was written by a version with another Volume store schema. Stop the complete
tree and use `lattice wipe`; there is no migration path.

A node that ran a build of `main` with the write-behind persistence layer
(the state buffer and `stateBufferBytes`, from #137 until #156 reverted it)
must be wiped before it runs this version: its store may hold facts whose
state it never wrote, and a `stateBufferBytes` key left in `lattice.json` or
`config.d` is refused at start.

Schema epoch 49 moves `volumes.db` to the Volume store's schema v3, which
drops a redundant index (about 14% of what a sync writes). Every node is
wiped once to run it; an older store reports `wipe required`.

Schema epoch 50 gives each hosted chain a Volume store of its own under
`volumes/` beside `state.db`, in place of the one `volumes.db`, so a chain's
writes no longer grow with the chains hosted beside it. Every node is wiped
once to run it. A chain's file is named by the SHA-256 of its path, so
names never collide on a case-insensitive disk and stay short however deep
the chain; `printf %s Nexus/Alpha | shasum -a 256` gives Nexus/Alpha's
(`volumes/<that>.db`). A chain the node stops hosting keeps its store until
the next start, which removes it with its log; the root chain's store also
holds the operator's pins, the protocol constants and the mempool's
journal. Back up the whole storage directory, `volumes/` included.

### `missingMaterializedVolume`

A hosted child chain's genesis spec is in neither the Volume stores nor this
node's own `specs`, or a transaction in the node's own pending journal is
absent from the root chain's Volume store. Restore the whole backup set or wipe.

Other content a fact names may be absent without stopping the node. It
starts on its facts, stores the Nexus genesis block again, and reads what it
needs to execute a block or build a template from its peers, each entry
checked against its CID. A `state.db` copied without its `volumes/`
therefore runs, but it holds only what the blocks it has executed and mined
since have stored:
the public read routes and the check of a submitted transaction answer from
this store alone, so they report content it lacks as not found and leave
such a transaction pooled. Resync it to hold the rest.

### Saved proof corruption

Startup refuses to serve child headers without their recorded proof evidence.
Restore the matched backup or wipe the tree.

### Damaged Volume store content

For its own use the node does not hash what it reads back from a Volume store:
every entry was checked against its CID on its way in. Bytes damaged on disk
since are caught wherever they are read against their CID. A block whose
content they are never connects: its fetch and connect wait, again and
again, on a `cidMismatch` that names the provider, though the bytes are this
node's own. What the node sends, to a peer or on the public read routes, it
checks first: a Volume holding damaged bytes is answered as not held, never
sent. Nothing repairs them in place. Restore the matched backup or wipe the
tree.

### Peers connected but height does not advance

Confirm the local tip really is stale, configured endpoints are reachable,
provider discovery is enabled, clocks are sane, and all nodes use the same
wire revision and Nexus genesis.

### A child chain stops at a block: receipt proofs not obtained

`/status` for the chain shows `blockedOn: bodiesUnavailable` and `waiting:
body of <cid>: its receipt proofs not obtained from any peer`. The block
carries a withdrawal, which is checked against a receipt in its parent
chain's state at the block's anchor. The trie nodes that prove that receipt
travel with the block, stored beside it and served with it; this block's
were never kept. That happens to a block stored before receipt proofs
travelled with blocks, when no node still holds the parent state it names.

Repair it once, from one node:

1. Start a node from an empty storage directory on this release, hosting the
   parent and the stuck chain with `blockBodies: all`, and a parent state
   window longer than the parent chain (`--state-window Nexus=<more than
   Nexus's height>`). It needs peers that serve the parent's block bodies
   from genesis.
2. It executes the parent again from genesis, keeping its state, then the
   child. At the stuck block the withdrawal reads its receipt from that
   state, and storing the block stores its receipt proofs beside it.
3. The stuck nodes ask the chain's hosts, this one included, for the block
   again, and receive it with its proofs. Each stores them with the block
   and serves them from then on.
4. Once the stuck nodes have passed the block, stop the repair node or wipe
   it back to its usual settings. No node keeps old parent state afterwards.

If the repair node stops at the same block, the cause is something else.

### Public reads return 429

Determine whether the code listener or nginx produced the response. The node's
limits are listener-wide (`--public-read-max-rate`, `--public-submit-rate`); a
429 from the node means the listener as a whole is over its ceiling.
