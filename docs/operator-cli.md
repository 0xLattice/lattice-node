# Operator CLI

`lattice` operates one node. `lattice up` runs the node in the foreground;
every other command asks the running node over its operator API.

## Choosing the node

| Option | Meaning |
|---|---|
| `--root <directory>` | The node's root. The current directory is the default. |
| `--node <url> --token-file <file>` | A node elsewhere, through its [remote operator listener](#remote-control). |

`init`, `identity`, `key`, `up`, `mine stop`, `emit-systemd` and
`emit-launchd` work on the local machine only.

## Commands

### Lifecycle

| Command | Effect |
|---|---|
| `lattice init [--peer <peer>]` | Create `lattice.json` and the node's identity key. Refuses to overwrite a configuration. |
| `lattice identity` | Print the node's public key and its peer string. |
| `lattice up` | Run the node in the foreground. |
| `lattice status` | One line per hosted chain: phase, height, best header height, tip, and what it waits on. Also chains hosted only for a chain beneath them, configured chains not running, and settings waiting for a restart. |
| `lattice logs [--tail N]` | The running node's recent log lines. `--miner` reads the local mining loop's instead. |
| `lattice restart` | Restart the node and wait until it answers again. Refused while the configuration would not start the node. |
| `lattice down` | Stop the node. |
| `lattice wipe` | Delete chain storage. Keeps the identity, configuration, specs and tokens. A running node wipes as it restarts. |
| `lattice emit-systemd` | Print systemd units for this root. |
| `lattice emit-launchd` | Print a launchd job for this root (macOS). |

`restart` and `wipe` rely on a process manager to start the node again
([Running in production](operations.md#process-managers)). Run by hand, the
node stays stopped: start it again yourself.

### Configuration

| Command | Effect |
|---|---|
| `lattice config get [a.b.c]` | Print the merged configuration, or one key. `--fragment <name>` prints one fragment. |
| `lattice config set a.b.c=value ...` | Change keys. `--patch '<json>'` applies a JSON merge patch. |
| `lattice config unset a.b.c ...` | Remove keys. |
| `lattice apply -f <file> --fragment <name>` | Replace one fragment whole. |

See [Configuration](configuration.md) for the keys and for when a change
takes effect.

### Child chains

| Command | Effect |
|---|---|
| `lattice child create <path>` | Write a chain's spec and host it. |
| `lattice child host <path>` | Host a chain that already exists. |
| `lattice child unhost <path>` | Stop hosting a chain and delete its data. |
| `lattice child commit <path> --key <file>` | Build the chain's next block, commit it on its parent, and push it. |

See [Child chains](child-chains.md).

### Mining

| Command | Effect |
|---|---|
| `lattice mine start` | Start the mining loop in the background. |
| `lattice mine status` | Whether it runs, the node it mines through, and its recipients. |
| `lattice mine stop` | Stop the mining loop. |
| `lattice mine run` | The mining loop in the foreground. |

See [Mining](mining.md).

### Keys and transactions

| Command | Effect |
|---|---|
| `lattice key generate --out <file>` | Create a key file (address, private key, public key), mode `0600`. |
| `lattice tx send --to <address> --amount <n>` | Transfer coin. |
| `lattice tx deposit --lock <n>` | Lock coin on a child chain for an exchange with its parent. |
| `lattice tx receipt --demander <address> --directory <name>` | Pay the demander on the parent chain. |
| `lattice tx withdraw --demander <address> --amount <n> [--to <address>]` | Withdraw the locked deposit on the child chain. |
| `lattice tx commit-child --directory <name> --block <cid> --parent-state <cid> [--previous <value>]` | Sign one child-block commitment. `lattice child commit` sends these for you. |

Every `tx` command takes:

| Option | Meaning |
|---|---|
| `--chain <path>` | The chain the transaction is for, such as `Nexus/Alpha`. |
| `--key <file>` | The key that signs and pays. A key file readable by group or others is refused. |
| `--fee <n>` | Defaults to the node's `minRelayFee`. |
| `--nonce <n>` | Defaults to the key's next nonce on that chain. |

`deposit`, `receipt` and `withdraw` are the three steps of a cross-chain
exchange ([Cross-chain transfers](https://lattice.build/docs/protocol/cross-chain/)).
They share `--swap-nonce <n>`, which identifies the exchange, and
`--demand <n>`, the amount paid on the parent.

```bash
lattice tx send \
  --root /var/lib/lattice \
  --chain Nexus/Alpha \
  --key ./wallet.json \
  --to <address> \
  --amount 25
```

A path the node does not host is refused by the CLI, and the node answers
404 for it.

### Pinned content

| Command | Effect |
|---|---|
| `lattice pins list` | List the pinned Volumes. |
| `lattice pins add <cid> [--fetch]` | Pin a Volume by its root CID. With `--fetch`, read it from peers first. |
| `lattice pins remove <cid>` | Unpin a Volume. |

See [Storage](storage.md#pinned-content).

### Remote operator tokens

| Command | Effect |
|---|---|
| `lattice tokens list` | List each token's name and what it may use. |
| `lattice tokens create <name>` | Make a token. `--role admin` allows every route, `--role read` every `GET`; or repeat `--route "METHOD /path"`. |
| `lattice tokens revoke <name>` | Revoke a token, from the next request. |

The secret is printed once, or written with `--out <file>` (mode `0600`).
The node keeps only its SHA-256.

## Remote control

To operate a node from another machine, give it a listener on a private
network and an admin token:

```bash
# Beside the node, once:
lattice config set operatorListen=10.0.0.5:8090 operatorTokens=operator-tokens.json --root /var/lib/lattice
lattice restart --root /var/lib/lattice
lattice tokens create ops --role admin --out ops.token --root /var/lib/lattice

# Anywhere on that network:
lattice status --node http://10.0.0.5:8090 --token-file ops.token
lattice child create Nexus/Alpha --block-time 10000 --reward 1000 --node http://10.0.0.5:8090 --token-file ops.token
lattice config set minRelayFee=5 --node http://10.0.0.5:8090 --token-file ops.token
```

Keep the listener on a private network or behind a TLS proxy: it is plain
HTTP. A remote client may not set `operatorTokens`, which names a file on
the node's machine. The listener is described in the
[HTTP API](api-operator.md#remote-operator-listener).
