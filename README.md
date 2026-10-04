# lattice-node

`lattice-node` is the full node for Lattice: a Nexus-rooted tree of
proof-of-work chains secured by recursive merged mining.

One process hosts one selected chain tree. It has one process identity, Ivy
overlay, content store, fact journal, RPC listener, and public-read listener.
Each hosted path still has independent consensus state, fork choice, sync,
mempool, and mining candidates inside that process.

## Architecture at a glance

- **Absolute paths.** `Nexus`, `Nexus/Payments`, and
  `Nexus/Payments/Rollups` are valid chain paths.
- **One process, one tree.** A child and every hosted ancestor run as levels of
  the same `NodeCore`; the wire carries a chain path where routing is needed.
- **One durable step.** `state.db` commits all levels touched by one core step
  in one SQLite transaction. `volumes.db` stores content, and
  `header-evidence.db` stores incomplete header boundaries and child proofs.
- **One overlay with discovery.** Every peer follows Nexus. Nodes announce one
  provider record for each hosted chain genesis and widen peer search when the
  verified Nexus tip stops progressing.
- **External mining.** The node owns templates and validation,
  `lattice-mining-coordinator` owns ranges, and stateless `lattice-miner`
  workers search nonces.

The detailed implementation map is in [docs/architecture.md](docs/architecture.md).

## Build and start

```bash
git clone https://github.com/adalinxx/lattice-node.git
cd lattice-node
swift build

mkdir -p node-data
swift run lattice init --root node-data
swift run lattice up --root node-data
swift run lattice status --root node-data
```

`lattice init` writes a flat `lattice.json`:

```json
{
  "listen": 4001,
  "rpc": 8080
}
```

Add peers as `publicKey@host:port`. The RPC server is loopback-only. A separate
optional public-read port exposes only bounded GET routes.

The daemon can also be run directly:

```bash
swift run lattice-node \
  --data-directory ./node-data/chains/Nexus \
  --identity-key ./node-data/identity/Nexus.key \
  --listen-port 4001 \
  --rpc-port 8080 \
  --peer <public-key>@<host>:4001
```

## Host a child chain

```bash
swift run lattice child create Nexus/Payments \
  --root node-data \
  --reward 1000 \
  --block-time 10000
```

This writes one child spec, appends `Nexus/Payments` to `hostedChains`, and
restarts a running host. The child genesis is built as a candidate from that
spec and mined through its parent's child commitment. It needs no parent
deployment transaction or authorization record.

List nested paths parent first. A nested genesis can be built only after its
parent has executed a block of its own. A parent whose reward is zero and whose
state never changes cannot supply that distinct parent state, so give a chain
positive rewards before using it as a parent.

## Mine the tree

The operator CLI reads mining policy from `lattice.json`:

```json
{
  "listen": 4001,
  "rpc": 8080,
  "hostedChains": ["Nexus/Payments"],
  "mine": {
    "worker": "cpu",
    "workers": 2,
    "recipients": {
      "Nexus": "<nexus-address>",
      "Nexus/Payments": "<payments-address>"
    }
  }
}
```

```bash
swift run lattice mine start --root node-data
swift run lattice mine status --root node-data
```

Every grind is checked against every hosted target. Configure a recipient for
each chain whose rewards and fees should be paid; an omitted recipient burns
that chain's payout.

## HTTP API

The API has one unversioned route set. There are no `/v1` aliases.

| Endpoint | Method | Purpose |
|---|---|---|
| `/health` | GET | Process and selected-chain health |
| `/status` | GET | Operator status for the hosted tree |
| `/transactions` | POST | Submit a signed transaction |
| `/mining/templates` | POST | Build merged-mining work |
| `/mining/work` | POST | Submit a nonce for issued work |
| `/api/...` | GET | Explorer and chain reads |

Use `?chainPath=Nexus/Payments` on chain-selectable reads. A submitted
transaction selects its level with `body.chainPath`; an unhosted path returns
404. See [docs/rpc-api.md](docs/rpc-api.md).

## Nexus genesis

Nexus is pinned to the deterministic local genesis CID:

`bafyreiggtg4ezifboyekbf4gxst2jr3mpjqcxsbmopy7w6fp46g4ngpgxa`

Its timestamp remains `0`. The full constants are documented in
[docs/protocol.md](docs/protocol.md).

## Storage compatibility

There are no storage migrations or compatibility modes. A schema, consensus,
or wire cutover is a flag day: stop the node, back up the identity separately
if needed, and wipe the complete hosted-tree storage directory. Never combine
`state.db`, `volumes.db`, or `header-evidence.db` from different snapshots.

```bash
lattice down --root /var/lib/lattice
lattice wipe --root /var/lib/lattice
lattice up --root /var/lib/lattice
```

## Documentation

- [Getting started](docs/getting-started.md)
- [Architecture](docs/architecture.md)
- [Protocol and node boundary](docs/protocol.md)
- [RPC API](docs/rpc-api.md)
- [Operator CLI](docs/operator-cli.md)
- [Operations](docs/operations.md)
- [Deployment](deploy/README.md)

`Package.swift` and `Package.resolved` are the authority for dependency
versions.
