# Storage

What a node writes to disk, how to bound it, and how to back it up.

## Layout

```text
<root>/
  lattice.json             configuration
  config.d/                configuration fragments
  identity/Nexus.key       the node's identity key
  specs/                   the specs of chains created here
  operator-tokens.json     remote operator tokens, when configured
  miner.json               the miner's settings, when it mines here
  run/  log/               the miner's pidfile and log, when it mines here
  chains/Nexus/            the data directory
    state.db
    volumes/               one Volume store per hosted chain
    volume-bundles.db
    peers.json
    serving.json
    storage.lock
```

One data directory holds every hosted chain. There is no per-chain process,
port, key or `state.db`.

| File | Holds | If lost |
|---|---|---|
| `state.db` | Facts for every chain: headers, child proofs, indexes, sync cursors, recent state diffs, the local mempool journal. | Restore with `volumes/`, or sync again. |
| `volumes/<hash>.db` | One chain's content: block bodies, state, spec and policy modules. Nexus's file also holds the operator's pins and the mempool's. | Restore with `state.db`, or sync again. |
| `volume-bundles.db` | A cache of which Volumes are served together. | Rebuilt from local content. |
| `peers.json` | Peers the node has reached ([Networking](networking.md#remembered-peers)). | The node relearns them. |
| `serving.json` | Peers' serving standing ([Networking](networking.md#serving-standing)). | Standings are lost. |
| `identity/Nexus.key` | The node's identity. | The node gets a new identity; peers that pinned the old key refuse it. |

`state.db` and `volumes/` are one recovery unit: back them up and restore
them together.

A chain's Volume store is named by the SHA-256 of its path:
`printf %s Nexus/Alpha | shasum -a 256` gives the name of `Nexus/Alpha`'s.

## What a node keeps

Headers, facts and child proofs are kept for every block of a hosted chain.
They grow with the number of blocks, as Bitcoin's block index does. Two
settings bound the rest.

### Block bodies

A body is a block's own Volume and its transactions', and for a child block
with withdrawals, the proof of each withdrawal's receipt in the parent
chain's state.

| `blockBodies` | Keeps |
|---|---|
| `all` (default) | Every body the node executed. |
| `none` | Only each chain's tip and genesis. A body is let go of once another block is the tip. |

On `none` the node still executes, mines and answers state reads. What
changes:

- It answers 404 for a block or transaction whose body it let go of, and
  "not held" to a peer that asks for it.
- Explorer routes that place a transaction or deposit in a block report it
  unplaced.
- After a reorganization, the transactions of the blocks left behind return
  to the pool only if a peer still serves those bodies.

**Run `all` on a node that mines a chain others should follow**, and on a
node an explorer reads. A miner on `none` lets go of each block as soon as
it builds the next, so a chain whose only miner is on `none` cannot be
synced by anyone.

Switching to `none` takes effect at the next start, which lets go of the
stored bodies before the node answers anything. Switching back to `all`
keeps bodies from then on and brings none back.

### State

| `state` | Keeps |
|---|---|
| `all` (default) | The state of every block the node executed. |
| `recent` | The whole current state of each chain, and what its last `stateWindow` blocks replaced (64 by default). |
| `none` | Only what the blocks at each chain's tip read and created. |

Kept state is a cache, not a promise. Execution, the check of a submitted
transaction and state reads all fetch state this node does not hold from
peers, so `recent` and `none` answer what `all` answers; a read of state
they let go of costs a fetch.

- On `recent`, blocks, transactions and reads of the current state run
  without fetching, as does a reorganization within the window.
- On `none`, only blocks that touch recent state run without fetching.
- Block bodies and anything asked for by CID are answered from this node's
  store alone, whatever `state` is.
- Chain specs and policy modules are kept on every setting.

The first start on `recent`, and a chain newly hosted, begins with a state
sync: the node reads the current state from peers, node by node. Until it
finishes, nothing is let go of. The mechanism is described in
[Architecture](architecture.md#storage-and-recovery).

Switching to `recent` or `none` applies to state stored from then on. What a
run on `all` stored stays until the node is synced again. Switching from
`recent` to `all` keeps what was held; switching to `none` lets it go.

**A network needs nodes on `all`.** A node that is the only holder of a
state or a body and lets it go has lost it for everyone.

### Pinned content

Content outside the chain, such as a file an application names by CID, is
kept when the operator pins it:

```bash
lattice pins add <cid> --fetch    # read it from peers, then pin it
lattice pins list
lattice pins remove <cid>
```

`pins add` without `--fetch` pins a Volume the node already holds. To provide
the bytes yourself, use `POST /pins`.

A pinned Volume is served, announced (unless the node runs with
`--no-announce-pins`) and kept across restarts until removed. Only the
Volume the CID names is kept, not the Volumes it links to. The node never
stores a pin a peer sent. See [HTTP API](rpc-api.md#operator-pins).

### Chains the node stops hosting

A chain the configuration no longer hosts has its data deleted, however it
left: `lattice child unhost`, a fragment edited or deleted, or a start
without it. A running node does so once the chain's work has stopped; every
start does so for any chain it holds data of and does not host. Each chain
let go of is a line in the node's log.

Hosting the chain again syncs it from peers like any new chain.

Deleting holds the node briefly: about 0.45 s for a 10,000-block chain and
4.5 s for a 100,000-block one.

### Disk space

- Removing a chain's Volume store frees its space.
- `state.db` and the Volume stores do not shrink when rows are deleted. The
  space is reused by later writes.
- `state.db-wal` is reused from its start and is not truncated.

To reclaim space after switching to `none` or `recent`, sync the node again
from an empty data directory.

## Backups

Back up only while the node is stopped.

```bash
systemctl stop lattice-mine lattice-tree
tar -C /var/lib/lattice -czf lattice-backup.tgz \
  lattice.json config.d identity specs chains/Nexus
systemctl start lattice-tree lattice-mine
```

Back up `identity/Nexus.key` separately as well, and protect it as mode
`0600`.

To restore, stop the node, replace the same paths from one backup, and start
it. Never combine `state.db` and `volumes/` from different backups, and do
not repair database files by hand. A node restored from an old backup syncs
forward from where the backup ends.

## What stops a node from starting

Startup fails closed when:

- the store was written for another schema or another Nexus genesis
  ([the node store is incompatible](troubleshooting.md#the-node-store-is-incompatible));
- a stored fact does not decode;
- a hosted child chain's genesis spec is in neither its Volume store nor
  `specs/`, or one of the node's own pending transactions is missing
  ([missingMaterializedVolume](troubleshooting.md#missingmaterializedvolume));
- `serving.json` cannot be read;
- another process holds `storage.lock`.

## How writes are ordered

1. A block's content is stored in one transaction of its chain's Volume
   store, once execution found the block valid or it was mined here.
2. The facts for every chain the step touched are committed in one
   `state.db` transaction.
3. The new state is published to readers.

Every commit is synchronous. Nothing is announced, served or built on before
the write that makes it durable returns.

Ready blocks of one chain are executed in batches of up to `connectBatch`
(32), stored and committed together. A larger batch commits less often while
a node catches up and holds more executed state in memory until it commits.
A crash loses at most the batch being executed: the node restarts at the
last committed batch and runs it again.
