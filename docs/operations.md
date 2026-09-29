# Operations

## Operator CLI

The `lattice` binary operates a host's whole chain-process tree from one
declarative `lattice.json`: `init` scaffolds directories, identities (kept
outside wipeable chain storage), and peer strings; `up`/`down` reconcile the
processes (children wired to their local parent automatically; `--foreground`
for containers, `emit-systemd` for hosts); `status` reads local loopback RPC
only; `mine` runs the rewarded mining loop with the nonce-cursor discipline
below; `child deploy`/`child adopt` are the two ways a child chain comes to
exist; `wipe` removes one chain's state and never identity. The full usage
guide is [operator-cli.md](operator-cli.md); the sections below remain the
ground truth for what each verb performs.

## Process model

A single-chain invocation runs Nexus with one absolute `--chain-path`. A child
chain runs only in the same `lattice-node` process as its ancestry: list the
tree in a `lattice.json` and host it with `--config` (see below); a non-Nexus
`--chain-path` is refused.

```bash
lattice-node \
  --chain-path Nexus \
  --data-directory /var/lib/lattice/chains/Nexus \
  --identity-key /var/lib/lattice/identity/nexus.key \
  --listen-port 4001 \
  --fact-listen-port 4002 \
  --rpc-port 8080 \
  --minimum-peer-key-bits 0 \
  --peer <public-key>@<host>:4001
```

RPC must remain on loopback. The same-chain overlay port may be public. Never
expose the hierarchy port: co-hosted levels dial it on loopback and no remote
peer needs it, but its listener binds all interfaces, so firewall it.

## Bootstrap peers

The binary ships default bootstrap peers for the root chain, so a Nexus process
started with no peer source of its own still has somewhere to dial. They are a
discovery convenience and nothing more: a default peer is verified and weighed
exactly like any other peer, receives no trust, no validation shortcut, and no
fork-choice influence, and is dropped like any stranger if it serves a
different chain.

- **Override.** Any `--peer` you supply REPLACES the defaults; the two are never
  merged. In `lattice.json`, a chain's `peers` list does the same.
- **Disable.** `--no-default-peers` starts the process with none. In
  `lattice.json`, an explicitly empty `"peers": []` means the same thing;
  omitting the key entirely is what asks for the defaults.
- **Child chains** never receive the root defaults. A child's peers must serve
  that child's chain, so give it its own `--peer` endpoints.
- **Loss is temporary.** A configured peer that goes away — including a default
  — is re-dialled under exponential backoff for the life of the process, so a
  node that loses its peers keeps trying to find them.

- **Four entries, two independent netgroups.** The shipped set does not span
  four independent networks: the three mainnet backbones all sit in one
  `137.66.0.0/16` netgroup, and only the public follower is outside it (its own
  IPv4 /16, and `2a09:8280::/32` over IPv6). Count the defaults as two
  independent sources, not four. If you need more separation than that — and a
  node whose only reachable defaults are the three backbones effectively has
  one — supply your own `--peer` endpoints. Note the netgroup is computed from
  the address a connection is OBSERVED at, not from the configured hostname, so
  the collapse happens only after dialing: with a low
  `--overlay-max-connections-per-netgroup` a node admits at most that many of
  the three backbones, discarding the surplus once it has already connected and
  without a distinctive error.

The startup banner reports which set is in play (`N default` or `N configured`
bootstrap peer(s)).

## Health

```bash
curl --fail http://127.0.0.1:8080/health
```

Important fields:

- `phase`: `active`, `awaitingGenesis` for an unbootstrapped child, or
  no tip-dependent intermediate phase.
- `chainPath`: the complete path owned by this process.
- `nexusGenesisCID`: must be
  `bafyreick4k7a6bxz4huqx4wiu3z5yph4tnpl4zvq2pi6xv3ouribtvzs24`.
- `tipCID` and `height`: null only while a child awaits genesis.
- `revision`: the local consensus mutation watermark.
- `mempoolCount` and `mempoolBytes`: bounded service pressure indicators.

## Public read surface

`--public-read-port` binds a second listener on all interfaces carrying only
the bounded GET read routes. Facing the internet with nothing in front of it,
it enforces its own arrival-rate ceilings — the same numbers
`deploy/read-replica/nginx.conf` applies to the proxied path:

| Flag | Default | Scope |
| --- | --- | --- |
| `--public-read-rate` | 25/s | Per client, general reads |
| `--public-read-expensive-rate` | 1/s | Per client, the expensive reads |
| `--public-read-max-rate` | 200/s | The whole listener |

