# Deployment

The tracked deployment assets run one `lattice-node` process for a complete
Nexus-rooted tree. The process has one identity, overlay, operator RPC,
optional public-read listener, content store, and path-keyed fact journal.
Mining remains external: one coordinator assigns nonce ranges to stateless
workers.

## Required invariants

1. List hosted child paths parent first in the flat `hostedChains` array.
2. Keep the operator RPC on loopback. Publish only the GET-only read listener
   or the checked-in nginx allowlist.
3. Expose one overlay port for the tree, not one port per hosted chain.
4. Treat `state.db`, `volumes.db`, and `header-evidence.db` as one recovery
   unit.
5. Use one reviewed revision for the node, coordinator, workers, CLI, and
   deployment image.
6. Pin Nexus to
   `bafyreiea6sw7enxfy7wn6jwc2ubtplkhp2buierain3lb3roqo6n4bjyvm`.
7. Start with a fresh runtime store after any incompatible release. There are
   no storage migrations or compatibility readers.

## systemd

Install all four release binaries from the same build:

```bash
sudo install -m 0755 .build/release/lattice /usr/local/bin/lattice
sudo install -m 0755 .build/release/lattice-node /usr/local/bin/lattice-node
sudo install -m 0755 .build/release/lattice-mining-coordinator \
  /usr/local/bin/lattice-mining-coordinator
sudo install -m 0755 .build/release/lattice-miner /usr/local/bin/lattice-miner
```

Initialize `/var/lib/lattice`, edit the generated flat topology, and verify it
before starting the unit:

```bash
sudo -u lattice lattice init --root /var/lib/lattice \
  --peer '<public-key>@<host>:4001'
sudo -u lattice lattice status --root /var/lib/lattice
```

For a hosted child, create its immutable spec with `lattice child create` or
place the spec under `/var/lib/lattice/specs` and add the absolute path to
`hostedChains`. A nested child needs its parent to have executed a block of its
own; configure a positive parent reward when the parent otherwise has no state
changes.

Install [lattice-node.service](lattice-node.service) and
[lattice-mining-coordinator.service](lattice-mining-coordinator.service). The
coordinator requires `/etc/lattice/mining.env`:

```text
RECIPIENT_ARGS=--recipient Nexus=<address> --recipient Nexus/Alpha=<address>
```

Protect the file as mode `0640`. Omit a recipient only when burning that
chain's payout is intentional.

For a bare-metal binary refresh from GHCR, install `crane` from a separately
verified source and pass [upgrade-binaries.sh](upgrade-binaries.sh) the image's
immutable `sha256:...` digest. The script refuses mutable tags and never changes
the data directory.

The persistent layout is:

```text
/var/lib/lattice/
  lattice.json
  identity/Nexus.key
  specs/
  chains/Nexus/
    state.db
    volumes.db
    header-evidence.db
```

The single `chains/Nexus` directory contains facts for every hosted path.
There are no per-child databases or identity keys.

## Containers and Fly

Both deployment Dockerfiles build the repository checkout directly, so the
image cannot silently inherit an older node binary.

- `read-replica/` builds a Nexus follower plus nginx. The node RPC remains on
  loopback; nginx exposes only bounded GET routes on port 8081.
- `testnet-follower/` builds all binaries and writes one flat `lattice.json`
  from `NEXUS_PEERS`, `EXTERNAL_HOST`, and parent-first `HOSTED_CHAINS`.

Deploy from the repository root so each Dockerfile can copy the reviewed
sources:

```bash
fly deploy -c deploy/read-replica/fly.toml .
fly deploy -c deploy/testnet-follower/fly.toml .
```

Run the allowlist test whenever public routes change:

```bash
bash deploy/read-replica/test-allowlist.sh
```

The public-read listener or proxy must never expose `/status`, `/metrics`,
`/core/snapshot`, or any POST route.

## Flag-day upgrades

There is no in-place migration. For an incompatible schema, consensus, or
wire cutover, stop both units, preserve only identity/config/specs, wipe the
whole runtime tree with the CLI, install one release, and restart:

```bash
sudo systemctl stop lattice-mining-coordinator lattice-node
sudo -u lattice lattice wipe --root /var/lib/lattice
sudo systemctl start lattice-node lattice-mining-coordinator
```

Never combine databases from different snapshots. For ordinary backups, stop
the processes and snapshot `lattice.json`, `identity`, `specs`, and
`chains/Nexus` together. See [the operations runbook](../docs/operations.md)
for preflight, recovery, discovery, mining, and alerting details.

For a Nexus relaunch across the public Fly hosts (new genesis, wipe, restore,
first block), follow [RELAUNCH.md](RELAUNCH.md).
