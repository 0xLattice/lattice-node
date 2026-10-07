# Getting started

## Requirements

- Swift 6.1 or newer for a source build
- SQLite development headers on Linux
- `curl` and `jq` for the examples

The repository builds four executables:

- `lattice-node` — one full-node process for a hosted chain tree;
- `lattice` — topology, lifecycle, key, transaction, and mining CLI;
- `lattice-mining-coordinator` — assigns nonce ranges and submits results;
- `lattice-miner` — stateless CPU nonce worker.

## Build

```bash
swift build
swift test
```

For a production binary, use `swift build -c release` or a verified release
archive.

## Initialize a host

```bash
mkdir -p ./node-data
swift run lattice init --root ./node-data
```

This creates:

```text
node-data/
  lattice.json
  identity/Nexus.key
```

The initial topology is flat because one process owns the whole tree:

```json
{
  "listen": 4001,
  "rpc": 8080
}
```

`listen` is the Ivy overlay. `rpc` is the loopback operator API. Add explicit
bootstrap peers with `peers`, or leave the field absent to use the built-in
Nexus bootstrap set.

## Start and inspect the node

```bash
swift run lattice up --root ./node-data
swift run lattice status --root ./node-data
curl -s http://127.0.0.1:8080/health | jq
```

Stop it with:

```bash
swift run lattice down --root ./node-data
```

For foreground/container operation:

```bash
swift run lattice up --root ./node-data --foreground
```

## Add a child

```bash
swift run lattice child create Nexus/Payments \
  --root ./node-data \
  --block-time 10000 \
  --reward 1000
```

The CLI writes `specs/Nexus%2FPayments.json`, appends the path to
`hostedChains`, and restarts the process if it is running. The next mining
template that can carry the child builds its genesis from the spec and the
parent's executed state.

Nested paths must be added parent first:

```bash
swift run lattice child create Nexus/Payments/Rollups \
  --root ./node-data \
  --reward 1000
```

The nested genesis waits until `Nexus/Payments` has executed a block of its
own. A reward-free parent whose state never changes cannot host a nested child;
that is a consensus consequence, not an availability error.

## Configure mining

Add a `mine` object to `lattice.json`:

```json
{
  "listen": 4001,
  "rpc": 8080,
  "hostedChains": ["Nexus/Payments"],
  "mine": {
    "worker": "cpu",
    "workers": 2,
    "batchSize": 2000000,
    "recipients": {
      "Nexus": "<nexus-address>",
      "Nexus/Payments": "<payments-address>"
    }
  }
}
```

Then start the mining loop:

```bash
swift run lattice mine start --root ./node-data
swift run lattice mine status --root ./node-data
```

An omitted recipient burns that chain's block reward and fees. A nested parent
should have a valid recipient and a positive reward so its state advances.

## Send transactions

Create a spending key:

```bash
swift run lattice key generate --out ./spend-key.json
```

Submit a transfer to any hosted level through the one RPC listener:

```bash
swift run lattice tx send \
  --root ./node-data \
  --chain Nexus/Payments \
  --key ./spend-key.json \
  --to <address> \
  --amount 10
```

## Public reads

The operator RPC remains loopback-only. Set `publicRead` in `lattice.json` to
open the code-enforced GET-only read surface on all interfaces:

```json
{
  "listen": 4001,
  "rpc": 8080,
  "publicRead": 8081,
  "publicReadRate": 25,
  "publicReadExpensiveRate": 1,
  "publicReadMaxRate": 200
}
```

Use `?chainPath=Nexus/Payments` to select a child on routes that accept a
chain. Unknown or unhosted paths return 404.

## Storage and upgrades

The running tree stores data under `node-data/chains/Nexus/`:

```text
state.db
volumes.db
storage.lock
```

There are no migrations. On an incompatible schema or protocol cutover, stop
the node and wipe the complete tree storage with `lattice wipe`. Identity,
specs, and `lattice.json` remain outside that directory.

Continue with the [operator CLI](operator-cli.md), [RPC API](rpc-api.md), and
[operations runbook](operations.md).