`0` disables that ceiling; all three `0` is no rate limiting at all. The live
values are printed on the startup banner. The expensive set is `/v1/blocks`
(a recent-block walk), `/api/chain/endpoints` (a peer fan-out), and a block's
`/transactions` or `/children` (hundreds of content fetches at `?limit=100`);
`/v1/blocks/<cid>` is block detail and is general.

**`GET`/`HEAD` `/health` is exempt from all three** — a platform health check
that public load can throttle turns load into a depooled machine, and on the
testnet follower that machine carries every chain in the path, so a cheap flood
would become a total outage. Its cost is bounded by collapsing the work instead
of by refusing requests: the public listener serves `/health` from a
server-side snapshot cache with the same `max-age` it already advertises, so a
flood costs one `readSnapshot()` per interval however fast it arrives. That is
a tighter bound than a rate limit, which would still admit
`--public-read-max-rate` snapshot walks per second into the `ChainProcess`
actor that also serves sync and block import. The exemption is limited to
`GET` and `HEAD`, the only methods a health check uses; `/health` under any
other method is charged normally rather than being handed a free path to a 404.

That snapshot cache is a **work bound, not a rate limit**, so it is always in
effect on the public listener — including when all three rates are `0`. An
operator who turns rate limiting off entirely still gets a `/health` on that
port that is up to `max-age` seconds old, with no opt-out. The loopback
`--rpc-port` is never cached: `lattice status` and anything watching height
advance should read there.

Known gap: nginx's per-client `limit_conn` (a cap on one client's *in-flight*
requests) has no analogue here — a router middleware sees requests, not
connection lifetime, so a token bucket bounds requests *started*, never
requests *resident*. Concurrency is therefore bounded only indirectly, through
arrival rate, and that bound loosens exactly when handler latency rises — which
is when it matters most.

The client of the two per-client ceilings is the **peer socket address**, with
the port dropped. The node has no proxy it can trust, so it never reads a
forwarded-for header. The consequence is operational: **behind a proxy that
presents one address for every client — fly's `http` handler, an ingress
load balancer — set both per-client rates to `0`.** There the peer socket
identifies the proxy, so a per-client limit throttles the entire internet as
one user, and the explorer home page alone issues ~20 parallel requests.
`--public-read-max-rate` is address-agnostic and keeps bounding the listener.
`deploy/testnet-follower/entrypoint.sh` ships exactly that configuration.

## Metrics

```bash
curl --fail http://127.0.0.1:8080/metrics
```

`GET /metrics` serves Prometheus text exposition format 0.0.4 on the loopback
RPC port only; it is never registered on `--public-read-port`, and the
read-replica nginx allowlist refuses it. Each chain runs as its own process, so
each chain process is a separate scrape target on its own `--rpc-port`. Scrape
from the same host or through an authenticated proxy. A platform-managed
scraper such as Fly's dials the machine's address, not loopback, so it cannot
reach this endpoint. Every sample carries `chain="<absolute chain path>"` (for
example `Nexus` or `Nexus/testnet`); label values are escaped per the format.

| Metric | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `lattice_chain_tip_height` | gauge | `chain`, `tier` | Canonical tip height. `tier="validated"` is the deepest validated tip the node acts on; `tier="weighed"` is the canonical weighed-inclusive tip that same read started from, so validated never exceeds weighed within a scrape. Absent while a child awaits genesis. |
| `lattice_overlay_peers` | gauge | `chain` | Authenticated same-chain overlay peers. The parent/child fact-plane link is not counted: a child whose only link is its parent reads `0`. |
| `lattice_mempool_transactions` | gauge | `chain` | Transactions in the mempool. |
| `process_start_time_seconds` | gauge | `chain` | Process start time, seconds since the Unix epoch. |

A scrape costs the same as `/health`: the same ungated validated-tip read, with
no operation gate.

## External mining services

Run one or more coordinators against a Nexus process. Each coordinator allocates
non-overlapping ranges to external `lattice-miner` workers and submits results
back to the node.

```bash
lattice-mining-coordinator \
  --node http://127.0.0.1:8080 \
  --worker-executable /usr/local/bin/lattice-miner \
  --workers 4
```

Custom workers (GPU or remote hardware) implement the contract in
[mining-workers.md](mining-workers.md) and slot in via `--worker-executable`.

