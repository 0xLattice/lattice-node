# Deployment

The tracked deployment assets run one `lattice-node` process for a complete
Nexus-rooted tree. The process has one identity, overlay, operator RPC,
optional public-read listener, content store, and path-keyed fact journal.
Mining is external:
[lattice-miner](https://github.com/0xLattice/lattice-miner) is a client of the
node's mining routes.

## Required invariants

1. List hosted child paths parent first in the flat `hostedChains` array.
2. Keep the operator RPC on loopback. Publish only the GET-only read listener
   or a proxy allowing no more than it.
3. Expose one overlay port for the tree, not one port per hosted chain.
4. Treat `state.db` and `volumes/` (a Volume store per hosted chain) as one
   recovery unit.
   `volume-bundles.db` is a cache and may be lost.
5. Use one reviewed revision for the node, CLI, and deployment image.
6. Pin Nexus to
   `bafyreiggtg4ezifboyekbf4gxst2jr3mpjqcxsbmopy7w6fp46g4ngpgxa`.
7. Start with a fresh runtime store after any incompatible release. There are
   no storage migrations or compatibility readers.

## systemd

Install both release binaries from the same build:

```bash
sudo install -m 0755 .build/release/lattice /usr/local/bin/lattice
sudo install -m 0755 .build/release/lattice-node /usr/local/bin/lattice-node
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

Install [lattice-node.service](lattice-node.service). To mine, run
lattice-miner beside it with its own `miner.json` (`recipients` maps each chain
path to the address its reward and fees go to; an omitted chain burns its
payout); `lattice emit-systemd` prints a unit for it when the root holds
`miner.json` (see [the operator CLI](../docs/operator-cli.md#mining)).

The persistent layout is:

```text
/var/lib/lattice/
  lattice.json
  identity/Nexus.key
  specs/
  chains/Nexus/
    state.db
    volumes/          a Volume store per hosted chain, named by its path's SHA-256
    volume-bundles.db
```

The single `chains/Nexus` directory contains facts for every hosted path, in
`state.db`, and a Volume store per hosted path under `volumes/`. There are no
per-child identity keys.

## Containers and Fly

Operator deployments (the public read replica, followers, app names,
addresses, peers, and public submit policy) live in
[lattice-ops](https://github.com/0xLattice/lattice-ops), not in this
repository.

The public-read listener or proxy must never expose `/status`, `/metrics`,
`/core/snapshot`, or any POST route.

## Flag-day upgrades

There is no in-place migration. For an incompatible schema, consensus, or
wire cutover, stop the node (and its miner), preserve only
identity/config/specs, wipe the whole runtime tree with the CLI, install one
release, and restart:

```bash
sudo systemctl stop lattice-node
sudo -u lattice lattice wipe --root /var/lib/lattice
sudo systemctl start lattice-node
```

Never combine databases from different snapshots. For ordinary backups, stop
the processes and snapshot `lattice.json`, `identity`, `specs`, and
`chains/Nexus` together. See [the operations runbook](../docs/operations.md)
for preflight, recovery, discovery, mining, and alerting details.
