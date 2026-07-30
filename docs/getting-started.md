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

It initially reports `awaitingGenesis`. On the parent:

1. `POST /v1/children/intents` with directory `Payments`, the child spec,
   child-genesis transactions, target, and timestamp.
2. Construct and sign a parent transaction with the returned genesis CID in a
   matching `GenesisAction`.
3. `POST /v1/transactions` with that parent transaction.
4. Mine the parent carrier with `lattice-mining-coordinator --deployment`.

The hierarchy plane delivers the resulting authenticated genesis link to the
child. The child does not accept opaque genesis bytes on its command line.

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
