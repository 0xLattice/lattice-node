# Operations runbook

## Deployment model

Run one `lattice-node` process for the configured Nexus-rooted tree. The
process owns:

- one long-lived identity key;
- one Ivy overlay listener;
- one loopback operator RPC;
- optionally one public-read listener (GET-only unless public submit is on);
- one `state.db`, `volumes.db`, and `header-evidence.db` recovery unit.

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
9. Reserve enough disk for unbounded fact history and retained content.
10. Test a clean shutdown, restart, and recovery before accepting traffic.

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
| Operator RPC | `8080/tcp` | Loopback only; the daemon rejects other bind addresses |
| Public reads | disabled | Public only when explicitly configured |

The public-read listener serves the bounded GET routes and never registers
operator status, metrics, or mining handlers; it registers
`POST /transactions` only with public submit on (below). Set all three read-rate controls to
zero only behind a proxy that supplies its own per-client and global limits
(`--public-submit-rate` is a fourth ceiling; it bounds only `POST /transactions`).
The example Fly read replica uses nginx as the public boundary.

## Discovery and peer health

Every peer follows Nexus on the same overlay. The node periodically announces
one provider record per hosted chain, its rendezvous: Nexus under its genesis
CID, each hosted child under `lattice.chain-peers.v1:<nexus genesis>:<path>`.
A child is keyed by path, not genesis, so a joiner is findable and can search
before it holds any of the child's blocks, and competing geneses share one
rendezvous. Provider records name chain availability, not individual blocks or
states. A node that declares a public read URL also announces each hosted
child under that child's read-endpoint key (below).

Each hosted chain searches its own rendezvous when it has not progressed since
boot - as soon as the node has a peer - or for `peerSearchInterval`: the node
asks the DHT for that chain's providers and dials up to four, drawn at random,
that it is not already connected to. Peers that host only other chains cannot
sync it. When Nexus is the stalled chain, the node also re-dials configured
bootstrap endpoints without a live session.

The trigger uses the locally verified tip, never a remote height claim. Set it
to `0` only for an intentionally isolated node.

A peer's request for headers is answered with what the node gathers within
`servingBudget` (`--serving-budget`, seconds, default 5), always at least one
header; the peer asks again for the rest. Lower it on a slow disk if peers
time out before an answer is sent.

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

The node issues no work for a chain it is still syncing. A chain is syncing
while its verified headers are more than the body window (64 blocks) ahead of
what it has executed, or while its executed tip is older than
`miningMaxTipAge` (`--mining-max-tip-age`, seconds, default 86400) and the
node has not yet caught up on that chain since it started; a chain with only
its genesis is never too old. A syncing Nexus answers `POST /mining/templates`
with 503 `syncing`, which the coordinator retries; a syncing hosted child is
left out of the template while Nexus and the other children are mined. Both
tests read the locally verified chain, never a remote height claim. Set
`miningMaxTipAge` to `0` to restart a chain nobody has mined for longer than
that.

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
header-evidence.db
storage.lock
```

`state.db` holds path-keyed facts, indexes, durable sync cursors, and the local
mempool journal. `volumes.db` holds content and retained roots.
`header-evidence.db` holds incomplete header boundaries and saved child proofs.

Persistence order is:

1. store and retain content;
2. store header evidence;
3. commit the complete multi-level `NodeBatch` and its cursors in one
   `state.db` transaction;
4. publish the new snapshots.

Back up only while the process is stopped, and snapshot all three databases
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
- referenced retained content is missing;
- saved child proofs do not decode or fail to cover a durable child work fact;
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

A fact references content absent from the matched `volumes.db`. Restore the
whole backup set or wipe. Copying only `state.db` is not recovery.

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
