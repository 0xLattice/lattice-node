# Operator CLI (`lattice`)

`lattice` operates one host's chain-process tree from a single declarative
file. Lattice runs one process per chain; a child authenticates against its
immediate parent's fact plane. The CLI makes that tree a value — `lattice.json`
— and every verb reconciles reality against it. No resident daemon, no remote
control plane: state lives in the file, pidfiles, and each node's own storage.

## Quickstart: join the network and mine

```bash
mkdir /var/lib/lattice && cd /var/lib/lattice

# Scaffold: directories, a Nexus identity (0600, outside wipeable chain
# storage), lattice.json, and your shareable peer string.
# --peer is optional: without it the node uses its built-in bootstrap peers.
lattice init --peer <pubkey>@lattice-mainnet-iad.fly.dev:4001

lattice up          # start the tree; children are wired automatically
lattice status      # phase / height / tip / mempool per chain, local RPC only

# Rewards are pre-signed on a TRUSTED machine; the key never ships to miners.
lattice-rewards generate-key --out reward-key.json
lattice-rewards emit-batch --key reward-key.json --count 10000 \
  --out reward-batch.jsonl
# copy reward-batch.jsonl (only!) to the mining host, then add to lattice.json:
#   "mine": {"chain": "Nexus", "worker": "cpu", "workers": 4,
#            "rewards": "reward-batch.jsonl"}

lattice mine start
lattice mine status  # cursor position and batch runway
```

## `lattice.json`

```json
{
  "chains": {
    "Nexus":            {"listen": 4001, "fact": 4002, "rpc": 8080,
                         "peers": ["<pubkey>@host:4001"]},
    "Nexus/Market":     {"listen": 4101, "fact": 4102, "rpc": 8103}
  },
  "mine": {
    "chain": "Nexus",
    "worker": "cpu",
    "workers": 4,
    "batchSize": 2000000000,
    "rewards": "reward-batch.jsonl",
    "minWork": {"Nexus": "2^32"}
  }
}
```

