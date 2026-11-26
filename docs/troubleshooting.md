# Troubleshooting

Find the symptom, then follow the steps. Start with what the node says:

```bash
lattice status --root /var/lib/lattice
lattice logs --root /var/lib/lattice --tail 200
curl -s http://127.0.0.1:8080/health | jq
```

`lattice status` shows, per hosted chain, its phase, height, best header
height, and what it waits on.

## The node does not start

### Exit 78: the configuration does not check

The reason is on standard error. Fix `lattice.json` or the fragment it
names. Under systemd the unit stays stopped until then; launchd and Docker
retry at their throttle ([Running in production](operations.md#exit-codes)).

### `wipe required`

The store was written for another schema version or another Nexus genesis.
There is no migration: wipe the chain storage and sync again.

```bash
lattice wipe --root /var/lib/lattice
```

`wipe` keeps the identity, configuration, specs and tokens
([Upgrades](operations.md#upgrades)).

### `missingMaterializedVolume`

A hosted child chain's genesis spec is in neither its Volume store nor
`specs/`, or one of the node's own pending transactions is missing from its
store. Restore the whole backup set, or wipe.

Other missing content does not stop the node: it reads what it needs from
peers, each entry checked against its CID. A `state.db` copied without its
`volumes/` therefore runs, but holds only what it has stored since. Its
public read routes report the rest as not found. Sync it again to hold
everything.

### Saved proof corruption

The node refuses to serve child headers whose recorded proof is damaged.
Restore the matched backup, or wipe.

### Another process holds the storage lock

A node, or a `lattice` command editing a stopped node, is using the data
directory. Only one may at a time.

## A chain does not advance

### Peers are connected but the height does not move

Check, in order:

1. The local tip really is stale: compare `lattice status` with another
   node or an explorer.
2. The node has peers for that chain, not only for Nexus
   ([How a node finds peers](networking.md#how-a-node-finds-peers)).
3. Configured peers are reachable from this host.
4. The host's clock is correct.
5. The node and its peers run compatible releases and the same Nexus
   genesis.

`sync.blockedOn` in `GET /status` names what the tip waits on.

### A child chain stays at `awaitingGenesis`

See [Child chains](child-chains.md#a-chain-stuck-at-awaitinggenesis).

### A child chain stops at a block: receipt proofs not obtained

`GET /status` for the chain shows `blockedOn: bodiesUnavailable` and
`waiting: body of <cid>: its receipt proofs not obtained from any peer`.

The block carries a withdrawal, which is checked against a receipt in the
parent chain's state. The proof of that receipt travels with the block.
This block's proof was never kept, and no node still holds the parent state
it names.

Repair it once, from one node:

1. Start a node from an empty data directory, hosting the parent and the
   stuck chain, with `blockBodies: all` and a parent state window longer
   than the parent chain (`"state": "recent"`, `"stateWindows": {"Nexus":
   <more than Nexus's height>}`). It needs peers that serve the parent's
   block bodies from genesis.
2. It executes the parent again from genesis, keeping its state, then the
   child. At the stuck block it reads the receipt from that state and stores
   the proof beside the block.
3. The stuck nodes ask the chain's hosts for the block again and receive it
   with its proof.
4. Once the stuck nodes have passed the block, stop the repair node or
   return it to its usual settings.

If the repair node stops at the same block, the cause is something else.

### A block never connects: `cidMismatch` naming this node

Bytes in a Volume store were damaged on disk. The node checks every entry
against its CID when it arrives, not on each read, so damage is caught where
the bytes are next checked: the block that needs them waits, again and
again, on a `cidMismatch`.

The node never sends damaged bytes: it answers "not held" for that Volume.
Nothing repairs them in place. Restore the matched backup, or wipe.

## Serving the public

### Public reads return 429

First find out whether the node or a proxy in front produced the response.
The node's limits are listener-wide (`publicReadMaxRate`,
`publicSubmitRate`), so one busy client can spend the budget for everyone.
Put per-client limits in the proxy, then raise the node's limit or set it to
`0`.

### Public reads return 503 with `Retry-After`

A reader asked for content the node does not hold, and waited 30 seconds
for the node to read it from peers, or the node's content budget was full.
The node reads at most `publicReadFetches` Volumes from peers at once
([Public reads](networking.md#public-reads)).

### Public reads return 404 for old blocks

The node let go of those bodies (`blockBodies: none`). Run `all` on a node
an explorer reads ([Storage](storage.md#block-bodies)).

## Mining

### Rewards are not arriving

A chain with no entry in the miner's `recipients` burns its reward and fees.
Check `lattice mine status` ([Mining](mining.md)).

### `ROUND DEADLINE EXCEEDED` in the miner's log

A round ran past its deadline and was abandoned; the next round retries. On
a host whose rounds legitimately run long, raise `roundDeadlineMultiplier`
in `miner.json`.

### The miner does not start mining

It waits for the node to answer a template request within
`templateTimeoutSeconds` (60). Check that the node is running, and read
`lattice logs --miner`.

## Tracing

Set `LATTICE_SYNC_TRACE=1` in the node's environment for sync tracing on
standard error, or set it to a file prefix. The trace can grow without
bound: enable it only for diagnosis and remove it afterwards.
