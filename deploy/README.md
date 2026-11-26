# Deployment

Ready-made systemd units for one node and its miner. For the general guide,
including launchd, containers and Fly, see
[Running in production](../docs/operations.md).

| File | Runs |
|---|---|
| [lattice-node.service](lattice-node.service) | `lattice up --root /var/lib/lattice` as user `lattice`. |
| [lattice-mining-coordinator.service](lattice-mining-coordinator.service) | The mining coordinator with two CPU workers. |
| [prometheus/lattice-alerts.yml](prometheus/lattice-alerts.yml) | Alert rules for the node's metrics. |

`lattice emit-systemd` prints equivalent units for any root, named
`lattice-tree` and `lattice-mine`. Use one set or the other.

## Install

1. Install all four binaries from the same release:

   ```bash
   sudo install -m 0755 lattice lattice-node lattice-mining-coordinator lattice-miner \
     /usr/local/bin/
   ```

2. Create the root and check it:

   ```bash
   sudo -u lattice lattice init --root /var/lib/lattice
   ```

   To use your own peers instead of the built-in seeds, add
   `--peer '<public-key>@<host>:4001'`.

3. Install and start the node's unit:

   ```bash
   sudo install -m 0644 lattice-node.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now lattice-node
   sudo -u lattice lattice status --root /var/lib/lattice
   ```

4. To mine, name the recipients and start the coordinator's unit:

   ```bash
   sudo install -d -m 0750 /etc/lattice
   echo 'RECIPIENT_ARGS=--recipient Nexus=<address> --recipient Nexus/Alpha=<address>' \
     | sudo tee /etc/lattice/mining.env
   sudo chmod 0640 /etc/lattice/mining.env
   sudo install -m 0644 lattice-mining-coordinator.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now lattice-mining-coordinator
   ```

   The unit refuses to start with no recipients. A chain left out burns its
   reward and fees ([Mining](../docs/mining.md)).

## Rules to keep

1. Keep the operator API on loopback. Publish only the public read listener,
   or a proxy that allows no more than it does: never `/status`, `/metrics`,
   `/core/snapshot`, or a POST route other than public submit.
2. Expose one overlay port for the tree, not one per chain.
3. Back up and restore `state.db` and `volumes/` together
   ([Storage](../docs/storage.md#backups)).
4. Run the node, the coordinator, the workers and the CLI from one release.
