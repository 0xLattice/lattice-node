# HTTP API: operator routes

The routes for whoever runs the node: its status, configuration, hosted
chains, child blocks, pinned content, serving credit, logs and lifecycle.
The `lattice` CLI drives most of them, and is the easier way to do these
tasks by hand ([Operator CLI](operator-cli.md)). This page is the reference
for a tool that calls them directly.

Every route here is on the operator API (loopback, with the node's cookie)
and on the [remote operator listener](#remote-operator-listener) (with a
token). None is on the public read listener. Credentials, integer encoding
and the error format are in [HTTP API](rpc-api.md). In the tables below, a
field marked optional is omitted when it has no value.

## Remote operator listener

A client on another machine (an operator's laptop, a hosting seller, a
dashboard, a miner) reaches the operator routes through a second listener,
off by default. To set one up with the CLI, see
[Remote control](operator-cli.md#remote-control).

### Turning it on

In `lattice.json`:

```json
{"operatorListen": "10.0.0.5:8090", "operatorTokens": "operator-tokens.json",
 "operatorAllowedOrigins": ["https://dash.example"]}
```

On a node started with flags these are `--operator-listen`,
`--operator-tokens` and `--operator-allowed-origin`. The listener's port
must differ from `listen`, `rpc`, `publicRead` and `webSocket`.

The listener is plain HTTP. Put it on a private network (a VPN, a private
subnet) or behind a proxy that terminates TLS, and never on a public address
without one. The operator API itself (`--rpc-bind`) stays loopback-only.

### How it differs from the operator API

It serves the operator API's routes with the same handlers, but:

- **Every request carries a token**, `/health` included:
  `Authorization: Bearer <token>` for a token in the file. No known token is
  `401`. The cookie is not a token here.
- **Each token is limited** to a role or a route list
  ([What a token may use](#what-a-token-may-use)). Anything else is `403`.
- **No field may name a file on the node's disk.** A fragment that changes
  `operatorTokens` is `400`; that key is set beside the node.
- **The loopback `Host` check does not apply.** A bearer token is not a
  credential a browser sends on its own.
- **Browsers** are refused as on the operator API: a request with an
  `Origin` header is `403` unless `operatorAllowedOrigins` lists that exact
  origin. A listed origin still needs a token. It gets CORS preflight
  answers (methods `GET, HEAD, POST, PUT, DELETE`; headers
  `Authorization, Content-Type, If-Match, If-None-Match`),
  `Access-Control-Allow-Origin`, and `ETag` exposed.

### What a token may use

| Token has | May use |
|---|---|
| `role: admin` | Every route. |
| `role: read` | Every `GET` and `HEAD` except `/tokens`. |
| `routes: [...]` | Only the routes it names, and never `/tokens`. |

`GET /whoami` is open to every token. An unknown path is `403` for every
token but `admin`.

A route is the method and the path as the node registers it, with a
parameter in braces: `GET /api/state/account/{addr}`, `GET /fetch/{cid}`.

- A listed route may name one path instead of the parameter:
  `PUT /config/fragments/hostmarket` reaches that fragment and no other,
  while `PUT /config/fragments/{name}` reaches every one.
- A fragment is the unit of scope. A token that may write a fragment may set
  any key in it.
- `?chainPath=` is not part of a route. A token reaches every chain the node
  hosts.

A token allowed `PUT /config/fragments/{name}`, `POST /restart`,
`POST /stop` or `POST /wipe` controls the node as fully as `admin` does,
short of managing tokens. Give those routes only where `admin` would do.

### The token file

The file `operatorTokens` names is a JSON array. It holds each token's
SHA-256, never the token. Each entry carries `role` or `routes`, not both:

```json
[{"name": "ops", "sha256": "<hex SHA-256 of the token>", "role": "admin"},
 {"name": "seller", "sha256": "<hex>", "routes": ["GET /config", "PUT /config/fragments/{name}"]}]
```

Tokens are made and revoked through the API ([Tokens](#tokens)). The file is
created by the first token made, and a change applies from the next request.

## Status

### `GET /status`

A chain's status as [`GET /health`](api-reads-and-transactions.md#get-health)
gives it, with the detail an operator and a miner need.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `chainPath` | query | Optional. A hosted chain; Nexus when omitted. |

**Response**

Every field of `GET /health`, read live, and:

| Field | Type | Meaning |
|---|---|---|
| `templateDigest` | string, optional | The current template digest, which changes when any hosted chain's template inputs change. A miner compares it with its work's ([Mining routes](api-mining.md)). Omitted before Nexus has an executed tip, and in a child chain's answer: the digest is Nexus's. |
| `version` | string | The node's build version, as `lattice-node --version` prints it. |
| `startedAt` | number | When the node process started, in unix seconds. A restart changes it. |
| `sync` | object | What the chain's sync holds, as its last step left it. |

`sync` holds counts and a few markers:

| Field | Type | Meaning |
|---|---|---|
| `pendingHeaders` | number | Headers received and not yet weighed, most waiting for their parent header. |
| `headersAwaitingProof` | number | Child-chain headers waiting for a proof that weighs them. |
| `proofChecksRunning` | number | Peers' proofs in a check, one job per page of headers. |
| `bodyWindow` | number | The blocks the node asks to execute next: every fork child on the acted-on path and the best chain's look-ahead. |
| `bodiesRequested` | number | Bodies asked of peers that have not arrived. |
| `bodiesUnavailable` | number | Window blocks whose last fetch failed: no peer served the body, or this node's byte budget or store declined it. |
| `bodiesParked` | number | Window blocks whose fetch failed at least once and that are still in the window. |
| `awaitingParentFacts` | number | Blocks whose connect needs a fact of the parent chain this node has not executed yet. |
| `jobsQueued` | number | This chain's jobs waiting for a worker. |
| `tipAdvancedAt` | number, optional | When the acted-on tip last moved, in unix seconds, as this process saw it. The first tip after a start counts as a move. |
| `secondsSinceTipAdvanced` | number, optional | Seconds since `tipAdvancedAt` when the answer was made. |
| `blockedOn` | string, optional | What the tip waits on: `atTip`, `headers`, `proofs`, `parent` (a child chain waiting on its parent chain), `bodies`, `bodiesUnavailable`, `execution`, or `stalled`. New values may be added. |
| `headersSynced` | boolean, optional | Whether the chain has weighed a peer's whole log since the node started. This opens its child chains' sync. |
| `synced` | boolean, optional | Whether the chain has caught up. A caught-up chain admits transactions from peers. |

Reading it:

- A chain whose `bestHeaderHeight` is above its `height` and whose tip has
  not moved for long is stalled. One at its best header is only waiting for
  the network's next block.
- `stalled` in `blockedOn` means the chain is behind its best header with
  nothing under way for the next block. It should never last.

**Errors**: `404` for a chain this node does not host.

### `GET /whoami`

Names the caller's own credential, so a client can offer only what it may
do. Every credential the listener accepts may call it.

**Response**

| Field | Type | Meaning |
|---|---|---|
| `name` | string | The token's name, or `cookie` for the operator API's cookie. |
| `role` | string, optional | `admin` or `read`. The cookie answers `admin`. Omitted for a route-list token. |
| `routes` | array of strings, optional | The token's routes. Omitted for a token with a role. |

```json
{"name": "seller", "routes": ["GET /hosted-chains"]}
```

It never includes a secret or its hash.

**Errors**: `401` without a credential.

### `GET /metrics`

Prometheus text exposition. What it holds and what to alert on is in
[Running in production](operations.md#metrics).

### `GET /core/snapshot`

Nexus's last published snapshot: the best header chain and the tip the node
acts on. It is an internal diagnostic.

**Response**

| Field | Type | Meaning |
|---|---|---|
| `bestHeaderTip` | string | The best header chain's tip. |
| `bestHeaderHeight` | decimal string | Its height. |
| `actOnTip` | string | The tip the node acts on. |
| `actOnHeight` | decimal string | Its height. |

**Errors**: `503` before the first snapshot is published.

## Configuration

These routes read and change the configuration of a node started with
`--root`, which is what `lattice up` runs. A node started with flags has no
configuration of its own, and the routes answer `409` there. The keys are
listed in [Configuration](configuration.md); the CLI over these routes is
`lattice config` and `lattice apply`.

### Layers

The configuration is read from layers, as systemd drop-ins and `sudoers.d`
are: `<root>/lattice.json`, then each `<root>/config.d/<name>.json` in name
order (byte order). Number fragments to order them: `10-deploy`,
`50-hostmarket`.

- Name order is the only precedence. No layer outranks another otherwise.
- Each writer owns one fragment: a deploy script `deploy`, a hosting seller
  its own, people and `lattice config set` the fragment `operator`.
- The node never writes `lattice.json`.
- A file in `config.d` whose name is not a fragment's (`README`,
  `x.json.bak`, `Deploy.json`) is not read, and is reported.

Every layer has `lattice.json`'s keys, and they merge:

| Key | Merged value |
|---|---|
| A single value (a port, a rate, a mode) | The later layer's. |
| `hostedChains`, each chain's `peers`, `rpcAllowedOrigins`, `operatorAllowedOrigins` | The union of every layer's. |
| `stateWindows`, `finalityWindows` | Per chain path, the later layer's. |

A key set to `null` is as if the layer did not set it. It does not unset an
earlier layer's value; to do that, remove the key from the layer that sets
it.

### The hosted tree

A `hostedChains` entry is a chain's path. A child chain runs only under its
parent: its blocks ride in the parent's, and validating it reads the
parent's state. So the node hosts the smallest tree rooted at Nexus that
holds every listed chain: the listed chains and their ancestors.

- An ancestor no layer lists is hosted *implied* by the listed chains under
  it, as apt installs a package's dependencies. A chain stops only once no
  layer lists it or any chain under it.
- A path created on this node (its spec is under `<root>/specs/`, written by
  [`POST /chains`](#post-chains)) is mined from that spec. Any other is
  synced from its peers.
- A chain that does not start is not hosted, and its status says why.
- A chain's settings (its `peers`, `stateWindows` and `finalityWindows`
  entries) apply wherever it is in the tree, listed or implied.

### What is refused and what is inert

- **Inert.** A setting for a chain not in the tree, or a state window while
  `state` is not `recent`, is left out and listed in `status.inert`. It is
  not an error.
- **Refused.** Anything else wrong (a file that is not one JSON object, an
  unknown key, a merged result that does not check) makes the whole
  configuration invalid. The node does not start from it (exit 78), and a
  change that would produce it is `400`.

### When changes apply

The node reads the layers at its start, again on `SIGHUP` (systemd's
`ExecReload`), and after each change of a fragment through this API. A
re-read is checked as a change is, and one that does not check is not used.

- Hosted chains and child chains' peers apply at once.
- Every other key (ports, Nexus's peers, retention, listeners, serving
  limits, relay fee and so on) applies at the next start. Until
  [`POST /restart`](#post-restart) it is listed as `pendingRestart`.

### `GET /config`

The merged configuration, the layers it came from, and how the running node
compares with it.

**Response**

```json
{"spec": {"...": "the merged configuration, as lattice.json holds one"},
 "fragments": ["lattice", "deploy", "hostmarket", "operator"],
 "status": {
   "chains": [{"path": "Nexus/Alpha", "from": ["deploy"], "actual": "hosted"},
              {"path": "Nexus/Beta", "from": [], "impliedBy": ["Nexus/Beta/Gamma"], "actual": "hosted"},
              {"path": "Nexus/Beta/Gamma", "from": ["operator"], "actual": "notHosted",
               "error": "did not start: ..."}],
   "pendingRestart": ["stateWindow"],
   "errors": ["operatorListen: 10.0.0.5:8090 did not open: ..."],
   "inert": ["peers for Nexus/Beta: not hosted"]}}
```

| Field | Type | Meaning |
|---|---|---|
| `spec` | object | The merged configuration, with `lattice.json`'s keys ([Configuration](configuration.md)). `spec.hostedChains` lists the chains the tree holds, parent first. |
| `fragments` | array of strings | The layers merged, in order. `lattice` is `lattice.json`. |
| `status.chains` | array | Each chain of the tree, and any chain still running that the tree no longer holds. |
| `status.chains[].path` | string | The chain's path. |
| `status.chains[].from` | array of strings | The layers that list it. Empty when it is implied. |
| `status.chains[].impliedBy` | array of strings, optional | For an implied chain: the listed chains under it that keep it hosted. |
| `status.chains[].actual` | string | `hosted` or `notHosted`. |
| `status.chains[].error` | string, optional | Why it is not hosted as configured. |
| `status.pendingRestart` | array of strings | The keys whose value differs from what the node started with and applies only at its next start. |
| `status.errors` | array of strings | What else does not match: a re-read (`SIGHUP`) the node could not use, in which case it keeps the configuration it had; an operator listener that could not open, in which case the node runs on without it, reachable on loopback. |
| `status.inert` | array of strings | What the layers set that does not apply, and why. |

**Errors**: `409` on a node started with flags.

### `GET /config/fragments/{name}`

One layer's file as it is.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `name` | path | The fragment's name. `lattice` is `lattice.json`. |

**Response**: the file's bytes as `application/json`, with its version in
`ETag`: the SHA-256 of its bytes.

**Errors**: `404` when there is no such fragment; `409` on a node started
with flags.

### `PUT /config/fragments/{name}`

Replaces a fragment with the request body.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `name` | path | The fragment's name: lowercase letters, digits, `.`, `_` and `-`, starting with a letter or digit (`deploy`, `50-hostmarket`). `lattice.json` is not written here. |
| `If-Match` | header | Optional. The `ETag` a `GET` answered, or `*` for any version. The fragment is written only while it is still that version. |
| `If-None-Match` | header | Optional, `*`. The fragment is written only while there is no such fragment yet. |
| body | | One JSON object with `lattice.json`'s keys, sent as `Content-Type: application/json`. |

A client that edits a fragment others write too sends one of the two
headers: `If-Match` for the version it read, `If-None-Match: *` when it
read none.

**Response**: as [`GET /config`](#get-config).

A chain that does not start is reported in `status`, not refused. A chain
the new configuration leaves out is treated as for
[`DELETE`](#delete-configfragmentsname).

**Errors**

| Status | When |
|---|---|
| `400` | The name is not a fragment's name, or the body is not one JSON object. |
| `400` | The configuration the change makes does not check, including one the node would not start from (its start-time checks are run on it). Nothing is written. |
| `400` | On the remote listener, the fragment changes `operatorTokens`, a file on the node's disk. |
| `412` | The precondition header does not hold. Nothing is written; read the fragment again and redo the change. |
| `409` | The node was started with flags. |

### `DELETE /config/fragments/{name}`

Removes a fragment.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `name` | path | The fragment's name. |
| `If-Match` | header | Optional, as for `PUT`. |

**Response**: as [`GET /config`](#get-config).

A chain no layer lists any more stops, unless a chain listed under it keeps
it, implied. The node lets go of the data of a chain the configuration does
not host; hosting it again syncs it again from its peers
([Storage](storage.md#chains-the-node-stops-hosting)).

**Errors**: `400` when what is left does not check; `404` when there is no
such fragment; `412` when `If-Match` is not its version; `409` on a node
started with flags.

## Chains

### `POST /chains`

Creates a child chain, once. The body is what fixes its genesis. It is
checked as `lattice child create` checks it
([Child chains](child-chains.md#create-a-chain)) and kept under
`<root>/specs/`.

**Request**

```json
{"path": "Nexus/Beta",
 "spec": {"...": "a ChainSpec, as in a spec file"},
 "premineTo": "<address, when the spec pays a premine>",
 "genesisTransactions": [{"transaction": {"...": "as POST /transactions takes"}}],
 "policyModules": ["<base64 WASM module the spec names>"]}
```

| Field | Type | Meaning |
|---|---|---|
| `path` | string | The chain's path. |
| `spec` | object, optional | The chain's `ChainSpec`, as in a spec file. |
| `premineTo` | string, optional | The address the genesis pays the spec's premine to. |
| `genesisTransactions` | array, optional | Signed transactions the genesis carries, each what [`POST /transactions`](api-reads-and-transactions.md#post-transactions) takes. |
| `policyModules` | array of strings, optional | The WASM modules the spec names, base64. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `path` | string | The chain's path. |
| `created` | boolean | `false` when the chain was already created with exactly this. |

Creating does not host the chain. List its path in a fragment's
`hostedChains` to mine its genesis and then its blocks.

A created spec stays even if the chain is never hosted or never starts. To
create the path with something else, remove its files under `<root>/specs/`
by hand while the node is stopped.

**Errors**

| Status | When |
|---|---|
| `400` | The body does not check. |
| `409` | The chain was created with something else. |
| `409` | The node already follows the chain without a spec: it is in the hosted tree (listed or implied, running or not), or the node's storage holds the chain's blocks. A spec would mine a rival genesis. |
| `409` | The node was started with flags. |

### `GET /hosted-chains`

The child chains running, and those the configuration hosts. It summarises
`status.chains` of [`GET /config`](#get-config).

**Response**

```json
{"chains": ["Nexus/Alpha"], "configured": ["Nexus/Alpha", "Nexus/Beta"]}
```

| Field | Type | Meaning |
|---|---|---|
| `chains` | array of strings | The child chains running, parent first. |
| `configured` | array of strings, optional | The chains the configuration hosts: the tree, listed or implied (`spec.hostedChains` of `GET /config`). Omitted on a node started with flags. |

How peers learn a change: a peer that connects afterwards is told the new
list in the hello. A peer already connected learns a newly hosted chain from
its provider record, and a peer that asks for a stopped one is answered as
by any node that does not host it.

## Child blocks

A hosted child chain's block can be carried by miners of its parent that do
not host it. A parent transaction `child/X` = `C@P` asks them to commit `C`
at `children[X]` (Lattice spec §6.3), and the block's author pushes `C`
until a carrier weighs it
([push-only derived grinds](design/proof-derived-work.md#push-only-derived-grinds)).

`lattice child commit` drives these three routes
([Child chains](child-chains.md#committing-a-child-block-yourself)).

In the bodies below, `block`, `children` and `spec` are the base64 bytes of
the block node, its child index and a child genesis's spec. `proofs` are
the bytes of its `ChildBlockProof`s.

### `POST /child-blocks`

Pushes a child block to this node, as a peer would send it.

**Request**

```json
{
  "chainPath": ["Nexus", "Alpha"],
  "block": "<base64 bytes>",
  "children": "<base64 bytes>",
  "spec": "<base64 bytes>",
  "proofs": ["<base64 bytes>"]
}
```

| Field | Type | Meaning |
|---|---|---|
| `chainPath` | array of strings | The child chain. |
| `block` | base64 string | The block node's bytes. |
| `children` | base64 string | Its child index's bytes. |
| `spec` | base64 string, optional | The chain's spec. Given only for a genesis. |
| `proofs` | array of base64 strings, optional | The block's proofs, one `ChildBlockProof` each. |

The bytes must be canonical, as on the gossip wire. The block is taken as
the same header synced from no peer would be, and stored as a received
header is. Nothing records the submit.

**`proofs`.** Each element is the base64 of one `ChildBlockProof`'s
canonical bytes (Lattice's `ChildBlockProof.serialize()`), exactly what one
element of a synced header entry's `proofs` carries on the sync wire: a
proof that the block sits at `children[d0]…[dn]` under a mined root whose
hash meets the block's target, the terminal carrier's `prevState` being the
block's `parentState`. A carrier need not be a valid or connected parent
block.

- With proofs, the block waits for their check as a synced header does
  (`awaiting`), then is weighed (`pending`, `tree`) and executes once the
  parent has executed a block leaving its `parentState`. Peers sync it with
  its proofs.
- Without them, it is held only when a weighed parent block commits it.

**Response**, read after the submit's step:

```json
{"blockCID": "<cid>", "status": "tree"}
```

| Field | Type | Meaning |
|---|---|---|
| `blockCID` | string | The submitted block's CID. |
| `status` | string | Where the block stands; see below. |

| `status` | Meaning |
|---|---|
| `tree` | Weighed in the child's block tree: done. |
| `pending` | Proved, waiting for its previous block to be weighed. |
| `awaiting` | Taken, waiting for a proof that weighs. |
| `dropped` | Not taken: no connected parent block commits it yet, or the chain let it go. |

Only `tree` is final. The author submits again on any other status, and
after a restart, an unhost or an eviction.

**Errors**

| Status | Reason | When |
|---|---|---|
| `404` | `unknownChain` | The chain is not hosted. Checked first. |
| `400` | `invalidChainPath` | The path is a root path. |
| `400` | `malformedBlock` | Bytes, a proof's included, do not parse or are not canonical. |
| `400` | `invalidChildProof` | A proof does not verify work for the block (as a peer that sent it would be disconnected; nothing is taken), or the proofs are past the bounds a synced header's are taken within (8 per block, 64 KiB each, by default). |

### `POST /child-blocks/build`

Builds the child's next block `C` as this node's next template carries it
(its executed tip extended, or its genesis), and stores and retains it with
its closure as a mined block is.

**Request**

```json
{"chainPath": ["Nexus", "Alpha"], "recipient": "<address>"}
```

| Field | Type | Meaning |
|---|---|---|
| `chainPath` | array of strings | The child chain. |
| `recipient` | string, optional | The address the block reward is paid to. Omitted, the reward is burned. |

**Response**

```json
{
  "blockCID": "<cid>",
  "parentState": "<cid>",
  "previous": "<cid>@<cid>",
  "submit": {"chainPath": ["Nexus", "Alpha"], "block": "<base64 bytes>", "children": "<base64 bytes>"}
}
```

| Field | Type | Meaning |
|---|---|---|
| `blockCID` | string | The built block's CID. |
| `parentState` | string | The parent state `P` the block was built on. |
| `previous` | string, optional | `child/X` in `P`'s general state: the commitment's `oldValue`. Omitted when unset (the first commitment). It is never guessed. |
| `submit` | object | The [`POST /child-blocks`](#post-child-blocks) body that pushes the block, with `spec` for a genesis. |

**Errors**

| Status | Reason | When |
|---|---|---|
| `400` | `invalidChainPath` | The path is not below this node's chain. |
| `400` | `invalidRecipientPlan` | The recipient is not an address. |
| `404` | `unknownChain` | The chain is not hosted. |
| `400` | `noChildCandidate` | The template carries no block for the chain: its genesis is weighed but not executed, or it has no spec to start from. |
| `404` | `notHeld` | `P`'s state is not readable here. |
| `503` | `executing` | The chain, or one above it, is executing a backlog of blocks first. |

### `GET /child-blocks/commitment`

The parent's current commitment for a child. Read only: nothing is built or
retained.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `chainPath` | query | The child chain, for example `Nexus/Alpha`. |

**Response**

```json
{"parentState": "<cid>", "value": "<cid>@<cid>"}
```

| Field | Type | Meaning |
|---|---|---|
| `parentState` | string | The post-state of the parent's executed tip: the state its next block enters. |
| `value` | string, optional | `child/X` there, read as the build route reads `previous`. Omitted when unset. |

**Errors**: `400` `invalidChainPath`; `404` `unknownChain`; `404` `notHeld`
when the parent has no executed tip or its state is not readable here.

## Pins

A Volume the operator names by its root CID is held, served to peers and
announced as held, until the operator unpins it.

- The node does not look inside a pinned Volume or follow anything it names.
- A pin is kept whatever `blockBodies` says.
- With `--no-announce-pins`, pins are held and served but never announced: a
  holder of many Volumes need not send a record per Volume.

The CLI over these routes is `lattice pins`
([Operator CLI](operator-cli.md#pinned-content)); what pinning costs on disk
is in [Storage](storage.md#pinned-content).

### `GET /pins`

**Response**

| Field | Type | Meaning |
|---|---|---|
| `pins` | array of strings | The root CIDs the operator pinned. |

### `POST /pins`

Pins a Volume.

**Request**

```json
{"cid": "<cid>", "entries": {"<cid>": "<base64 bytes>"}}
```

| Field | Type | Meaning |
|---|---|---|
| `cid` | string | The Volume's root CID. |
| `entries` | object, optional | The Volume's entries, CID to base64 bytes, for a Volume the node does not hold. |

A Volume the node holds needs only `cid`. One it does not hold is stored
only as the operator provides it in `entries`: the root and the entries it
lists, each checked against its CID. The node never reads a pin from peers.

**Response**: the pins, as [`GET /pins`](#get-pins).

**Errors**

| Status | Reason | When |
|---|---|---|
| `400` | `invalidCID` | `cid` is not a CID. |
| `404` | `notHeld` | The node does not hold the Volume and `entries` does not provide it, or the Volume left the store before it was pinned. |
| `400` | `invalidVolume` | `entries` lacks the root, or an entry is not the bytes its CID names. |
| `409` | `conflictingVolume` | The store holds that root with other entries. |

### `DELETE /pins/:cid`

Unpins a Volume. It goes from the store unless something else the node keeps
names it. A CID the operator did not pin changes nothing.

**Request**: `cid` in the path.

**Response**: the pins left, as [`GET /pins`](#get-pins).

**Errors**: `400` `invalidCID`.

### `GET /fetch/:cid`

Reads a Volume from peers without storing it, each entry checked against its
CID. An application validates what it reads, and pins it if it keeps it.

**Request**: `cid` in the path.

**Response**: the shape [`POST /pins`](#post-pins) takes: `cid` and
`entries`.

**Errors**: `400` `invalidCID`; `404` `notServed` when no peer serves it.

## Serving credit

A peer's serving standing is one non-negative byte count. It decides how
freed serving slots are shared among waiting peers when every slot is busy;
while a slot is free, serving is free. How standing rises and falls is in
[Networking](networking.md#serving-standing). These routes read a standing
and let the operator credit one, by hand or through a sponsor such as
lattice-sponsor.

A peer is named by its Ed25519 public key as Ivy and the node print it (the
`storage:` line at start, `PeerEndpoint.publicKey`): exactly 64 lowercase
hex characters, without the `ed01` multikey prefix. Any other spelling is
`400` `invalidPeer`.

### `GET /serving-credit/:peer`

**Request**: the peer's key in the path.

**Response**

```json
{"peer": "<peer key>", "standing": 7168}
```

| Field | Type | Meaning |
|---|---|---|
| `peer` | string | The peer's key. |
| `standing` | number | Its standing, in bytes. |

**Errors**: `400` `invalidPeer`.

### `POST /serving-credit`

Credits bytes to a peer's standing.

**Request**

```json
{"peer": "<peer key>", "bytes": 1048576}
```

| Field | Type | Meaning |
|---|---|---|
| `peer` | string | The peer's key. |
| `bytes` | number | Bytes to credit, at least 1. |

**Response**: the peer's standing, as
[`GET /serving-credit/:peer`](#get-serving-creditpeer).

**Errors**: `400` `invalidPeer` or `invalidBytes`; `503` `notSaved` when the
credit could not be written, in which case it was not applied.

Every standing is kept in `<data-directory>/serving.json`, written before
each credit is applied, on every maintenance pass and at a clean stop. A
crash loses only the changes since the last write, never a credit. The file
must move with the data directory: a node started without it starts with no
standings. Fields in it that the node does not know are ignored.

## Logs and disk

### `GET /logs`

The end of the node's log.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `tail` | query | Optional. The number of lines: 200 by default, at most 10000. |
| `file` | query | Optional. Only `node` is accepted. |

**Response**: `text/plain`, the last `tail` lines.

Each line the node logs goes to its standard error, where its process
manager collects it, and is kept in memory: the last 10000 lines, and at
most 4 MiB. Not here: lines from before the node's last start, and anything
else on standard error, such as a crash report or `LATTICE_SYNC_TRACE=1`
output.

**Errors**: `400` for a `tail` that is not positive; `404` for any other
`file` (a client beside the node keeps its own log).

### `GET /disk`

Bytes per entry in the data directory, and the free bytes on its file
system.

**Response**

```json
{"storage": "/var/lib/lattice/chains/Nexus",
 "stores": [{"name": "state.db", "bytes": 7352320}, {"name": "volumes", "bytes": 1744896}],
 "totalBytes": 15183872, "freeBytes": 112642072576}
```

| Field | Type | Meaning |
|---|---|---|
| `storage` | string | The data directory's path. |
| `stores` | array | One entry per file or directory in it. |
| `stores[].name` | string | The entry's name. |
| `stores[].bytes` | number | Its bytes on disk. |
| `totalBytes` | number | The sum of the entries. |
| `freeBytes` | number, optional | Free bytes on the data directory's file system. |

## Lifecycle

The node never starts itself. A restart is an exit with a status its
process manager restarts on ([Running in production](operations.md#exit-codes)).

### `POST /restart`

Restarts the node.

**Response**: `202`

```json
{"restarting": true}
```

The node then stops as on SIGTERM and exits with status 75 (`EX_TEMPFAIL`).
Its process manager starts it again (systemd `Restart=on-failure`, launchd
`KeepAlive`, `docker run --restart on-failure`), and the new process reads
`lattice.json` afresh. A client waits until `startedAt` in
[`GET /status`](#get-status) changes.

**Errors**: `409` when the configuration as it is on disk would not start
the node (it is read and checked as a start would), or when a stop or
restart is already under way.

### `POST /stop`

Stops the node.

**Response**: `202`

```json
{"stopping": true}
```

The node then stops as on SIGTERM and exits 0, which a process manager
leaves stopped. A client waits until nothing answers.

### `POST /wipe`

Deletes every chain's data and syncs again. Only on a node started with
`--root`.

**Response**: `202`

```json
{"restarting": true, "wiping": true}
```

The wipe runs at the node's next start, before it opens its storage: the
node records the request, exits 75 as for a restart, and the started process
deletes every chain's data (`<root>/chains`).

- Identity, `lattice.json`, specs and tokens stay.
- Nexus syncs again from its peers, and hosted chains from theirs.
- Per-chain wipes are not offered: chains share one store.

**Errors**: `409`, with no wipe recorded, on a node started with flags, when
the configuration on disk would not start the node, or once a stop or
restart is already under way, since that start may not come.

## Tokens

These routes manage the [remote operator listener](#remote-operator-listener)'s
tokens. The cookie (on the operator API) and `admin` tokens (on the remote
listener) reach them. They answer `409` when the node has no token file
(`operatorTokens`). The CLI over them is `lattice tokens`
([Operator CLI](operator-cli.md#remote-operator-tokens)).

### `GET /tokens`

**Response**

```json
{"tokens": [{"name": "ops", "role": "admin"}, {"name": "seller", "routes": ["GET /status"]}]}
```

| Field | Type | Meaning |
|---|---|---|
| `tokens` | array | One entry per token. |
| `tokens[].name` | string | The token's name. |
| `tokens[].role` | string, optional | `admin` or `read`. |
| `tokens[].routes` | array of strings, optional | The routes it may use, for a token without a role. |

### `POST /tokens`

Makes a token.

**Request**

```json
{"name": "dash", "role": "read"}
```

| Field | Type | Meaning |
|---|---|---|
| `name` | string | The token's name: letters, digits, `.`, `_` and `-`. |
| `role` | string, optional | `admin` or `read`. |
| `routes` | array of strings, optional | The routes it may use, each `METHOD /path`. Give `role` or `routes`, not both. |

**Response**

```json
{"name": "dash", "token": "<64 hex>"}
```

| Field | Type | Meaning |
|---|---|---|
| `name` | string | The token's name. |
| `token` | string | The token. It is shown this once. |

The file keeps the token's SHA-256. It is written atomically with mode
`0600`, and created on first use.

**Errors**: `409` for a name in use; `400` for an unknown role, both a role
and routes or neither, or a bad name or route.

### `DELETE /tokens/{name}`

Revokes a token, from the next request.

**Request**: the token's name in the path.

**Response**: the tokens left, as [`GET /tokens`](#get-tokens).

**Errors**: `404` for an unknown name.