**Run one recipient plan per node.** A node serves one miner plan at a
time: the recipients and minimum work a template request names for the chains
below Nexus. A request with a different plan replaces the last one, and each
hosted child rebuilds its candidate for it; until it has, templates carry no
candidate built for the other plan, so no child block pays the wrong miner.
Miners with different recipient plans sharing one node therefore thrash: each
request undoes the other's, and their templates mostly carry no child
blocks. Coordinators that share one plan (the same `--recipient` and
`--min-work` entries) may share a node. A recipient is only an address: no
reward transaction is signed anywhere.

### Minimum work per block

A chain whose genesis sits at the maximum target hands out near-free blocks
until the retarget catches up: a fresh chain can mine a burst of them in
seconds, and the correction that follows overshoots by as much as it was
behind. A miner can decline to produce those blocks. `--min-work <chain
path>=<work>` is a filter on the miner's own search: the node still builds
that chain's block at its scheduled (canonical) target, and the template asks
the miner for a hash meeting `min(scheduled target, floor(2^256 / work) - 1)`.
A hash that clears the block's committed target but not that threshold is
never searched for, and the node refuses it if submitted (`missesSearchTarget`).

```bash
lattice-mining-coordinator \
  --node http://127.0.0.1:8080 \
  --worker-executable /usr/local/bin/lattice-miner \
  --min-work Nexus=2^32 \
  --min-work Nexus/testnet/swap=2^20
```

- It is an operator choice, never consensus. Validity, import and fork
  choice are untouched, and nodes keep accepting other miners' blocks at the
  scheduled target. Unset, templates are exactly the schedule.
- Blocks commit the canonical target by default. The difficulty schedule is
  absolute, measured from the chain's height-1 anchor, so committing a harder
  target does NOT move the schedule for later blocks — it only spends more
  work meeting the same one. The single exception is block 1 itself, which IS
  the anchor: the target it commits is where the chain's schedule begins.
- The trade-off is real. Fork choice credits a Nexus block
  `workForTarget(block.target)`, so a Nexus block committing the maximum
  target carries about one unit of work however hard the miner searched for
  it. (A child block is credited the larger of its own target's work and that
  of the root-most ancestor carrier its hash also satisfies, so a max-target
  child carried by a valid Nexus block is credited the Nexus target's work.)
  A filter that paces blocks near the target block time therefore keeps
  committed difficulty where the anchor put it: the schedule reads only the
  anchor and the block, and on-schedule blocks are exactly what it holds
  still for. Difficulty climbs only through blocks faster than the target, and
  it climbs at most one doubling per half-life (`halfLife ×
  targetBlockTime`) — there is no single-step over-correction to fear, and
  equally no way to harden quickly. Choose the value knowing it paces blocks
  without raising the schedule: roughly `expected hashrate × targetBlockTime` keeps the rate near
  target (1 GH/s against a one-hour target is 3.6e12, so `2^42`); a smaller
  value lets blocks arrive faster, which is what moves the target. Both `2^N`
  and plain decimal integers are accepted, up to 2^255 — the work of target 1,
  the hardest any block can ask for. More than that is refused outright, by
  the miner and by the node, rather than quietly becoming a target no one can
  ever hit.
- One coordinator covers the chain it mines and every chain merged-mined
  under it, one `--min-work` each. One nonce commits every chain in the
  template at once, so a hash meeting one chain's threshold can land between
  another chain's threshold and its easier committed target — a valid block
  that chain's filter declined. Wherever a filter is harder than its chain's
  scheduled target, the search therefore stops at the hardest such threshold
  in the template, including descendants below a child. Merged-mined chains
  then advance no faster than that filter allows, in both directions:
  - a filtered Nexus pinned at the maximum target holds every merged child to
    the Nexus threshold, even a child with no filter of its own;
  - a child filter harder than the Nexus schedule holds this miner's Nexus
    production to the child's threshold — a Nexus block at its easier
    committed target would carry the declined child block — and, because
    those Nexus blocks then arrive no faster than the child filter allows,
    keeps the Nexus committed target where it is (at the maximum, on a fresh
    chain).
- A filter two or more levels below the Nexus is visible to the Nexus only
  through the witness each child node returns with its candidate. Where that
  witness does not name the filtered chain — a child node without this
  behaviour, or one that never received the entry — the Nexus caps the search
  at that filter's target outright. This fails closed, and it can be stricter
  than needed:
  - when the chain is not in the template at all;
  - whenever that filter does not bind, meaning the chain's committed target
    is already at or harder than the filter target. Each child node returns a
    single witness, the block that sets its own search target, so a
    non-binding filtered chain two or more levels down is normally not the one
    it names, and the Nexus caps every descendant path the witness does not
    name.

  The cap costs only this miner's own template (a search harder than its
  blocks need); it never imports a declined block and has no consensus effect.
  Removing it would need each child node to return one witness per filtered
  path in its subtree, a change to the child candidate wire format. That
  belongs with the merged-mining design for deployed child chains and is not
  made here.