- Every key in `chains` is an absolute Nexus-rooted path; a child requires its
  immediate parent in the same file (the CLI derives `--parent` from the local
  parent's identity and fact port — you never wire it by hand).
- `peers` is that chain's overlay bootstrap peers. Omit it and a Nexus process
  uses the default bootstrap peers built into the binary; a list REPLACES them;
  an explicitly empty `"peers": []` means no bootstrap peers at all. Child
  chains never receive the root defaults, so a child that needs peers names its
  own. Defaults are discovery only — no trust, no fork-choice influence — and a
  peer that goes away is re-dialled under backoff for the life of the process.
- Ports must be unique across the file. `.` and `..` path atoms are rejected.
- `worker` is `"cpu"` (the bundled `lattice-miner`) or a path to any
  executable honoring the [worker contract](mining-workers.md) — a GPU worker
  slots in here.
- `rewards` is optional; without it, mined blocks pay nobody.
- `minWork` is optional: chain path → minimum work per block (`2^N` or a
  decimal integer), passed to the coordinator as `--min-work`. It asks for
  blocks harder than the schedule — the miner's choice, never a validity rule
  — and matters most on a chain launched at the maximum target, where it is
  what keeps a fresh chain from bursting. See
  [operations.md](operations.md#minimum-work-per-block).

## Verbs

| Verb | What it does |
|---|---|
| `init [--peer …]` | Scaffold the root, mint identities, write `lattice.json`, print peer strings. Without `--peer` the tree carries no `peers` key, so the node uses its built-in default bootstrap peers. |
| `identity` | Every chain's public key and peer string (no log scraping). |
| `up [--foreground]` | Start missing processes, parents first, under a spawn lock. `--foreground` stays as PID 1 and restarts exits (containers). |
| `down` | Stop the tree, children first. SIGTERM, then SIGKILL after a grace. |
| `status` | One table for the tree, from local loopback RPC only. |
| `mine start/stop/status` | Supervised rewarded mining (below). `stop` is graceful: the in-flight batch finishes and the cursor is persisted. |
| `child deploy` | Create a new child of a running local parent (below). |
| `child adopt <path>` | Join an *existing* child: adds it to the tree and starts it; genesis is re-derived through the authenticated parent link, never copied from a node. |
| `tx send/deposit/receipt/withdraw` | Sign a transaction with a key file and submit it to one chain in the tree (below). |
| `wipe <chain>` | Remove one stopped chain's state (`state.db` + `volumes.db` as a unit). Identity is never touched — a wiped Nexus recreates the pinned genesis; a wiped child returns to `awaitingGenesis`. |
| `emit-systemd` | Print units that run `up --foreground` and `mine run` under systemd. |

All verbs take `--root` (default: current directory).

## Mining and rewards

`mine start` runs one coordinator batch per block beside the configured
chain's node, feeding one pre-signed reward per block, in nonce order:

- The cursor advances only on an **accepted block**, or on the one signature
  proving the current nonce is already spent (the node refuses a template for
  line *i* while accepting line *i + 1* — e.g. after a crash between block
  acceptance and the cursor write).
- Worker or node failures retry in place, forever. A skipped nonce would
  permanently invalidate the rest of the batch, so nothing else advances it.
- If line *i* and line *i + 1* are **both** refused, the batch is stalled
  (nonce gap or a halving made the amount too large): the log says so and the
  loop holds. Re-emit the batch from the key's next expected nonce.
- Re-emit before the batch runs out (`mine status` shows the runway) and
  before a halving boundary.

## Deploying a child chain

```bash
# spec.json: the child's ChainSpec (JSON). premine is a BLOCK COUNT; the
# credited amount is the reward schedule summed over that many blocks.
lattice child deploy Market \
  --spec spec.json \
  --fund funded-key.json \
  --premine-to <address>       # optional: credit the premine in genesis
# nested children: --parent Nexus/Market
```

The full arc runs in one command: the self-contained child genesis is built
locally from a seed (spec, `--premine-to`, timestamp) → a `GenesisAction`
anchor signed by `--fund` (the key stays on this machine) is submitted to the
parent → ordinary one-round coordinator runs are driven from the tree root
until the parent lists the recorded CID → the child appears in `lattice.json`
with auto-allocated ports, its data directory is seeded with
`child-genesis.json`, and it comes up `active` on that genesis CID. If the
parent does not record the anchor, **nothing is added to the tree or spawned**.

Notes:
- `--fund` must be a funded key on the parent chain; `--nonce` defaults to 0
  and must be the key's next expected nonce (a reused key needs the real one).
- The gate is the parent's committed record of the genesis CID, read through
  its `/api/chain/children` listing, not mempool drain. That listing returns at
  most 100 children, so on a parent with more children the gate can miss a
  recorded child and report that the anchor was not recorded.
- On a network whose target is too hard for ad-hoc CPU rounds, pass
  `--external-mining-wait-seconds <n>` to wait for already-running miners to
  record the anchor instead of driving local rounds.
- The command prints the `genesis` CID and `seed` JSON before submitting the
  anchor, so a recorded CID can still be activated by hand if the command dies
  before seeding the child.
- A child with no funded account cannot transact — use `--premine-to`.

## Transactions

`tx` signs with a `lattice-rewards` key file (the key stays on this host) and
submits to the named chain's loopback RPC, which validates against current
state before pooling. `--nonce` defaults to the chain's next expected nonce
for the key; pass it explicitly to queue several transactions before the
first is mined. `--fee` adds an explicit signer debit.

```bash
# plain transfer
lattice tx send --chain Nexus/Market --key alice.json --to <address> --amount 40

# parent/child value exchange, in protocol order; the three legs share one
# identity: demander / demand / swap-nonce
lattice tx deposit  --chain Nexus/Market --key seller.json \
  --swap-nonce 7 --demand 60 --lock 100            # seller locks 100 on the child
lattice tx receipt  --chain Nexus        --key buyer.json \
  --swap-nonce 7 --demand 60 --demander <seller> --directory Market
                                                   # buyer pays 60 on the parent
lattice tx withdraw --chain Nexus/Market --key buyer.json \
  --swap-nonce 7 --demand 60 --demander <seller> --amount 100
                                                   # buyer claims the locked 100
```

Submitting a withdrawal before the child's parent-state view carries the
receipt is not an error: the pool holds it as temporarily unavailable, and it
becomes eligible for a block once a carrier links that state. A transaction
that spends a balance it does not yet have is different — that one is refused
outright, so a dependent spend has to wait for the credit it depends on.

## Runbook proof

The E2E suite drives exactly these flows against real processes: a second
host `init --peer`s the first, syncs Nexus, `child adopt`s its child chain
and syncs that too; and full token swaps through `tx` — deposit locked on a
child (and on a grandchild under a nested parent), receipt paid one level up,
withdrawal claimed against the parent's receipt state, and dependent spends
proving the credited balances
(`Tests/LatticeNodeE2ETests/LatticeCtlE2ETests.swift`).

## Troubleshooting

- **`status` says `running, rpc unreachable`** — the process is up but not
  serving yet (recovery), or the pidfile survived a crash; check
  `log/<chain>.log` under the root.
- **Child stuck `awaitingGenesis`** — its anchor never landed, or the parent
  link is wrong; see the child-chain section of
  [operations.md](operations.md).
- **`REWARD BATCH STALLED` in the mine log** — see the mining rules above;
  re-emit the batch.
- **Identity key refused on load** — it is group/other-readable; `chmod 600`.
