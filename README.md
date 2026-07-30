# lattice-node

`lattice-node` runs one chain in the Lattice hierarchy. Lattice has one root,
**Nexus**, and every other chain is a descendant secured through merged proof of
work. A process owns exactly one chain, one durable store, one same-chain
overlay, and one private parent/child fact plane.

## Architecture at a glance

- **One process, one chain.** Run another `lattice-node` process for every child.
  A parent owns no child state or child fork-choice view.
- **Absolute chain paths.** Every path includes `Nexus` as its first component:
  `Nexus`, `Nexus/Payments`, or `Nexus/Payments/Rollups`. A path that omits
  `Nexus` is invalid. A child `directory` such as `Payments` is only the final edge
  label under a known parent.
- **Two network planes.** The public Ivy overlay carries same-chain blocks and
  content. The private hierarchy plane carries authenticated direct-parent and
  direct-child facts.
- **External mining.** The node creates templates, validates submitted work,
  persists accepted blocks, and publishes them. `lattice-mining-coordinator`
  schedules nonce ranges and external `lattice-miner` workers search them.
- **Content-addressed durability.** Each process stores protocol state in
  `state.db` and materialized content volumes in `volumes.db`.

Testing networks are ordinary child chains with testing-oriented economics and
cadence. Nexus has one genesis and no alternate network mode.

## Build and run

```bash
git clone https://github.com/adalinxx/lattice-node.git
cd lattice-node
swift build

# Nexus. Its default storage is ~/.lattice/chains/Nexus.
swift run lattice-node \
  --chain-path Nexus \
  --listen-port 4001 \
  --fact-listen-port 4002 \
  --rpc-port 8080

# Add same-chain peers explicitly when needed.
swift run lattice-node \
  --chain-path Nexus \
  --peer <public-key>@<host>:4001
```

RPC is intentionally loopback-only. The daemon rejects non-loopback
`--rpc-bind` values.

To run a child, configure its complete identity and immediate parent:

```bash
swift run lattice-node \
  --chain-path Nexus/Payments \
  --parent <nexus-process-public-key>@127.0.0.1:4002 \
  --listen-port 4101 \
  --fact-listen-port 4102 \
  --rpc-port 8180
```

The child starts in `awaitingGenesis`. Create a child intent on the parent,
submit the separately signed parent `GenesisAction` transaction, and mine the
parent block that commits it. The authenticated hierarchy plane then delivers
the genesis proof and signed authorization. The child derives work from that
proof and becomes active once the genesis is durably admitted. Genesis is
returned as a normal content-addressed block; there is no opaque serialized
bootstrap channel.

## Mining

Run the coordinator against the Nexus loopback API and point it at the external
worker executable:

```bash
swift run lattice-mining-coordinator \
  --node http://127.0.0.1:8080 \
  --worker-executable .build/debug/lattice-miner \
  --workers 2
```

`lattice-miner` is deliberately a small worker. It receives one immutable
block/range assignment, searches nonces, and reports the result. It never owns
chain state, wallet keys, child topology, proofs, or publication.

Normal templates exclude every transaction containing a `GenesisAction`.
Run the coordinator with `--deployment` to mine one fully backed pending child
deployment subtree; repeated deployment rounds rotate across eligible work.

## HTTP API

Each process exposes only its configured chain at the loopback address. Requests
cannot select a second chain at runtime.

| Endpoint | Method | Purpose |
|---|---|---|
| `/health` | GET | Process and chain status |
| `/v1/status` | GET | Same structured status response |
| `/v1/transactions` | POST | Submit a content-bound signed transaction |
| `/v1/mining/templates` | POST | Create Nexus work and gather direct-child candidates |
| `/v1/mining/work` | POST | Submit a nonce for issued work |
| `/v1/children/intents` | POST | Build a direct-child genesis intent |

See [docs/rpc-api.md](docs/rpc-api.md) for request and response shapes.

## Nexus genesis

Nexus starts from one deterministic local bootstrap block. Its sole unsigned
transaction credits the premine; the node recomputes the block CID locally and
requires the exact configured value:

`bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`

| Parameter | Value |
|---|---:|
| Owner public key | `ed01fe416588df6e7fa5213c0d3e430f504bb5203172120c86b874826b55f53bdb7d` |
| Timestamp | `0` |
| Target | `UInt256.max` |
| Target block time | `3,600,000 ms` |
| Initial reward | `1,048,576` |
| Halving interval | `876,600` blocks |
| Premine | `175,320` reward-block equivalents |
| Retarget window | `120` blocks |
| Maximum transactions | `5,000` per block |
| Maximum state growth | `3,000,000` bytes per block |
| Maximum block size | `1,000,000` bytes |

All other transactions, including ordinary child-genesis transactions and the
parent transaction that anchors a child, follow normal signature rules.

## Storage migration

The new store is intentionally incompatible with legacy node data. Stop the
process and remove the **entire configured storage directory**, including both
`state.db` and `volumes.db`; do not retain a legacy database or content volume.
On the next Nexus start, the node recreates the exact pinned genesis above.

```bash
rm -rf /var/lib/lattice/chains/Nexus
lattice-node --chain-path Nexus \
  --data-directory /var/lib/lattice/chains/Nexus
```

Back up any identity key you intend to reuse before removing a directory, or
place it outside the storage directory and pass `--identity-key` explicitly.

## Documentation

- [Getting started](docs/getting-started.md)
- [Architecture](docs/architecture.md)
- [Protocol reference](docs/protocol.md)
- [RPC API](docs/rpc-api.md)
- [Operations](docs/operations.md)
- [Deployment](deploy/README.md)
- [Chain addressing](docs/design/chain-addressing.md)

## Dependencies

The protocol packages are maintained under [adalinxx](https://github.com/adalinxx):
Lattice, Ivy, Tally, VolumeBroker, and cashew. `Package.swift` is the authority
for the exact compatible revisions or release tags.
