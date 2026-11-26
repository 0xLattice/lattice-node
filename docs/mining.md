# Mining

Mining is a separate process from the node. The node builds block templates
and accepts solved work; the miner searches for nonces. One search counts on
every chain the node hosts (merged mining).

To write your own worker, see the [worker contract](mining-workers.md).

## Start mining

1. Make a key to receive rewards, and note its address:

   ```bash
   lattice key generate --out ./wallet.json
   ```

2. Write `miner.json` in the node's root:

   ```json
   {
     "worker": "cpu",
     "workers": 2,
     "recipients": {
       "Nexus": "<address>",
       "Nexus/Alpha": "<address>"
     }
   }
   ```

3. Start the miner:

   ```bash
   lattice mine start --root /var/lib/lattice
   lattice mine status --root /var/lib/lattice
   ```

**A chain with no recipient burns its reward and fees.** List every chain
you want paid for.

| Command | Effect |
|---|---|
| `lattice mine start` | Start the mining loop in the background. Its pidfile is `run/mine.pid` and its output `log/mine.log`. |
| `lattice mine status` | Whether it runs, the node it mines through, and its recipients. |
| `lattice mine stop` | Finish or bound the active round, then stop. |
| `lattice mine run` | The same loop in the foreground, for a process manager. |
| `lattice logs --miner` | The mining loop's recent output. |

Under systemd, `lattice emit-systemd` prints a `lattice-mine.service` unit
when the root holds miner settings
([Running in production](operations.md#process-managers)).

## miner.json

The miner's settings are `<root>/miner.json`, or the file given with
`--config`. The node never reads it, and an unknown key is refused.

| Key | Default | Meaning |
|---|---|---|
| `worker` | `cpu` | `cpu` for the bundled worker, or the path of an executable implementing the [worker contract](mining-workers.md). |
| `workers` | 1 | How many workers to run. |
| `batchSize` | 2000000000 | Nonces a worker tries per batch. |
| `recipients` | none | The address each chain's reward and fees go to, by chain path. |
| `minWork` | scheduled target | A minimum work per block by chain path, such as `{"Nexus": "2^32"}`. The miner only submits hashes that meet it. It is a local filter: blocks still commit their scheduled target. |
| `minBlockIntervalSeconds` | none | The shortest gap between two blocks this miner produces. A floor: a round that ran longer does not wait. |
| `templateTimeoutSeconds` | 60 | How long to wait for the node to answer a template request before mining starts. 60 is also the most it can be. |
| `roundDeadlineMultiplier` | 10 | Headroom on the round deadline (below). |

The loop reads the file again before each round, so a changed recipient
applies to the next round without a restart. A file that no longer checks is
logged and the last good settings are kept.

## Mining through a node on another machine

By default the miner mines through the node under `--root`, over its loopback
API. To mine through a node elsewhere, give that node's
[remote operator listener](rpc-api.md#remote-operator-listener) and a token.
A mining token needs three routes:

```bash
# Beside the node:
lattice tokens create miner --out miner.token --root /var/lib/lattice \
  --route "POST /mining/templates" --route "POST /mining/work" --route "GET /status"

# On the mining machine, with its own root for settings, pidfile and log:
lattice mine start --root /var/lib/lattice-miner \
  --node http://10.0.0.5:8090 --token-file miner.token
```

The miner always runs on the machine `lattice mine` runs on. `--node` only
says which node it mines through.

## Running the coordinator directly

`lattice mine` runs `lattice-mining-coordinator` for each round. You can run
the coordinator yourself instead, as the checked-in
[`lattice-mining-coordinator.service`](../deploy/lattice-mining-coordinator.service)
does:

```bash
lattice-mining-coordinator \
  --node http://127.0.0.1:8080 \
  --rpc-cookie-file <root>/chains/Nexus/.cookie \
  --worker-executable /usr/local/bin/lattice-miner \
  --workers 2 \
  --recipient Nexus=<address> \
  --recipient Nexus/Alpha=<address>
```

That unit reads its recipients from `/etc/lattice/mining.env` and refuses to
start when the file names none, so it cannot silently burn every reward:

```bash
install -d -m 0750 /etc/lattice
cat >/etc/lattice/mining.env <<'EOF'
RECIPIENT_ARGS=--recipient Nexus=<address> --recipient Nexus/Alpha=<address>
EOF
chmod 0640 /etc/lattice/mining.env
```

Use one or the other for a node, not both.

## How a round works

- **Templates follow the whole tree.** A new transaction, a new child
  candidate or an accepted child block changes the template, and the miner
  fetches new work even when the Nexus tip did not move.
- **Issued work stays valid.** A solution on an old tip is submitted and
  becomes a side block.
- **Work is credited per chain.** A hash counts for each chain whose target
  it meets.
- **Work never expires on a clock.** The round deadline only catches a hung
  coordinator: 600 seconds until a first round completes, then the longest
  completed round (counted up to 600 seconds) times
  `roundDeadlineMultiplier`, never less than 600 seconds. A timeout is logged
  and the next round retries.

## What to alert on

- The miner reports no usable template for longer than one expected block
  interval.
- A round deadline is exceeded.
- A reward burns because a recipient is absent.
- A chain meant to parent a nested child has stopped changing state
  ([Child chains](child-chains.md#nested-chains)).

The node's mining metrics are listed in
[Running in production](operations.md#metrics).