### What the filter is for

**A minimum-work filter adjusts the RATE at which a miner produces blocks. It
never changes what a block commits.**

That is the whole model, and the two halves matter equally.

A block always commits its *scheduled* target — `parent.nextTarget`, which the
absolute schedule derives from the chain's height-1 anchor. The filter sits in
front of the miner's own search: hashes easier than
`floor(2^256 / work) - 1` are neither searched for nor submitted. Declining
them makes this miner's blocks take longer to find, and that is the entire
effect.

Difficulty then follows, because the schedule reads elapsed time against
height. Blocks arriving faster than `targetBlockTime` pull the target harder;
slower, easier. So an operator sets the filter to choose a starting block
rate, and the chain converges on the difficulty that rate implies — at one
doubling per half-life, `halfLife × targetBlockTime`.

This is why it is a chain-launch instrument. A new chain's genesis commits the
maximum target by convention, so without a filter the first blocks are free and
arrive as fast as the miner can hash. The filter sets a sane opening rate;
everything after that is the schedule's job.

**Difficulty is what the chain reads from observed timing — never what a miner
declares.** A miner that could commit its own filter target would be publishing
private policy as consensus data, inherited by every later block through the
anchor. There is deliberately no setting that does this.

Two consequences worth knowing:

- **Pacing at exactly `targetBlockTime` cancels the signal.** If
  `minBlockIntervalSeconds` equals the target block time, blocks land exactly on
  schedule, drift stays zero, and difficulty never moves from wherever the
  anchor put it. Pace below the target block time, or not at all, if you want
  the schedule to converge.
- **The filter is two-sided.** Set so blocks arrive faster than the target and
  difficulty rises; slower and it falls. It is a throttle, not a floor.

If block production stalls:

1. Confirm the Nexus node is `active`.
2. Confirm the coordinator can reach the loopback HTTP endpoint.
3. Check coordinator logs for template rejection, expired work, or worker
   failure.
4. Check the worker executable path and permissions.
5. Confirm the submitted work satisfies at least one assembled chain target.

Do not daemonize the coordinator behind `nohup`+shell backgrounding on Linux:
a shell that forks with `SIGCHLD` blocked wedges Foundation's child reaping —
the coordinator hangs after one batch with zombie workers and an empty log.
Use a supervisor that spawns it with a clean signal mask (systemd, or the
reference [deploy/mine-supervisor.py](../deploy/mine-supervisor.py)).

## Mining rewards

Each block commits a `rewardRecipient` address, covered by its proof of work,
and consensus credits it exactly the block reward plus the block's fees. A block
without one burns both. The coordinator takes one `--recipient <chain
path>=<address>` per chain (`lattice.json`: `mine.recipients`; the reference
supervisor: `RECIPIENTS`); a chain left out pays no one. The recipient is only
an address, so no key and no signed payout ever reaches the mining host, and
there is no batch, cursor or nonce sequence to keep:

```bash
lattice key generate --out reward-key.json   # on a trusted machine
lattice-mining-coordinator --node http://127.0.0.1:8080 \
  --recipient Nexus=<address from reward-key.json>
```

A request that still carries the retired `rewards` field is refused, and so is
a `lattice.json` whose `mine` section still names `rewards`.

## Child chains

A child process may start before or after its parent records the child genesis
and can safely remain in `awaitingGenesis` until the parent block carrying the
`GenesisAction` is accepted. The child re-reads a `child-genesis.json` seed
from its data directory on every activation trigger (its start, each parent tip
change, each child-overlay peer hello, and a slow retry), so a seed written
while it waits is picked up without a restart. Without a usable seed, the child
can activate only by fetching the anchored genesis from a child-overlay peer,
and a brand-new chain has none.

A child runs in the same process as its whole ancestry: list every level in
`lattice.json` and start the tree host.

```bash
lattice-node --config /var/lib/lattice/lattice.json
```

Each level keeps its own ports, storage (`chains/<path>`) and identity
(`identity/<path>.key`) under the configuration's directory, or `--data-root`.
A chain added to the file is hosted from the next start. The child's data
directory for the seed above is its `chains/<path>` directory.

