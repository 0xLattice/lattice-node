# Deployment

The tracked deployment assets target the current one-process/one-chain daemon.
Scripts for faucets, embedded trees, and workers that talk directly to nodes
were removed because those roles do not exist in Lattice.

## Rules that every deployment must preserve

1. Supply one absolute `--chain-path` beginning with `Nexus`.
2. Give every child an explicit authenticated immediate parent with `--parent`.
3. Keep the unauthenticated HTTP API on loopback.
4. Expose the same-chain overlay and, where required, the parent/child fact
   plane as separate ports.
5. Run `lattice-mining-coordinator` and external `lattice-miner` workers as
   separate processes from the node.
6. Treat `state.db` and `volumes.db` as one backup and recovery unit.
7. Use the single pinned Nexus genesis CID:
   `bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`.

Deploy a child chain with testing-oriented parameters when an application needs
a testing network. Nexus keeps the same pinned genesis in every deployment.

## systemd

Install the release binaries:

```bash
sudo install -m 0755 .build/release/lattice-node /usr/local/bin/lattice-node
sudo install -m 0755 .build/release/lattice-mining-coordinator \
  /usr/local/bin/lattice-mining-coordinator
sudo install -m 0755 .build/release/lattice-miner /usr/local/bin/lattice-miner
```

Then install [lattice-node.service](lattice-node.service) and
[lattice-miner.service](lattice-miner.service). The latter runs the coordinator
and launches external workers; its historical filename remains only so existing
unit-install automation does not need a rename.

Keep the node identity outside wipeable chain state:

```text
/var/lib/lattice/
  identity/nexus.key
  chains/Nexus/
    state.db
    volumes.db
```

## Container entrypoint

[entrypoint.sh](entrypoint.sh) dispatches explicitly to `lattice-node`,
`lattice-mining-coordinator`, or `lattice-miner`. Bare arguments default to the
node for image compatibility.

Example Nexus process:

```bash
docker run --network host \
  -v lattice-data:/home/lattice/.lattice \
  ghcr.io/adalinxx/lattice-node:2.0.0 \
  lattice-node \
  --chain-path Nexus \
  --data-directory /home/lattice/.lattice/chains/Nexus \
  --identity-key /home/lattice/.lattice/identity/nexus.key \
  --listen-port 4001 \
  --fact-listen-port 4002 \
  --rpc-port 8080
```

Run the coordinator in the same network namespace so the node API remains
loopback-only:

```bash
docker run --network host \
  ghcr.io/adalinxx/lattice-node:2.0.0 \
  lattice-mining-coordinator \
  --node http://127.0.0.1:8080 \
  --worker-executable /usr/local/bin/lattice-miner \
  --workers 2
```

## Child process

Allocate independent ports, storage, and identity for each child:

```bash
lattice-node \
  --chain-path Nexus/Payments \
  --parent <nexus-key>@10.0.0.10:4002 \
  --data-directory /var/lib/lattice/chains/Nexus/Payments \
  --identity-key /var/lib/lattice/identity/payments.key \
  --listen-port 4101 \
  --fact-listen-port 4102 \
  --rpc-port 8180
```

The child waits for the content-addressed genesis proof created by a parent
intent plus a separately signed parent `GenesisAction` transaction. It never
boots from an opaque serialized genesis field.

## Destructive migration

Stop the node and coordinator, preserve an identity key only if desired, and
remove the whole process storage directory:

```bash
sudo systemctl stop lattice-miner lattice-node
sudo rm -rf /var/lib/lattice/chains/Nexus
sudo systemctl start lattice-node lattice-miner
```

Do not keep a legacy database, `state.db`, or `volumes.db` across this migration.
Nexus recreates the exact pinned genesis; child processes return to
`awaitingGenesis` and reacquire an authenticated parent link.
