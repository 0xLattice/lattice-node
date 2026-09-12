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

Operate each chain as an independent service. Every invocation needs one
absolute Nexus-inclusive `--chain-path`; a non-Nexus process additionally needs
the authenticated immediate parent supplied by `--parent`.

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

RPC must remain on loopback. The same-chain overlay port may be public. Expose
the hierarchy fact port only where configured direct parents and children need
it.

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
  `bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`.
- `tipCID` and `height`: null only while a child awaits genesis.
- `revision`: the local consensus mutation watermark.
- `mempoolCount` and `mempoolBytes`: bounded service pressure indicators.

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
| `lattice_chain_tip_height` | gauge | `chain`, `tier` | Main-chain tip height. `tier="validated"` is the deepest validated tip the node acts on; `tier="weighed"` is the canonical weighed-inclusive tip that same read started from, so validated never exceeds weighed within a scrape. Absent while a child awaits genesis. |
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

### Minimum work per block

A chain whose genesis sits at the maximum target hands out near-free blocks
until the retarget catches up: a fresh chain can mine a burst of them in
seconds, and the correction that follows overshoots by as much as it was
behind. A miner can decline to take those blocks. `--min-work <chain
path>=<work>` asks the node to build that chain's block at the harder of the
requested target and the scheduled one; `nextTarget` is recomputed from the
target actually used, so the retarget sees real difficulty from block 1 and no
burst happens.

```bash
lattice-mining-coordinator \
  --node http://127.0.0.1:8080 \
  --worker-executable /usr/local/bin/lattice-miner \
  --min-work Nexus=2^32 \
  --min-work Nexus/testnet/swap=2^20
```

- It is an operator choice, never consensus. Validity requires only that a
  block be as hard as its parent scheduled (`target <= parent.nextTarget`), so
  mining harder is always permitted and nodes keep accepting other miners'
  blocks at the scheduled target. Fork choice is untouched. Unset — the
  default — templates and blocks are exactly as before.
- Choose the value as work per block: roughly `expected hashrate ×
  targetBlockTime`. At 1 GH/s against a one-hour target block time that is
  3.6e12, so `2^42`. Both `2^N` and plain decimal integers are accepted, up to
  2^255 — the work of target 1, the hardest any block can ask for. More than
  that is refused outright, by the miner and by the node, rather than quietly
  becoming a target no one can ever hit.
- Set it per chain, and set it before launching a fresh chain: every chain
  that starts at the maximum target bursts on its own, Nexus and each child
  alike. One coordinator covers the chain it mines and every chain merged-mined
  under it, one `--min-work` each.

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

Without a rewards file the coordinator requests empty rewards and mined blocks
pay nobody. Rewards are ordinary signed transactions validated by consensus:
credit-only account actions, fee 0, total claimed at most the spec reward at
the mined height, and the signer's nonces strictly sequential — so one signed
reward transaction is valid in exactly one block, in nonce order. Unsigned
credits exist only in genesis.

`lattice-rewards` keeps the reward key off the mining host:

```bash
lattice-rewards generate-key --out reward-key.json
lattice-rewards emit-batch \
  --key reward-key.json \
  --count 10000 \
  --out reward-batch.jsonl
```

Ship only `reward-batch.jsonl` to the miner. Each line is one complete
`--rewards-file` payload; feed line `i`, and advance to `i + 1` only after the
block paying it is accepted. A spent nonce is refused at template build
(HTTP 400 `invalidRewardTransaction`) — a supervisor's signal that the cursor
is behind, never a reason to skip ahead on other failures: a skipped nonce
permanently invalidates every later line. The reference
[deploy/mine-supervisor.py](../deploy/mine-supervisor.py) implements this
loop. Re-emit the batch before it is exhausted, and before a halving boundary
makes its amount exceed the allowed reward. Cursor advancement reflects the
current tip: a deep reorg that reverts a paid reward strands the tail of the
batch on a nonce gap — recover by re-emitting from the key's next expected
nonce.

## Child chains

A child process may start before or after its parent records the child genesis
and can safely remain in `awaitingGenesis` until the parent block carrying the
`GenesisAction` is accepted. The node reads a `child-genesis.json` seed from its
data directory only at startup: place the seed before starting the first node
of a new chain, or restart the child after writing it. Without a seed read at
startup, the child can activate only by fetching the recorded genesis from a
child-overlay peer, and a brand-new chain has none.

```bash
lattice-node \
  --chain-path Nexus/Payments \
  --parent <nexus-key>@10.0.0.10:4002 \
  --data-directory /var/lib/lattice/chains/Nexus/Payments \
  --identity-key /var/lib/lattice/identity/payments.key \
  --listen-port 4101 \
  --fact-listen-port 4102 \
  --rpc-port 8180
```

The parent endpoint is a live verdict boundary, not merely a bootstrap hint.
Back up the configured parent key and child process identity as operational
secrets. Losing the live parent does not revoke already admitted history or
fork choice, but new child admissions that change parent state wait until the
authenticated immediate parent can acknowledge the exact continuity or genesis
query. Same-chain peers may restore the required Volumes; they cannot relay the
parent's unsigned session-bound answer.

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
  exclusion re-projection) is not progress and does not reset the timer.
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
have gone silent, and the permanent reconnect-suppression trap in which the
overlay has stopped retrying a configured peer for good.

**Against a deliberate eclipse, the escape comes from the configured seed set,
not from discovery.** Provider lookups resolve through the hint cache and the
routing table, both populated exclusively through current sessions, so a fully
eclipsed node is asking its attacker where to find peers. The discovery limb is
best-effort; set `--peer` to seeds you trust, which is the part an attacker
cannot supply.

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
empty child directory returns to `awaitingGenesis` and must admit its genesis
again, which requires its configured parent to confirm the recorded CID.

Before running a recursive removal, resolve and verify the explicit path. Never
target a home directory, workspace root, or an unresolved environment variable.

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
- Verify `--parent` names the immediate parent's process key and fact port.
- Confirm a separately signed parent transaction carrying the matching
  `GenesisAction` was mined. The parent's `GET /api/chain/children` listing
  helps, but it returns at most 100 children with no offset, so absence from it
  is not proof on a parent with more children.
- The child pursues two genesis paths concurrently: a `child-genesis.json` seed
  read from its data directory at startup, and a fetch of the recorded genesis
  block by CID from child-overlay peers.
- If the seed was written after the child started, restart the child; the seed
  is read only at startup.
- If the seed is not the exact one the recorded CID was built from, it yields a
  different CID that the parent will not confirm. The child can then activate
  only through the fetch path, so confirm a child-overlay peer serves the
  genesis block (a brand-new chain has none), or replace the seed and restart.
- Check hierarchy-plane connectivity; an overlay peer cannot substitute for the
  configured parent fact link.

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
- Treat `--parent` as a pinned live-verdict configuration.
- Firewall the hierarchy plane to intended parent/child hosts where possible.
- Use distinct storage and identity paths per chain process.
