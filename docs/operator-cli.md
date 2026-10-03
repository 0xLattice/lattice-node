# Operator CLI

`lattice` is the declarative front door for one host. It reads one
`lattice.json`, owns no resident state, and reconciles one `lattice-node`
process that hosts the configured Nexus-rooted tree.

Every command accepts `--root <directory>`. The current directory is the
default.

## Topology

```json
{
  "listen": 4001,
  "rpc": 8080,
  "peers": ["<public-key>@node.example:4001"],
  "externalAddress": "192.0.2.10",
  "publicRead": 8081,
  "publicReadRate": 25,
  "publicReadExpensiveRate": 1,
  "publicReadMaxRate": 200,
  "hostedChains": [
    "Nexus/Alpha",
    "Nexus/Alpha/Beta"
  ],
  "mine": {
    "worker": "cpu",
    "workers": 2,
    "batchSize": 2000000,
    "recipients": {
      "Nexus": "<address>",
      "Nexus/Alpha": "<address>",
      "Nexus/Alpha/Beta": "<address>"
    },
    "minBlockIntervalSeconds": 10
  }
}
```

This is intentionally one schema, without legacy decoding:

- `listen`, `rpc`, `peers`, public-read policy, and identity apply once to the
  process;
- `hostedChains` lists child paths parent before child;
- mining maps are keyed by hosted absolute path;
- ports must be nonzero and unique;
- rates must be finite and nonnegative;
- unknown paths in mining policy are rejected.

## Lifecycle

| Command | Effect |
|---|---|
| `lattice init` | Create `lattice.json` and the process identity, refusing to overwrite a topology. |
| `lattice up` | Start the one node process in the background. Restart it when the configured hosted path set changed. |
| `lattice up --foreground` | Supervise the node for container or init-system use. |
| `lattice status` | Read every hosted level from the one loopback RPC. |
| `lattice down` | Stop the node process under the spawn lock. |
| `lattice wipe` | Remove the complete stopped tree storage. Preserve identity, specs, and topology. |
| `lattice identity` | Print the process public key and peer string. |

Examples:

```bash
lattice init --root /var/lib/lattice
lattice up --root /var/lib/lattice
lattice status --root /var/lib/lattice
lattice down --root /var/lib/lattice
```

The PID file names the executable as well as the PID, so a recycled PID is not
signalled. Start, stop, restart, child creation, and wipe share one spawn lock.
Storage also has its own writer lock; `wipe` refuses if any node still owns it.

## Child chains

```bash
lattice child create Nexus/Alpha \
  --root /var/lib/lattice \
  --block-time 10000 \
  --reward 1000 \
  --premine 0
```

Or provide a complete `ChainSpec` JSON:

```bash
lattice child create Nexus/Alpha \
  --root /var/lib/lattice \
  --spec alpha-spec.json
```

Creation writes one immutable spec and adds the path to `hostedChains`. The
node builds the genesis candidate from that spec when the parent has an
executed state it can commit, and ordinary merged mining secures it. There is
no child-deploy command or parent authorization transaction.

For a nested child, create the parent first. Its genesis is not eligible until
the parent has executed a block. Give a chain positive rewards before relying
on it as a parent; a reward-free, transaction-free chain never changes state.

## Mining

| Command | Effect |
|---|---|
| `lattice mine start` | Start the background coordinator loop. |
| `lattice mine status` | Show its PID and configured recipients. |
| `lattice mine stop` | Finish or bound the active round, then stop. |

`mine.worker` is `cpu` for the bundled worker or an executable path implementing
the worker contract. `mine.recipients` controls each chain's reward and fee
recipient; an omitted path burns that payout. `mine.minWork` is a local search
filter, not a committed consensus target. `mine.minBlockIntervalSeconds` is a
floor on template spacing and releases itself when rounds run longer.

The mining loop probes the node for the template expiry and places a deadline
around each coordinator process group. A timeout is logged loudly and the next
round retries.

## Spending keys and transactions

```bash
lattice key generate --out ./wallet.json
```

Key files are created mode `0600`, and transaction commands refuse a
group/other-readable key.

```bash
lattice tx send \
  --root /var/lib/lattice \
  --chain Nexus/Alpha \
  --key ./wallet.json \
  --to <address> \
  --amount 25 \
  --fee 1
```

`tx deposit`, `tx receipt`, and `tx withdraw` expose the three cross-level
exchange actions. All submissions use the one RPC listener and carry their
absolute chain path. The CLI rejects a path this host does not serve; the node
also returns 404 for an unhosted path.

## systemd

Generate foreground units from the configured topology:

```bash
lattice emit-systemd --root /var/lib/lattice \
  > /etc/systemd/system/lattice.generated.units
```

The checked-in examples are [deploy/lattice-node.service](../deploy/lattice-node.service)
and [deploy/lattice-mining-coordinator.service](../deploy/lattice-mining-coordinator.service).
The coordinator unit requires a nonempty `RECIPIENT_ARGS` in
`/etc/lattice/mining.env` so production mining cannot silently burn all
rewards.

## Layout

```text
<root>/
  lattice.json
  identity/Nexus.key
  specs/Nexus%2FAlpha.json
  chains/Nexus/
    state.db
    volumes.db
    header-evidence.db
    storage.lock
  run/
  log/
```

There is no per-chain process, port, key, or child `state.db`. The path in
`specs/` identifies a level; runtime facts for every level share the one tree
journal.
