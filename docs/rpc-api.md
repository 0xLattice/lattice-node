# HTTP API

How to reach a Lattice node over HTTP, the conventions every route follows,
and an index of every route. The routes themselves are on three pages:

| Page | For | Routes |
|---|---|---|
| [Reads and transactions](api-reads-and-transactions.md) | Apps, wallets and explorers | Chain, block, account, deposit and Volume reads; submitting a transaction; fees |
| [Mining routes](api-mining.md) | Miners | Templates, the template event stream, submitting work |
| [Operator routes](api-operator.md) | Whoever runs the node | Status, configuration, chains, child blocks, pins, serving credit, logs, lifecycle, tokens |

The API has one unversioned route set. `/v1/...` does not exist.

## Listeners

A node has up to three HTTP listeners.

| Listener | Where it binds | Credential | Serves |
|---|---|---|---|
| Operator API | Loopback only, port `rpc` (8080) | The node's cookie, except on `GET`/`HEAD /health` | Every route |
| Public read listener | All interfaces, port `publicRead`; off by default | None | The read routes, and `POST /transactions` when the operator turns [public submit](api-reads-and-transactions.md#public-submit) on |
| Remote operator listener | `operatorListen`; off by default | A bearer token on every request | Every route, each token limited to a role or a route list |

An app that does not run its own node uses a public read listener. An app
beside a node, and the `lattice` CLI, use the operator API. A client on
another machine that operates the node, such as a miner or a dashboard, uses
the [remote operator listener](api-operator.md#remote-operator-listener).

The keys that open each listener are in
[Configuration](configuration.md#listeners), and what to expose is in
[Networking](networking.md#ports).

### The public read listener

- It needs no credential and answers any browser origin (CORS allows `GET`,
  and `POST` when public submit is on, with the `Content-Type` header).
- It accepts a bounded number of requests per second, all clients together.
  Past that it answers `429`. `/health` is exempt. The limits are in
  [Networking](networking.md#public-reads).
- It never serves `/status`, `/metrics`, mining routes or any other operator
  route.
- CIDs and response sizes are bounded before anything is decoded.

## Authentication

This section covers the operator API. The remote operator listener's tokens
are described with [that listener](api-operator.md#remote-operator-listener).

### The cookie

At every start the node writes a fresh random cookie to
`<data-directory>/.cookie` and removes it at exit. Under `lattice up` that is
`<root>/chains/Nexus/.cookie`; `--rpc-cookie-file` puts it elsewhere. The
file has mode `0600` and holds `__cookie__:<token>`.

Every route on the operator port requires the cookie, except `GET` and
`HEAD /health`, which stay open so health probes need no secret. Send either:

- `Authorization: Basic <base64 of the file's content>`
  (`curl --user "$(cat .cookie)"`), or
- `Authorization: Bearer <token>` (the part after `__cookie__:`).

```bash
curl -s --user "$(cat <root>/chains/Nexus/.cookie)" http://127.0.0.1:8080/status
```

Anything else gets `401`, with no `WWW-Authenticate` challenge. The cookie
changes at every restart, so a client reads the file again after one.

### Finding the port

Beside the cookie, the node writes where the operator API listens (for
example `http://127.0.0.1:8080`) to `<data-directory>/.rpc-address` at every
start, and removes it at exit. A changed `rpc` key waits for a restart, so
until then `lattice.json` names the next start's port. A local client reads
`.rpc-address` for the current one.

### Requests that change something

On the operator API, a `POST`, `PUT` or `DELETE`:

- must carry a loopback `Host` (`127.0.0.1`, `localhost` or `::1`), or it is
  `403`;
- must declare `Content-Type: application/json` when it has a body, or it is
  `415`.

### Browsers

A request with an `Origin` header gets `403` unless the operator lists that
exact origin with `rpcAllowedOrigins` in `lattice.json`
(`--rpc-allowed-origin`), for example `chrome-extension://<extension id>`.

A listed origin still needs the cookie. It gets:

- CORS preflight answers: methods `GET, HEAD, POST, PUT, DELETE`; headers
  `Authorization, Content-Type, If-Match, If-None-Match`;
- `Access-Control-Allow-Origin` on every response, refusals included, with
  `ETag` exposed.

## Conventions

Requests and responses are JSON unless a route says otherwise.

### Integers

Every 64- or 128-bit consensus integer is a canonical base-10 JSON
**string**, in responses and in the `POST /transactions` body: `0`, or an
optional `-`, then a nonzero digit, then digits (`^(?:0|-?[1-9][0-9]*)$`).

| Kind of value | Encoding |
|---|---|
| Heights, timestamps, block nonces, balances, account and transaction nonces, deltas | Decimal string |
| Deposit, receipt and withdrawal nonces and amounts | Decimal string |
| `rewardCredited`, `minRelayFee`, `finalityWindow`, the chain spec's 64-bit fields | Decimal string |
| Small counts and sizes: `transactionCount`, `mempoolCount`, `mempoolBytes`, `count`, `version`, `maxBlockSize`, offsets | JSON number |
| Targets and work | Hex string |

In a request, a JSON number, a leading `+` or zero, `-0`, or an out-of-range
value in a decimal-string field is refused with `400`.

Two places do not follow the rule, and each is marked where it is
documented:

- The [mining routes](api-mining.md) are the miner's protocol. Their `block`
  is the consensus block's own encoding, and a work submission's `nonce` is
  a JSON number.
- `blockHeight` inside a [state proof](api-reads-and-transactions.md#state-proofs)
  is a JSON number.

### Absent fields

An optional field with no value is omitted. It is never `null`.

### Selecting a chain

A node hosts Nexus and any number of child chains. `GET` routes take the
chain as an optional query value, its absolute path:

```text
?chainPath=Nexus/Alpha
```

- Omitting it selects Nexus.
- A path this node does not host is `404`.
- A transaction names its chain in `body.chainPath`, and the node routes it
  there.
- Mining templates are requested at Nexus and can carry every hosted
  descendant.

Two routes read `chainPath` differently, because the node that answers hosts
the *parent* of the chain named:
[`GET /api/chain/endpoints`](api-reads-and-transactions.md#get-apichainendpoints)
and
[`GET /api/receipt-state`](api-reads-and-transactions.md#get-apireceipt-state).

### Caching

Read responses carry `Cache-Control`:

| Response | Header |
|---|---|
| Content named by CID (a block or transaction by CID, a Volume, the genesis) | `public, max-age=31536000, immutable` |
| Anything that follows the tip (status, latest block, accounts, inclusion, the pool) | `public, max-age=3` |

On the public read listener `/health` for Nexus is itself up to 3 seconds
old. A client that needs the current nonce or tip bypasses its own cache.

### Errors

An error is a status code and a JSON body that names the reason where the
node has one:

```json
{"error": {"message": "belowMinRelayFee"}}
```

| Status | Meaning |
|---|---|
| `400 Bad Request` | Malformed JSON, invalid content, a policy refusal, or invalid work. |
| `401 Unauthorized` | An operator route without the node's cookie, or the remote operator listener without a known bearer token. |
| `403 Forbidden` | A browser `Origin` that is not listed, a non-loopback `Host`, or a route the remote listener's token may not use. |
| `404 Not Found` | An unknown resource, content this node does not hold, or a `chainPath` it does not host. |
| `409 Conflict` | The request conflicts with what is: a pin whose root the store holds with other entries, a chain created otherwise, a node started with flags, a stop already under way. |
| `412 Precondition Failed` | A configuration fragment is not the version the request named. |
| `413 Content Too Large` | A public submit body over 1 MiB. |
| `415 Unsupported Media Type` | An operator request body without `Content-Type: application/json`. |
| `429 Too Many Requests` | The transaction pool is full, or the public listener's rate limit is reached. |
| `503 Service Unavailable` | The node is stopping, busy, or cannot answer yet. Where there is a `Retry-After`, ask again after it. |

Each route's page lists the reasons it names.

## Route index

"Public" means the public read listener. Every route is also on the operator
API and the remote operator listener.

### Reads and transactions

| Method | Path | Public | Purpose |
|---|---|---|---|
| `GET`, `HEAD` | [`/health`](api-reads-and-transactions.md#get-health) | yes | A chain's phase, tip and pool size |
| `GET` | [`/api/chain/info`](api-reads-and-transactions.md#get-apichaininfo) | yes | A chain's tip, and this node's submit and fee policy |
| `GET` | [`/api/chain/spec`](api-reads-and-transactions.md#get-apichainspec) | yes | The chain's spec |
| `GET` | [`/api/chain/genesis`](api-reads-and-transactions.md#get-apichaingenesis) | yes | The genesis CID |
| `GET` | [`/api/peers`](api-reads-and-transactions.md#get-apipeers) | yes | How many peers serve the chain |
| `GET` | [`/api/state/account/:addr`](api-reads-and-transactions.md#get-apistateaccountaddr) | yes | An account's balance and next nonce at the tip |
| `GET` | [`/accounts/:owner`](api-reads-and-transactions.md#get-accountsowner) | yes | An account's balance and next nonce at a given block |
| `GET` | [`/api/block/latest`](api-reads-and-transactions.md#get-apiblocklatest) | yes | The tip block's summary |
| `GET` | [`/api/block/:height-or-cid`](api-reads-and-transactions.md#get-apiblockheight-or-cid) | yes | One block |
| `GET` | [`/api/blocks`](api-reads-and-transactions.md#get-apiblocks) | yes | A page of blocks, newest first |
| `GET` | [`/api/block/:cid/transactions`](api-reads-and-transactions.md#get-apiblockcidtransactions) | yes | A page of a block's transactions |
| `GET` | [`/api/block/:cid/children`](api-reads-and-transactions.md#get-apiblockcidchildren) | yes | The child blocks a block commits |
| `GET` | [`/api/transaction/:cid`](api-reads-and-transactions.md#get-apitransactioncid) | yes | A transaction's actions and where it was included |
| `GET` | [`/transactions/:cid`](api-reads-and-transactions.md#get-transactionscid) | yes | A transaction's content by CID |
| `GET` | [`/api/mempool`](api-reads-and-transactions.md#get-apimempool) | yes | The pending transactions |
| `POST` | [`/transactions`](api-reads-and-transactions.md#post-transactions) | when public submit is on | Submit a transaction |
| `GET` | [`/api/fees`](api-reads-and-transactions.md#get-apifees) | yes | The next blocks this node's pool would fill, for pricing a fee |
| `GET` | [`/api/deposits`](api-reads-and-transactions.md#get-apideposits) | yes | A page of active deposits, with a state proof |
| `GET` | [`/api/deposit-state`](api-reads-and-transactions.md#get-apideposit-state) | yes | One deposit, with a state proof |
| `GET` | [`/api/receipt-state`](api-reads-and-transactions.md#get-apireceipt-state) | yes | The receipt for one deposit, with a state proof |
| `GET` | [`/api/chain/children`](api-reads-and-transactions.md#get-apichainchildren) | yes | The child chains a chain's blocks have committed |
| `GET` | [`/api/chain/endpoints`](api-reads-and-transactions.md#get-apichainendpoints) | yes | The read URLs declared for a child chain |
| `GET` | [`/volumes/:cid`](api-reads-and-transactions.md#get-volumescid) | yes | One complete Volume |
| `GET` | [`/volumes`](api-reads-and-transactions.md#get-volumes) | yes | Several complete Volumes in one body |

### Mining

| Method | Path | Public | Purpose |
|---|---|---|---|
| `POST` | [`/mining/templates`](api-mining.md#post-miningtemplates) | no | Request work |
| `GET` | [`/mining/events`](api-mining.md#get-miningevents) | no | A stream that says when to request new work |
| `POST` | [`/mining/work`](api-mining.md#post-miningwork) | no | Submit a nonce |

### Operator

| Method | Path | Public | Purpose |
|---|---|---|---|
| `GET` | [`/status`](api-operator.md#get-status) | no | A chain's status with sync detail and the template digest |
| `GET` | [`/whoami`](api-operator.md#get-whoami) | no | The caller's own credential |
| `GET` | [`/metrics`](api-operator.md#get-metrics) | no | Prometheus metrics |
| `GET` | [`/core/snapshot`](api-operator.md#get-coresnapshot) | no | Nexus's best header and acted-on tip |
| `GET` | [`/config`](api-operator.md#get-config) | no | The merged configuration and how the node compares with it |
| `GET` | [`/config/fragments/{name}`](api-operator.md#get-configfragmentsname) | no | One configuration fragment |
| `PUT` | [`/config/fragments/{name}`](api-operator.md#put-configfragmentsname) | no | Replace a fragment |
| `DELETE` | [`/config/fragments/{name}`](api-operator.md#delete-configfragmentsname) | no | Remove a fragment |
| `POST` | [`/chains`](api-operator.md#post-chains) | no | Create a child chain |
| `GET` | [`/hosted-chains`](api-operator.md#get-hosted-chains) | no | The child chains running and configured |
| `POST` | [`/child-blocks`](api-operator.md#post-child-blocks) | no | Push a child block |
| `POST` | [`/child-blocks/build`](api-operator.md#post-child-blocksbuild) | no | Build a child's next block |
| `GET` | [`/child-blocks/commitment`](api-operator.md#get-child-blockscommitment) | no | The parent's current commitment for a child |
| `GET` | [`/pins`](api-operator.md#get-pins) | no | The pinned Volumes |
| `POST` | [`/pins`](api-operator.md#post-pins) | no | Pin a Volume |
| `DELETE` | [`/pins/:cid`](api-operator.md#delete-pinscid) | no | Unpin a Volume |
| `GET` | [`/fetch/:cid`](api-operator.md#get-fetchcid) | no | Read a Volume from peers without storing it |
| `GET` | [`/serving-credit/:peer`](api-operator.md#get-serving-creditpeer) | no | A peer's serving standing |
| `POST` | [`/serving-credit`](api-operator.md#post-serving-credit) | no | Credit a peer's serving standing |
| `GET` | [`/logs`](api-operator.md#get-logs) | no | The node's recent log |
| `GET` | [`/disk`](api-operator.md#get-disk) | no | Disk use |
| `POST` | [`/restart`](api-operator.md#post-restart) | no | Restart the node |
| `POST` | [`/stop`](api-operator.md#post-stop) | no | Stop the node |
| `POST` | [`/wipe`](api-operator.md#post-wipe) | no | Delete every chain's data and sync again |
| `GET` | [`/tokens`](api-operator.md#get-tokens) | no | The remote listener's tokens |
| `POST` | [`/tokens`](api-operator.md#post-tokens) | no | Make a token |
| `DELETE` | [`/tokens/{name}`](api-operator.md#delete-tokensname) | no | Revoke a token |

## What the API does not offer

- **No route reads key-value (general) state.** A transaction's key-value
  `actions` are in its content ([`GET /transactions/:cid`](api-reads-and-transactions.md#get-transactionscid)),
  and the state itself is reached by walking Volumes
  ([`GET /volumes/:cid`](api-reads-and-transactions.md#get-volumescid)) from
  a block's `postStateCID`.
- **No route lists an account's transactions**, and nothing is indexed by
  address.
- **Account reads carry no proof.** Only deposit and receipt reads do
  ([State proofs](api-reads-and-transactions.md#state-proofs)).
- **No versioned paths**, and no per-client rate limits: those belong in a
  proxy in front of the node.
