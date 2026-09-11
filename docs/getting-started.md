# Getting started

## Build

Requires Swift 6.1 or newer.

```bash
git clone https://github.com/adalinxx/lattice-node.git
cd lattice-node
swift build
```

The package builds four executables:

- `lattice-node` — one chain process.
- `lattice-mining-coordinator` — node-facing work scheduler.
- `lattice-miner` — stateless nonce-range worker.
- `lattice-proof-verifier` — proof verification utility.

## Start Nexus

```bash
swift run lattice-node \
  --chain-path Nexus \
  --listen-port 4001 \
  --fact-listen-port 4002 \
  --rpc-port 8080
```

The default storage path is `~/.lattice/chains/Nexus`. On its first start the
node creates a mode-0600 `process.key`, constructs the deterministic Nexus
genesis, and verifies its CID:

`bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`

The RPC server listens on loopback. Non-loopback `--rpc-bind` values are
rejected because the current HTTP surface is unauthenticated.

Add same-chain peers explicitly:

```bash
swift run lattice-node \
  --chain-path Nexus \
  --peer <public-key>@192.0.2.10:4001 \
  --peer <public-key>@198.51.100.20:4001
```

Peer identity admission uses `--minimum-peer-key-bits` (default `0`). Generated
process identities work at that default. Set a nonzero threshold only when every
peer that must connect has deliberately generated a qualifying identity.

## Check status

```bash
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/v1/status
```

Both endpoints return the process phase, absolute chain path, pinned Nexus
genesis CID, tip, height, and bounded service counts.

## Run external mining

The coordinator obtains Nexus templates and gives immutable nonce ranges to
external workers:

```bash
swift run lattice-mining-coordinator \
  --node http://127.0.0.1:8080 \
  --worker-executable .build/debug/lattice-miner \
  --workers 2
```

Use `--once` for one bounded coordinator batch. `lattice-miner` is not a
node-facing daemon; the coordinator launches it with a concrete work ID, block,
target, start nonce, and count.

`--rewards-file` accepts the complete, at-most-1-MiB externally signed template
request JSON (`{"rewards":[...]}`). Omit it for no rewards; the coordinator has
no identity or private-key flag.

## Start a child process

All chain paths are absolute and Nexus-inclusive. Start a child with its full
path and its immediate parent's authenticated fact endpoint:

```bash
swift run lattice-node \
  --chain-path Nexus/Payments \
  --parent <nexus-process-public-key>@127.0.0.1:4002 \
  --listen-port 4101 \
  --fact-listen-port 4102 \
  --rpc-port 8180
```

It initially reports `awaitingGenesis`. To give a new chain its genesis:

1. Build the self-contained child genesis offline from a seed: the child spec,
   an optional premine recipient, and a timestamp. The same seed always yields
   the same genesis CID.
2. Write that seed as `child-genesis.json` into the child's data directory
   before starting the child. The node reads the file only at startup, so a
   child that was already running must be restarted after the file is written.
3. Construct and sign a parent transaction carrying the genesis CID in a
   `GenesisAction` for directory `Payments`.
4. `POST /v1/transactions` on the parent with that transaction.
5. Mine the parent with `lattice-mining-coordinator` as usual; the transaction
   is selected like any other.

A child started with the seed retries until the parent's record lands. A child
also tries to fetch the recorded genesis block by CID from child-overlay peers,
but a brand-new chain has no peer serving it, so the first node of a new chain
needs the seed. Either way, the child admits the genesis only after its
authenticated parent confirms that exact record. The child does not accept
opaque genesis bytes on its command line. `lattice child deploy` performs all
of these steps for a local tree.

## Testing an application

Create a child chain with testing-oriented rewards, limits, and target cadence.
Nexus retains its one pinned genesis. The testing chain's address is
still a normal absolute path such as `Nexus/MyAppTest`, and it exercises the
same child-deployment and merged-mining rules as any production child.

## Storage

Each process owns one directory:

```text
~/.lattice/chains/Nexus/
  process.key
  state.db
  volumes.db
```

For a custom location:

```bash
lattice-node \
  --chain-path Nexus \
  --data-directory /var/lib/lattice/chains/Nexus
```

The current store does not import legacy layouts. During migration, back up any
identity key you want to retain, stop the process, and delete the entire
configured storage directory. Do not preserve only `state.db` or only
`volumes.db`.

## Next steps

- [HTTP API](rpc-api.md)
- [Architecture](architecture.md)
- [Operations](operations.md)
- [Deployment](../deploy/README.md)
- [Chain addressing](design/chain-addressing.md)