A child reads the parent facts its imports need (the recorded genesis and
parent-state continuity) from its parent level's own validated state in the
same process; there is no remote parent. Back up each level's identity key as
an operational secret.

For application testing, deploy a normal child with test-oriented parameters.
Nexus retains its one pinned genesis.

## Peer search

A node that has stopped making progress goes looking for more peers rather
than waiting on the ones it already holds. An eclipse only works for as long
as its victim keeps asking the same peers, and running a node is cheap, so
searching is the defence.

- **Trigger.** No new high-water accepted height for `--peer-search-interval`
  seconds. Staleness is measured from this node's own acquired tip, which
  advances only on proof of work it verified itself; no peer's announced or
  claimed height is consulted. A tip that moves *backwards* (a reorg, an
  exclusion changing the selectable path) is not progress and does not reset
  the timer.
- **Response.** Re-dial every configured `--peer` this node holds no session
  with (which also clears the overlay's reconnect suppression, the one state in
  which it has permanently given up on a configured peer), then run one
  provider lookup for this chain's genesis and dial up to four endpoints it is
  not already connected to. Discovery answers pointing at unspecified,
  loopback, link-local, multicast or broadcast hosts are dropped unread.
- **Default.** `600` (ten minutes), enabled. Same cadence for the first search
  and every repeat while the tip is still idle, so a long stall cannot
  accumulate dials.
- **Tuning.** `--peer-search-interval <seconds>`. `0` disables it entirely, as
  does any negative value.
- **Timing precision.** The staleness threshold is the interval exactly as
  configured, but the node samples its own tip on a cadence bounded to
  1s–24h. A search therefore fires up to one sampling period *after* the
  threshold is crossed: with the default, expect a widening between ten and
  twenty minutes after the last accepted block. An interval above 24h still
  measures staleness at its full configured value; only the sampling cadence is
  bounded.

**What this buys, unconditionally:** recovery from benign stalls — peers that
have gone silent, and the reconnect-suppression state in which the overlay has
stopped retrying a configured peer for good. Re-dialling a configured peer
clears that suppression, so "loss is temporary" under **Bootstrap peers** holds
even for a peer the overlay has given up on entirely, not only for one it is
still backing off from.

**Against a deliberate eclipse, the escape comes from the seed set, not from
discovery.** Provider lookups resolve through the hint cache and the routing
table, both populated exclusively through current sessions, so a fully eclipsed
node is asking its attacker where to find peers; the discovery limb is
therefore best-effort. The seeds are the part an attacker cannot choose, and a
Nexus process carries them by default, so a stalled root node re-dials a source
its attacker never selected without any operator action. A **child** chain
receives no defaults, so a child's escape is exactly the `--peer` set its
operator gave it — another reason to give a child real peers of its own.

This is **discovery only**. It never disconnects, scores, punishes or prefers a
peer — a slow peer and a withholding peer are indistinguishable, so an idle tip
is never evidence against anyone — and it has no bearing on validation, fork
choice, or which peer serves a sync.

## Storage and backups

One process directory contains both halves of durable state:

```text
<storage>/
  process.key   # unless --identity-key points elsewhere
  state.db
  volumes.db
```

Take `state.db` and `volumes.db` from the same stopped process. Copying or
restoring only one can leave retained-root metadata inconsistent with
materialized content.

For easier destructive recovery, keep long-lived identity keys outside the
chain storage directories and pass their paths explicitly.

## Required migration wipe

Legacy stores are intentionally incompatible with this architecture. Migration
is a whole-directory reset; there is no partial state rebuild and no supported
way to preserve legacy CAS volumes.

```bash
systemctl stop lattice-miner lattice-node

# Optional: preserve an identity only when it lives inside the directory.
install -m 600 /var/lib/lattice/chains/Nexus/process.key \
  /var/lib/lattice/identity/nexus.key

# Remove state.db, volumes.db, and every legacy artifact together.
rm -rf /var/lib/lattice/chains/Nexus

systemctl start lattice-node lattice-miner
```

An empty Nexus directory recreates the exact pinned genesis automatically. An
empty child directory returns to `awaitingGenesis` and must import its genesis
again, which requires its co-hosted parent level to confirm the recorded CID.

Before running a recursive removal, resolve and verify the explicit path. Never
target a home directory, workspace root, or an unresolved environment variable.

## Upgrading to executed-state attestation is one-way

