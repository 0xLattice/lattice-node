# Getting started

Run a node on one machine: install it, start it, and check that it follows
the network. It takes a few minutes, plus the time to sync.

## Install

On macOS (Apple silicon) or Linux (x86-64), install the latest release:

```bash
curl -fsSL https://lattice.build/install.sh | sh
```

It checks the download against its published SHA-256 and puts the programs
in `~/.lattice/bin`; add that directory to your `PATH`. To check a release
yourself, see [Release verification](release-verification.md).

Or build from source:

```bash
git clone https://github.com/0xLattice/lattice-node
cd lattice-node
swift build -c release
```

A source build needs Swift 6.1 or newer, and the SQLite development headers
on Linux. The examples also use `curl` and `jq`.

Either way you get four programs:

| Program | Purpose |
|---|---|
| `lattice` | The command-line tool you operate the node with. |
| `lattice-node` | The node. `lattice up` runs it. |
| `lattice-mining-coordinator` | Hands nonce ranges to mining workers and submits results. |
| `lattice-miner` | The CPU mining worker. |

The commands below assume they are on your `PATH`. A source build puts them
in `.build/release/`.

## Create a node

```bash
lattice init --root ./node-data
```

This creates the node's configuration and its identity key:

```text
node-data/
  lattice.json
  identity/Nexus.key
```

```json
{
  "listen": 4001,
  "rpc": 8080
}
```

`listen` is the port other nodes connect to. `rpc` is the operator API,
which only this machine can reach. With no `peers` listed, the node finds
the network through its built-in seeds.

## Start it

```bash
lattice up --root ./node-data
```

The node runs in the foreground and logs to the terminal. From another
shell:

```bash
lattice status --root ./node-data
curl -s http://127.0.0.1:8080/health | jq
```

`status` shows Nexus's height climbing as the node syncs. Stop the node with
Ctrl-C, or with `lattice down --root ./node-data`.

## Next

| To | Read |
|---|---|
| Run it as a service, monitor it, upgrade it | [Running in production](operations.md) |
| Change settings | [Configuration](configuration.md) |
| Mine | [Mining](mining.md) |
| Launch or host a child chain | [Child chains](child-chains.md) |
| Open ports, serve public reads, list a chain on an explorer | [Networking](networking.md) |
| Bound disk use, back up | [Storage](storage.md) |
| Send a transaction | [Operator CLI](operator-cli.md#keys-and-transactions) |
| Fix a problem | [Troubleshooting](troubleshooting.md) |
