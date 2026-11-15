# Operator CLI

`lattice` operates one node: it starts `lattice-node --root <root>`, which
hosts the Nexus-rooted tree its `lattice.json` describes, and then asks that
node, over its operator API, for everything else. The node owns
`lattice.json` while it runs ([Operator control](rpc-api.md#operator-control)).

Every command accepts `--root <directory>` (the current directory is the
default). Every command that operates a node also accepts `--node <url>
--token-file <file>`: it then asks that node's
[remote operator listener](rpc-api.md#remote-operator-listener) instead of
the one under `--root` (loopback and its cookie). Only `init`, `identity`,
`key`, `up`, `down`, `mine stop` and `emit-systemd` work on the local machine
alone. The miner always runs on the machine `lattice mine` runs on; `--node`
only says which node it mines through.

## Operating a node

| Command | Effect |
|---|---|
| `lattice status` | Each hosted chain's phase and tip, configured chains not running, keys waiting for a restart. |
| `lattice config get [a.b.c]` | The configuration, or one key of it. |
| `lattice config set a.b.c=value ...` | Change keys (a value that parses as JSON is JSON, else a string), or `--patch '<merge patch>'`. |
| `lattice config unset a.b.c ...` | Remove keys. |
| `lattice child create/host/unhost/commit` | [Child chains](#child-chains). |
| `lattice mine start/stop/status` | [Mining](#mining). |
| `lattice tx ...` | [Transactions](#spending-keys-and-transactions). |
| `lattice pins list/add/remove` | The Volumes the node keeps for its operator. |
| `lattice restart` | Restart the node in place; waits until it answers again. |
| `lattice wipe` | Delete chain storage, keep identity and configuration; a running node restarts empty. |
| `lattice tokens list/create/revoke` | Remote operator tokens. |
| `lattice logs [--miner] [--tail N]` | The node's recent log lines (`--miner`: the local mining loop's, read from `log/mine.log` under `--root`). |

A running node applies hosted chains and child-chain peers at once;
it writes every other key and lists it as waiting for a restart until
`lattice restart` (refused while `lattice.json` would not start the node). A
change the node would not start from (a peer that does not parse, a port in
use) is refused before it is kept. A change to a stopped node is written to `lattice.json`
directly, checked first, under the spawn lock. A running node refuses a
change when `lattice.json` was edited by hand since it last wrote it: stop it
to edit the file by hand, or `lattice restart` to load the edit. A file that
does not check stops the node at start with the reason.

Remote control, from an operator's machine:

```bash
# Beside the node, once: a listener on the private network and an admin token.
lattice config set operatorListen=10.0.0.5:8090 operatorTokens=operator-tokens.json --root /var/lib/lattice
lattice restart --root /var/lib/lattice
lattice tokens create ops --role admin --out ops.token --root /var/lib/lattice

# Anywhere on that network:
lattice status --node http://10.0.0.5:8090 --token-file ops.token
lattice child create Nexus/Alpha --block-time 10000 --reward 1000 --node http://10.0.0.5:8090 --token-file ops.token
lattice config set minRelayFee=5 --node http://10.0.0.5:8090 --token-file ops.token
```

Tokens have a role, `admin` (every route) or `read` (every `GET`), or
`--route "METHOD /path"` repeated. The secret is printed (or written with
`--out`, mode `0600`) once; the node keeps its SHA-256. `tokens revoke` takes
effect from the next request. Keep the listener on a private network or
behind a TLS proxy: it is plain HTTP.

A remote client may not set `operatorTokens`, which names a file on the
node's machine.

## Topology

```json
{
  "listen": 4001,
  "rpc": 8080,
  "webSocket": 4002,
  "peers": ["<public-key>@node.example:4001"],
  "externalAddress": "192.0.2.10",
  "publicRead": 8081,
  "publicReadMaxRate": 200,
  "publicReadURL": "https://reads.example.org",
  "publicSubmit": false,
  "operatorListen": "10.0.0.5:8090",
  "operatorTokens": "operator-tokens.json",
  "hostedChains": [
    "Nexus/Alpha",
    "Nexus/Alpha/Beta"
  ]
}
```

This is intentionally one schema:

- `listen`, `rpc`, public-read policy, and identity apply once to the
  process;
- `peers` is a list per chain, keyed by absolute path; an array is Nexus's
  list (see "Configured peers" in `operations.md`);
- `hostedChains` lists child paths parent before child;
- ports must be nonzero and unique, except that `webSocket` may be 0, which
  turns the browser listener off (see "Network surfaces" in `operations.md`);
- rates must be finite and nonnegative;
- `blockBodies`, when set, is `all` or `none` and is passed as
  `--block-bodies` (see "What a node keeps" in `operations.md`);
- `state`, when set, is `all`, `recent` or `none` (`tip` means `recent`) and is
  passed as `--state` (same section);
- `stateWindow`, when set, is at least 1 block and is passed as
  `--state-window N`; `stateWindows` maps a chain path to blocks over it and
  is passed as `--state-window path=N`. Absent = 64;
- `finalityWindow`, when set, is a number of blocks and is passed as
  `--finality-window N` for every hosted chain; absent or 0 is off (see
  [Node-local finality](operations.md#node-local-finality));
- `finalityWindows`, when set, maps a chain path to blocks
  (`{"Nexus/Alpha": 500}`) over that default and is passed as
  `--finality-window path=N`; 0 turns it off for that chain;
- `announceLifetime`, when set, is 1 to 86400 and is passed as
  `--announce-lifetime` (see
  "Discovery and peer health" in `operations.md`);
- `publicReadURL`, when set, is an absolute `https://` (or `http://`) URL with
  a host and no credentials, query or fragment; it is passed as
  `--public-read-url` and declared for every hosted level (see
  [Listing a chain on an explorer](operations.md#listing-a-chain-on-an-explorer));
- `publicReadFetches`, when set, is nonnegative and is passed as
  `--public-read-fetches`: how many Volumes the public listener reads from
  peers at once for readers when the node does not hold them (see
  [`GET /volumes/:cid`](rpc-api.md#read-routes)); `0` serves only what the
  node holds;
- `publicSubmit`, when true, passes `--public-submit` and requires
  `publicRead`: the public listener also accepts `POST /transactions` (see
  [Running a public submit endpoint](operations.md#running-a-public-submit-endpoint));
  absent or false is off;
- `operatorListen` and `operatorTokens` go together: the remote operator
  listener's `host:port`, on a port no other listener uses, and its token
  file, a relative path being under the root (see
  [Remote operator listener](rpc-api.md#remote-operator-listener)); absent is
  off; `operatorAllowedOrigins` lists the browser origins it answers;
- it holds no mining settings: the miner is a separate process with its own
  file ([Mining](#mining)). A `mine` object left from an earlier release is
  ignored by the node (with a warning at start) and dropped the next time the
  node writes the file, or by `lattice config unset mine`; a change adding
  one is refused.

## Lifecycle

| Command | Effect |
|---|---|
| `lattice init` | Create `lattice.json` and the process identity, refusing to overwrite a topology. |
| `lattice up` | Start `lattice-node --root <root>` in the background, its output to `log/lattice-node.log`. A running node is left as it is. |
| `lattice up --foreground` | Supervise the node for container or init-system use. |
| `lattice status` | Read every hosted level from the node. |
| `lattice down` | Stop the node process under the spawn lock. |
| `lattice restart` | Restart the running node in place (same pid, same arguments). |
| `lattice wipe` | Remove the tree storage; preserve identity, specs, tokens, and topology. A running node does it on a restart. |
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
Storage also has its own writer lock; a stopped-node `wipe` refuses if any
node still owns it, and `lattice` takes a held lock to mean the node runs.

`POST /restart` makes the node replace itself with its own binary and
arguments (`execv`) after an orderly stop, so it needs no supervisor: the pid,
the pidfile and any supervisor that watches it stay as they are.

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

A spec names each WASM policy module by CID in `wasmPolicies`. Give the file
for every module it names:

```bash
lattice child create Nexus/Alpha \
  --root /var/lib/lattice \
  --spec alpha-spec.json \
  --policy-module transfer-rules.wasm \
  --policy-module action-rules.wasm
```

Each file is matched to the spec by its CID and checked against the policy
ABI; creation is refused if a file is one the spec does not name, or a named
module has no file. The modules are kept beside the spec, and the node stores
them at start, so it can store and serve the genesis it mines.

A spec with a premine needs the account the genesis pays it to:

```bash
lattice child create Nexus/Alpha \
  --root /var/lib/lattice \
  --spec alpha-spec.json \
  --premine-to <address>
```

`premine` counts blocks of the reward schedule; the genesis pays their rewards
to that account in one unsigned credit, as Nexus's genesis pays its own, and
genesis validation bounds the credit by the premine. Creation is refused for a
premine with no account, an account that is not an address, or a genesis one of
the spec's transaction policies refuses. The account is kept beside the spec
and passed to the node as `--premine-to <path>=<address>`, which the node checks
the same way at start.

A chain can also start with state its creator writes, such as names the
creator holds from the first block, as signed transactions the genesis carries
after its premine:

```bash
lattice child create Nexus/Alpha \
  --root /var/lib/lattice \
  --spec alpha-spec.json \
  --genesis-transactions genesis.json
```

The file is a JSON array of what `POST /transactions` takes. Genesis validation
does not check signatures, so creation does: each transaction must be signed by
exactly its signers, be for this chain, carry no coin, deposit, receipt or
withdrawal actions (a genesis pays only its premine), and pass the spec's
transaction policies; with the premine they must fit one block. The file is
kept beside the spec and passed to the node as
`--genesis-transactions <path>=<file>`, which the node checks the same way at
start. A signer's later transactions continue from the nonces its genesis
transactions used.

Creation writes one immutable spec and adds the path to `hostedChains`. The
node builds the genesis candidate from that spec when the parent has an
executed state it can commit, and ordinary merged mining secures it. There is
no child-deploy command or parent authorization transaction.

For a nested child, create the parent first. Its genesis is not eligible until
the parent has executed a block. Give a chain positive rewards before relying
on it as a parent; a reward-free, transaction-free chain never changes state.

To host a child chain that already exists, add its path:

```bash
lattice child host Nexus/Alpha --root /var/lib/lattice
```

A running node starts it at once and syncs it from its peers; a stopped one
hosts it from its next start. `child create` on a running node sends the spec
(with its premine recipient, genesis transactions and modules) inline in
[`POST /hosted-chains`](rpc-api.md#post-hosted-chains), and the node keeps
them under `specs/`; a second create of the same path is refused. Remotely,
`--spec`, `--genesis-transactions` and `--policy-module` are files on the
machine running `lattice`.

To stop hosting one:

```bash
lattice child unhost Nexus/Alpha --root /var/lib/lattice
```

It refuses while a chain below it is hosted, and removes the chain's
recipient, peers and minimum work with it. What it stored stays; hosting it
again resumes it.

### Committing a child block on its parent

A hosted child's block can be carried by the parent's miners that do not
host it. `lattice child commit` builds the child's next block `C` on the
state `P` the parent's next block enters, commits it on the parent as
`child/X` = `C@P` (Lattice spec §6.3), and pushes `C` until a carrier weighs
it ([push-only derived grinds](design/proof-derived-work.md#push-only-derived-grinds)):

```bash
lattice child commit Nexus/Alpha \
  --root /var/lib/lattice \
  --key ./wallet.json \
  --fee 1
```

`--key` signs and pays the commit on the parent and is paid `C`'s block
reward. `--fee` defaults to the parent's `minRelayFee`. Every 3 seconds the
loop pushes `C` ([`POST /child-blocks`](rpc-api.md#post-child-blocks)) and
stops on `tree`. On `pending` or `awaiting` a carrier commits `C`, and it
waits. On `dropped` it reads the parent's commitment
([`GET /child-blocks/commitment`](rpc-api.md#get-child-blockscommitment)): on
`C`'s `P` it sends the commit again until the parent's pool takes it; on
another `P` (a new tip, or a reorg past the carrier) it builds there
([`POST /child-blocks/build`](rpc-api.md#post-child-blocksbuild)) and commits
with the build's `previous` as the `oldValue`. It builds at most once per
`P` and never commits a carried `C` again. Errors are printed and the loop
goes on.

The three flows:

```bash
# A new chain: its genesis is the first C.
lattice child create Nexus/Alpha --root /var/lib/lattice --spec alpha-spec.json
lattice child commit Nexus/Alpha --root /var/lib/lattice --key ./wallet.json

# An existing chain: C extends its executed tip.
lattice child host Nexus/Alpha --root /var/lib/lattice
lattice child commit Nexus/Alpha --root /var/lib/lattice --key ./wallet.json

# A pending child transaction: the next C carries the pool.
lattice tx send --root /var/lib/lattice --chain Nexus/Alpha \
  --key ./wallet.json --to <address> --amount 25 --fee 1
lattice child commit Nexus/Alpha --root /var/lib/lattice --key ./wallet.json
```

The author's loop can run on another machine than the node: give the node's
[remote operator listener](rpc-api.md#remote-operator-listener) and a file
holding a token for it instead of `--root`:

```bash
lattice child commit Nexus/Alpha --node http://10.0.0.5:8090 \
  --token-file ./operator-token --key ./wallet.json
```

The token's routes must include `GET /health`, `GET /api/fees`,
`GET /api/state/account/{addr}`, `GET /api/mempool`,
`GET /api/transaction/{cid}`, `POST /transactions`,
`GET /child-blocks/commitment`, `POST /child-blocks/build` and
`POST /child-blocks`.

A node that hosts `X` pools and relays `child/X` commitments but leaves every
one out of its own templates, whether or not they carry its own candidate
for `X`.

## Mining

| Command | Effect |
|---|---|
| `lattice mine start` | Start the mining loop in the background (`run/mine.pid`, output in `log/mine.log`). |
| `lattice mine status` | Whether it runs, the node it mines through, and its recipients. |
| `lattice mine stop` | Finish or bound the active round, then stop. |

Mining is a separate process, not part of the node: the node serves
templates and accepts work, and knows nothing of who mines through it. The
loop is a client of one node, by default the one under `--root` (its loopback
API and cookie), or with `--node <url> --token-file <file>` any node's
[remote operator listener](rpc-api.md#remote-operator-listener). A token
for mining needs only three routes:

```bash
# Beside the node:
lattice tokens create miner --out miner.token --root /var/lib/lattice \
  --route "POST /mining/templates" --route "POST /mining/work" --route "GET /status"

# On the mining machine, with its own root for settings, pidfile and log:
lattice mine start --root /var/lib/lattice-miner \
  --node http://10.0.0.5:8090 --token-file miner.token
```

Its settings are its own file, `<root>/miner.json` (or `--config <file>`),
never the node's `lattice.json`:

```json
{
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
```

The loop reads it again before each round, so a changed recipient applies to
the next round with no restart; a file that no longer checks is logged and
the last good settings kept. An unknown key is refused.

While there is no `miner.json`, the miner reads the `mine` object an older
`lattice.json` in the same root still holds (its `enabled` ignored) and copies
it to `miner.json` once, saying so (never over a `miner.json` already there),
so a host upgraded with no edits keeps mining. The node drops that object the
next time it writes `lattice.json`; the copy is what the miner reads from then
on. So after upgrading, start the miner once (`lattice mine start`, or its
unit) before changing the node's configuration: a change made first drops
`mine` before anything copied it, and the miner then finds no settings.

A host upgraded from a build where the node itself started the miner (the
unreleased `main` between #63 and this change) mines no more on its own:
start the miner after upgrading with `lattice mine start --root <root>`, or
install the `lattice-mine.service` unit `emit-systemd` prints.

`worker` is `cpu` for the bundled worker or an executable path implementing
the worker contract. `recipients` sends each chain's reward and fees to an
address; each template request carries them, and an omitted path burns that
payout. `minWork` is a local search filter, not a committed consensus target.
`minBlockIntervalSeconds` is a floor on template spacing and releases itself
when rounds run longer.

The mining loop starts once the node answers a template request
(`templateTimeoutSeconds`) and places a deadline around each coordinator
process group: 600 seconds until a round completes, then the longest
completed round (counted up to 600 seconds) times `roundDeadlineMultiplier`,
never less than 600 seconds.
It only catches a hung coordinator; work itself never expires on a clock. A
timeout is logged loudly and the next round retries.

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
exchange actions. `tx commit-child` signs one child commitment on `--chain`,
which `child commit` sends for its author:

```bash
lattice tx commit-child \
  --root /var/lib/lattice \
  --chain Nexus \
  --key ./wallet.json \
  --directory Alpha \
  --block <child block CID> \
  --parent-state <parent state CID> \
  --previous <current C@P>
```

`--directory` is one edge label under `--chain`. `--block` and
`--parent-state` must be standard CIDs; only a block entering that state
carries it. `--previous` is the directory's current commitment value, omitted
for the first. The node pools it only while the chain's executed tip leaves
that parent state, and a pooled one leaves the pool when the tip moves on. All submissions use the one RPC listener and carry their
absolute chain path. The CLI rejects a path this host does not serve; the node
also returns 404 for an unhosted path.

## systemd

Generate foreground units from the configured topology (and a
`lattice-mine.service` running `lattice mine run --root <root>` when the root
holds miner settings):

```bash
lattice emit-systemd --root /var/lib/lattice \
  > /etc/systemd/system/lattice.generated.units
```

For a node started with flags rather than `--root`, the checked-in examples
are [deploy/lattice-node.service](../deploy/lattice-node.service)
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
    volume-bundles.db
    storage.lock
  operator-tokens.json   (operatorTokens, when set)
  miner.json             (the miner's own settings, when it mines here)
  run/
  log/lattice-node.log
  log/mine.log           (the mining loop's, when it mines here)
```

There is no per-chain process, port, key, or child `state.db`. The path in
`specs/` identifies a level; runtime facts for every level share the one tree
journal.