The image that records execution as a durable import fact writes a batch
shape the previous image cannot decode. **Once a node has accepted a single
block on the new image, the previous image can no longer open that data
directory.**

The schema epoch is deliberately NOT bumped. Bumping it would force every node
to wipe on upgrade, which is exactly what the boot-time migration exists to
avoid — it carries pre-existing executions across so an upgraded chain does not
come back having forgotten every one. The cost of keeping the epoch is that a
downgrade has no clean path.

Because the epoch still matches, the old binary passes its schema check and
then fails later, while replaying the durable log. It reports:

```
The node store is corrupt: <decoding error>
```

That message is misleading here — the store is intact. It is `corrupt`, not
`wipeRequired`, so the old image offers no reset instruction even though a
reset is what a rollback would need.

Plan the roll accordingly:

- **Snapshot `state.db` and `volumes.db` together, before first start on the
  new image.** Restoring that matched pair is the only way back to the old
  image without resyncing.
- Otherwise a rollback is a whole-directory wipe plus a resync, per the section
  above.
- Roll one node first and let it accept a block before proceeding, so the
  one-way step is taken deliberately rather than fleet-wide at once.

### Parents and children roll together

A child reads its parent facts from its co-hosted parent level in the same
process, so a tree upgrades as one: restart the `lattice-node --config` process
on the new image. The parent attests only states it **executed**, never one it
only weighed.

### What the migration grandfathers

The boot migration converts the old tier column into durable execution facts
without re-validating. Those rows were written by an image whose parent-state
rules were weaker, so an execution it recorded is re-affirmed rather than
re-checked.

This matters only for a chain that could have been fed a forged parent anchor
*before* the upgrade — that is, a child chain. It does not apply to a root: a
root anchors to no parent, so its recorded executions are its own, and
migrating them re-affirms nothing it did not genuinely run.

So a root upgrades in place safely. **A child chain carried across this upgrade
should be redeployed rather than migrated**, unless you are satisfied its
history predates any exposure. A child deployed fresh after the upgrade is
unaffected.

## Common failures

### `invalidNexusGenesis`

The recovered height-zero fact or store metadata does not match the pinned
Nexus CID. Stop the process and perform the whole-directory wipe above. Do not
try to replace only the genesis row or retain `volumes.db`.

### `missingMaterializedVolume`

`state.db` references a retained volume absent from `volumes.db`. Restore a
matched backup pair or wipe the entire process directory and resync.

### Child remains `awaitingGenesis`

- Verify its `--chain-path` is absolute and exactly matches the intended child.
- Verify the child and its whole ancestry are listed in the `lattice.json` the
  process was started with (`--config`), and that the parent level is running:
  a child whose parent level failed is not started, and stopping a level stops
  every level below it.
- Confirm a separately signed parent transaction carrying the matching
  `GenesisAction` was mined. The parent's `GET /api/chain/children` listing
  helps, but it returns at most 100 children with no offset, so absence from it
  is not proof on a parent with more children.
- The child tries to activate on its start, each parent tip change, each
  child-overlay peer hello, and a slow retry after a failed fetch. Each attempt
  rebuilds the `child-genesis.json` seed from its data directory (re-read every
  time) and, without a usable seed, fetches the anchored genesis block by CID
  from child-overlay peers.
- If the seed is not the exact one the recorded CID was built from, it yields a
  different CID, which the child logs and does not activate; it falls back to
  the fetch path, so confirm a child-overlay peer serves the genesis block (a
  brand-new chain has none), or replace the seed.
- The parent record is read from the co-hosted parent level; an overlay peer
  cannot substitute for it.

### No peers

- Check each `--peer` key, host, and overlay port.
- Confirm the intended bootstrap set is in play: the startup banner reports
  `N default` or `N configured` bootstrap peer(s), and reports none when the
  process was started with `--no-default-peers` (or `"peers": []`) and no
  `--peer`.
- If `--minimum-peer-key-bits` is nonzero, confirm every required peer identity
  deliberately satisfies it. Generated process keys are accepted by the default
  value `0`.
- Confirm both peers advertise the same Nexus genesis CID and absolute chain
  path.

## Security

- Keep process private keys mode `0600`; startup rejects broader permissions.
- Keep RPC loopback-only. Authenticate any proxy that exposes it beyond the
  host.
- Host each child in the same process as its ancestry (`lattice.json`): its
  parent facts are read from the co-hosted parent level, never from a remote
  process.
- Firewall the hierarchy plane to intended parent/child hosts where possible.
- Use distinct storage and identity paths per chain process.
