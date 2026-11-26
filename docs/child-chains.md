# Child chains

Anyone can add a child chain beneath a chain their node hosts. There is no
deployment transaction and no approval: the node builds the child's genesis
from its spec, and merged mining secures it.

A chain is named by its path from Nexus, such as `Nexus/Alpha` or
`Nexus/Alpha/Beta`.

## Create a chain

```bash
lattice child create Nexus/Alpha \
  --root /var/lib/lattice \
  --block-time 10000 \
  --reward 1000 \
  --premine 0
```

The node keeps the chain's spec under `specs/`, adds the path to
`hostedChains`, and hosts the chain at once, without a restart. The next
mining template that can carry the child builds its genesis from the spec
and the parent's executed state.

**A spec is immutable.** Creating the same path with a different spec is
refused, and a launched chain's rules cannot be changed.

To mine it, give the miner a recipient for the new chain
([Mining](mining.md)).

### From a complete spec

Give a full `ChainSpec` as JSON instead of the flags:

```bash
lattice child create Nexus/Alpha --root /var/lib/lattice --spec alpha-spec.json
```

| Option | Use |
|---|---|
| `--spec <file>` | A complete `ChainSpec`. |
| `--policy-module <file>` | A WASM policy module the spec names by CID in `wasmPolicies`. Repeat it for each module. |
| `--premine-to <address>` | The account the genesis pays the spec's premine to. |
| `--genesis-transactions <file>` | Signed transactions the genesis carries after its premine. |

- **Policy modules.** Each file is matched to the spec by its CID and
  checked against the policy ABI. Creation is refused if a file is one the
  spec does not name, or a named module has no file.
- **Premine.** `premine` counts blocks of the reward schedule. The genesis
  pays their rewards to the `--premine-to` account in one credit. A premine
  with no account is refused.
- **Genesis transactions.** The file is a JSON array of what
  `POST /transactions` takes. Use it for state the creator writes from the
  first block, such as names the creator holds. Each transaction must be
  signed by exactly its signers, be for this chain, carry no coin, deposit,
  receipt or withdrawal actions, and pass the spec's policies.
  With the premine they must fit one block. A signer's later transactions
  continue from the nonces used here.

With `--node`, these files are read on the machine running `lattice`.

## Nested chains

Create the parent first, then the child:

```bash
lattice child create Nexus/Alpha/Beta --root /var/lib/lattice --reward 1000
```

A nested chain's genesis waits until its parent has executed a block of its
own. **Give a parent positive rewards.** A chain with no
reward and no transactions never changes state, so nothing can be built
beneath it. That is a consequence of the consensus rules, not a fault.

## Host a chain that already exists

```bash
lattice child host Nexus/Alpha --root /var/lib/lattice
```

A running node starts it at once and syncs it from its peers. A stopped node
hosts it from its next start.

The node hosts every listed chain's ancestors too, since a child runs only
under its parent.

## Stop hosting a chain

```bash
lattice child unhost Nexus/Alpha --root /var/lib/lattice
```

- **The chain's data is deleted** ([Storage](storage.md#chains-the-node-stops-hosting)).
  Hosting it again syncs it from peers.
- **A chain with a hosted chain beneath it stays hosted**, and `unhost` says
  so: `Nexus/Alpha: no longer listed; still hosted for Nexus/Alpha/Beta`. It
  stops once those are unhosted too.
- **A chain another configuration fragment lists is refused**, naming the
  fragment.
- Peers and windows set for the chain stay in the configuration, inert until
  it is hosted again.
- A spec that never started stays under `specs/` until removed by hand.

## A chain stuck at `awaitingGenesis`

`lattice status` or `GET /health?chainPath=<path>` shows `awaitingGenesis`
for a hosted child with no genesis yet. Check in order:

1. Every ancestor is hosted.
2. The spec file exists and decodes.
3. The immediate parent has executed at least one block after its genesis.
4. The parent has a positive reward, or transactions that change its state.
5. A miner is running with recipients for the parent and the child.

## Committing a child block yourself

Normally a miner that hosts a child carries its blocks. `lattice child
commit` is for a chain whose blocks should be carried by the parent's miners
that do not host it: it builds the child's next block, commits it on the
parent in a transaction, and pushes the block until it is in the chain's
tree.

```bash
lattice child commit Nexus/Alpha \
  --root /var/lib/lattice \
  --key ./wallet.json \
  --fee 1
```

`--key` signs and pays the commit on the parent, and is paid the child
block's reward. `--fee` defaults to the parent's `minRelayFee`.

```bash
# A new chain: its genesis is the first block committed.
lattice child create Nexus/Alpha --root /var/lib/lattice --spec alpha-spec.json
lattice child commit Nexus/Alpha --root /var/lib/lattice --key ./wallet.json

# An existing chain: the block extends its executed tip.
lattice child host Nexus/Alpha --root /var/lib/lattice
lattice child commit Nexus/Alpha --root /var/lib/lattice --key ./wallet.json

# A pending child transaction: the next block carries the pool.
lattice tx send --root /var/lib/lattice --chain Nexus/Alpha \
  --key ./wallet.json --to <address> --amount 25 --fee 1
lattice child commit Nexus/Alpha --root /var/lib/lattice --key ./wallet.json
```

The loop can run on another machine than the node:

```bash
lattice child commit Nexus/Alpha --node http://10.0.0.5:8090 \
  --token-file ./operator-token --key ./wallet.json
```

The token's routes must include `GET /health`, `GET /api/fees`,
`GET /api/state/account/{addr}`, `GET /api/mempool`,
`GET /api/transaction/{cid}`, `POST /transactions`,
`GET /child-blocks/commitment`, `POST /child-blocks/build` and
`POST /child-blocks`.

### What the loop does

Call the child block `C` and the parent state it is built on `P`. The commit
on the parent sets `child/Alpha` to `C@P` (Lattice spec §6.3).

Every 3 seconds the loop pushes `C`
([`POST /child-blocks`](api-operator.md#post-child-blocks)) and acts on the
answer:

| Answer | The loop |
|---|---|
| `tree` | Stops: the block is in the tree. |
| `pending`, `awaiting` | Waits: a miner is carrying the commit. |
| `dropped` | Reads the parent's commitment ([`GET /child-blocks/commitment`](api-operator.md#get-child-blockscommitment)). If it is still on `C`'s `P`, it sends the commit again. If `P` has changed (a new tip, or a reorganization), it builds a new block there ([`POST /child-blocks/build`](api-operator.md#post-child-blocksbuild)) and commits that. |

It builds at most once per `P` and never commits a carried block again.
Errors are printed and the loop goes on.

A node that hosts a chain pools and relays `child/<name>` commitments for it
but leaves them out of its own templates. The mechanism is described in
[push-only derived grinds](design/proof-derived-work.md#push-only-derived-grinds).
