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

To pay mining rewards, generate a key and a pre-signed batch with
`lattice-rewards` on a trusted machine (the key never ships to the miner) and
run [mine-supervisor.py](mine-supervisor.py) beside the coordinator; see the
"Mining rewards" section of [docs/operations.md](../docs/operations.md).

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

## Read replica (public read surface)

`read-replica/` is the public read surface for the explorer (lattice.build).
It is a normal lattice-node — dialing the backbones and syncing — with an nginx
**allowlist** proxy in front: the node's HTTP API stays loopback-only (rule 3),
and nginx exposes ONLY the bounded GET read routes (`/health`, `/v1/blocks*`,
`/v1/transactions/:cid`, `/v1/accounts/:owner`, `/api/*`), returning 403 for
everything else — crucially `/v1/status` (gated + mutating) and every write POST.

- `Dockerfile` — `FROM ghcr.io/adalinxx/lattice-node:sha-<...>` + nginx. Bump the
  pinned sha on each read-RPC release so the allowlist matches the node's routes.
- `nginx.conf` — the allowlist itself (the auditor-required public/internal
  boundary). Any route change must land with its allowlist change in the same diff.
- `entrypoint.sh` — starts nginx, then the node in the foreground.
- `fly.toml` — the fly app (`lattice-mainnet-read`); 443/80 → nginx (8081).
- `test-allowlist.sh` — asserts the boundary (allowed routes proxy through, denied
  routes 403) by running the real `nginx.conf` against a stub upstream in Docker.
  Runs in CI (`read-replica-allowlist` job); run locally with
  `bash deploy/read-replica/test-allowlist.sh`.

Deploy: `flyctl deploy ./deploy/read-replica --config ./deploy/read-replica/fly.toml -a lattice-mainnet-read`.
