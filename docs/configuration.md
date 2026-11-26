# Configuration

A node's configuration is one JSON object: `lattice.json` in the root, merged
with the fragments in `config.d/`. This page lists every key. The miner has
its own file, `miner.json` ([Mining](mining.md#minerjson)).

```json
{
  "listen": 4001,
  "rpc": 8080,
  "peers": { "Nexus": ["<public-key>@node.example:4001"] },
  "externalAddress": "192.0.2.10",
  "publicRead": 8081,
  "publicReadURL": "https://reads.example.org",
  "state": "recent",
  "hostedChains": ["Nexus/Alpha", "Nexus/Alpha/Beta"]
}
```

`lattice init` writes the first two keys; everything else is optional. An
unknown key is refused, and a configuration that does not check stops the
node at start with the reason (exit 78).

## Changing it

```bash
lattice config get [a.b.c]              # the merged configuration, or one key
lattice config set minRelayFee=5        # a value that parses as JSON is JSON, else a string
lattice config set --patch '{"stateWindows": {"Nexus/Alpha": 500}}'
lattice config unset minRelayFee
```

- **What applies when.** A running node applies `hostedChains` and
  child-chain `peers` at once. Every other key waits for the next start;
  `lattice status` lists what waits, and `lattice restart` applies it.
- **Refused changes.** A change that does not check, or that the node could
  not start from, is refused and nothing is written.
- **A stopped node.** The same commands write the file directly, checked
  first, under the node's storage lock.
- **Editing by hand.** A file edited by hand is read at the next start, or on
  `SIGHUP` (`systemctl reload`, or `kill -HUP`), and checked the same way.
- **Inert settings.** A setting for a chain that is not hosted (its peers or
  windows) is not an error. `lattice status` lists it as inert.

### Fragments

`config.d/<name>.json` files are layers over `lattice.json`, so that several
tools can each own part of the configuration.

- Layers merge in name order: `lattice.json` first, then `config.d` by file
  name. Number fragments to order them.
- `lattice config set`, `config unset`, `child host` and `child unhost`
  write the `operator` fragment (`config.d/operator.json`).
- `lattice apply -f <file> --fragment <name>` replaces one fragment whole,
  for a tool or script that owns it. `lattice config get --fragment <name>`
  reads one.
- A file in `config.d` whose name is not a fragment's is not read;
  `lattice status` lists it.
- When a layer on disk does not merge (a file broken by hand), the commands
  fail with the reason. Fix that file, or replace it with `lattice apply`.

Edits are safe against each other: each sends the version it read and is
redone when another writer changed the fragment meanwhile.

## Listeners

| Key | Default | Meaning |
|---|---|---|
| `listen` | 4001 | The overlay port, TCP. One port for the whole tree. |
| `rpc` | 8080 | The operator API port. It binds loopback only. |
| `rpcAllowedOrigins` | none | Browser origins allowed on the operator API, exactly as the browser sends them. |
| `webSocket` | 4002 if it can bind | The port browsers reach the node on (TCP and UDP). `0` turns it off. Set explicitly, failing to bind is an error. |
| `webSocketURL` | none | The `ws://` or `wss://` URL browsers dial, at most 256 printable ASCII bytes. Needs `webSocket` set to the listener's port. |
| `externalAddress` | observed | The host other nodes can reach this one at. Set it when the observed source address is not dialable. |
| `operatorListen` | off | `address:port` of the remote operator listener, on a port of its own. Goes with `operatorTokens`. |
| `operatorTokens` | off | The token file for `operatorListen`; a relative path is under the root. A remote client may not set it. |
| `operatorAllowedOrigins` | none | Browser origins the remote operator listener answers. Needs `operatorListen`. |

Ports must be nonzero and unique (only `webSocket` may be `0`). What each
listener serves, and what to expose, is in
[Networking](networking.md#ports).

## Peers

| Key | Default | Meaning |
|---|---|---|
| `peers` | built-in seeds | Peers by chain path, each `<public-key>@host:port`. |
| `announceLifetime` | 1200 | Seconds each provider announcement lasts, 1 to 86400. |

```json
"peers": {
  "Nexus": ["<public-key>@node.example:4001"],
  "Nexus/Alpha": ["<public-key>@alpha-host.example:4001"]
}
```

- **Nexus's list replaces the built-in seeds.** Those peers are dialled from
  the start and kept. An empty list means connect to no one.
- **A child chain's list is extra seeds for that chain**, beside what it
  finds through its parent. The chain must be hosted. An empty list is the
  same as none.
- An array, `"peers": ["<public-key>@node.example:4001"]`, is Nexus's list.

How a node uses them is in [Networking](networking.md#how-a-node-finds-peers).

## Public reads and submits

| Key | Default | Meaning |
|---|---|---|
| `publicRead` | off | Port of the public read listener. It binds all interfaces and serves only the bounded GET read routes. |
| `publicReadMaxRate` | 200 | Requests per second the read listener accepts, all clients together. `0` removes the limit. |
| `publicReadFetches` | 4 | Volumes the read listener reads from peers at once for readers. `0` serves only what the node holds. |
| `publicReadURL` | none | This host's public read URL, declared for every chain it hosts. Absolute `https://` or `http://`, with a host and no credentials, query or fragment. |
| `publicSubmit` | false | Also accept `POST /transactions` on the read listener. Needs `publicRead`. |
| `publicSubmitRate` | 10 | Requests per second for public `POST /transactions`, separate from reads. `0` removes the limit. |
| `minRelayFee` | 1 | The smallest fee this node admits to its pool, on every hosted chain. Node policy, not consensus. |

`publicReadRate` and `publicReadExpensiveRate` are accepted and ignored.

See [Public reads](networking.md#public-reads) and
[Public submit](networking.md#public-submit).

## What the node keeps

| Key | Default | Meaning |
|---|---|---|
| `blockBodies` | `all` | `all` keeps every block body the node executed; `none` keeps only each chain's tip and genesis. |
| `state` | `all` | `all`, `recent` or `none`. `tip` is accepted as `recent`. |
| `stateWindow` | 64 | With `state: recent`, how many blocks of replaced state each chain keeps, counting its tip. At least 1. |
| `stateWindows` | none | `stateWindow` for single chains, by path: `{"Nexus/Alpha": 500}`. |
| `connectBatch` | 32 | The most blocks of one chain executed and committed together. At least 1. |

A state window with `state` set to `all` or `none` is refused. What each
choice costs is in [Storage](storage.md#what-a-node-keeps).

## Memory and serving limits

| Key | Default | Meaning |
|---|---|---|
| `servingMaxConcurrent` | 64 | Content requests served to peers at once. Further requests wait. |
| `servingMaxInFlightVolumeBytes` | 134217728 (128 MiB) | Bytes of Volumes the node reads or sends to peers at once. |
| `maxAcquisitionBytes` | 268435456 (256 MiB) | Bytes of fetched content the node's fetches hold in memory at once, all chains together. At least what one block's fetch may hold. |

## Hosted chains

| Key | Default | Meaning |
|---|---|---|
| `hostedChains` | none | Child chain paths this node hosts, each listed after its parent. Nexus is always hosted. |

Use `lattice child create`, `host` and `unhost` rather than editing this
list ([Child chains](child-chains.md)).

## Node-local finality

| Key | Default | Meaning |
|---|---|---|
| `finalityWindow` | off | Blocks. The node declines headers and work more than this far below a chain's best tip. Absent or `0` is off. |
| `finalityWindows` | none | `finalityWindow` for single chains, by path: `{"Nexus/Alpha": 500}`. `0` turns it off for that chain. |

Lattice has no protocol finality. This is one node's own policy: nodes with
different windows, or none, agree on every block's validity.

**What it does.** A header more than the window below a chain's best tip, by
height, is declined: not stored, not weighed, never blamed and not asked for
again. So is new work crediting such a block. A fork from a block deeper than
the window can never connect. The next block on the tip is never outside the
window, so a stalled chain can always be extended. When the best tip moves to
a lower height the window moves down with it, and what was declined is judged
again when it next arrives.

**What it costs.** The node does not follow a reorganization deeper than the
window, even a heavier one. A node partitioned or offline for longer than its
window stays on its side until its operator intervenes, and a miner in that
state mines the losing side.

**Choosing a window.**

- Leave it off on miners, on nodes other nodes depend on, and on nodes that
  explorers read.
- A fork `d` blocks deep is at most `2^(d / halfLife)` cheaper than work at
  the tip. Nexus's half-life is 120 blocks, so a window of 240 caps that
  discount at about 4×. At a one-hour block time 240 blocks is about 10 days.
- Choose a window far longer than any outage you expect.
- Give each child chain a window at least as long as its parent's: a parent
  reorganization can reorganize the child.
- The window does not bound storage. It declines new forks and deletes
  nothing; `blockBodies` and `state` bound storage.

`GET /api/chain/info` reports a chain's effective window as `finalityWindow`,
absent when off.

## Flags

`lattice up` runs `lattice-node --root <root>`, which reads this
configuration. Started without `--root`, `lattice-node` takes the same
settings as flags named after the keys (`publicReadMaxRate` is
`--public-read-max-rate`, `stateWindows` is `--state-window Nexus/Alpha=500`).
`lattice-node --help` lists every flag.

Some peer-discovery settings have no key and are flags only:

| Flag | Default | Meaning |
|---|---|---|
| `--peer-target` | 8 | With fewer current peers than this, a chain dials peers it remembers. |
| `--peers-before-seeds` | 2 | With fewer current peers than this, a chain dials its seeds. |
| `--peer-search-interval` | 600 | Seconds without a new block on a chain before it widens its peer search. `0` only for an intentionally isolated node. |
| `--provider-walk-sessions` | 64 | Sessions that provider announcements and lookups may open. `0` keeps them among peers already connected. |
| `--no-announce-pins` | off | Hold and serve pinned Volumes without announcing them. |
