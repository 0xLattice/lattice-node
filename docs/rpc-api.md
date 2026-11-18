# HTTP API

Base operator URL: `http://127.0.0.1:<rpc-port>`

The API has one unversioned route set. `/v1/...` does not exist. The operator
listener is loopback-only and authenticated ([Authentication](#authentication)).
An optional remote operator listener serves the same routes to clients on
other machines, with scoped tokens ([Remote operator listener](#remote-operator-listener)).
The optional public-read listener is unauthenticated. The optional public-read
listener registers only the GET routes in the read table below, plus
`POST /transactions` when its operator turns public submit on
([Public submit](#public-submit)); it is off by default.

Requests and responses are JSON unless noted. Operator POSTs require
`Content-Type: application/json` and a loopback `Host` authority.

## Authentication

The operator listener works like bitcoind's RPC cookie. At every start the node
writes a fresh random cookie to `<data-directory>/.cookie` (override with
`--rpc-cookie-file`; under `lattice up` that is `<root>/chains/Nexus/.cookie`),
mode `0600`, content `__cookie__:<token>`, and removes it at exit. Every route
on the operator port requires it except `GET`/`HEAD /health` (public chain
status, also served by the public listener; open so health probes need no
secret). Send either:

- `Authorization: Basic <base64 of the file's content>` (`curl --user "$(cat .cookie)"`), or
- `Authorization: Bearer <token>` (the part after `__cookie__:`).

Anything else gets `401` (no `WWW-Authenticate` challenge).
The cookie changes at every restart; clients re-read the file.

Beside it, in `<data-directory>/.rpc-address`, the node writes where this
listener is (e.g. `http://127.0.0.1:8080`) at every start and removes it at
exit, as Kubo does its `api` file. A changed `rpc` waits for a restart, so
until then `lattice.json` names the next start's port, not this one's; local
clients read the file.

Browsers are refused: a request with an `Origin` header gets `403` unless the
operator lists that exact origin with `--rpc-allowed-origin` (`rpcAllowedOrigins`
in `lattice.json`), e.g. `chrome-extension://<extension id>`. A listed origin
gets CORS preflight answers (`GET, HEAD, POST, PATCH, DELETE`; headers `Authorization,
Content-Type`) and `Access-Control-Allow-Origin` on responses, refusals
included, and still needs the cookie.

## Remote operator listener

A client on another machine (an operator's laptop, a hosting seller, a
dashboard) reaches the operator routes through a second listener, off by
default. In `lattice.json`:

```json
{"operatorListen": "10.0.0.5:8090", "operatorTokens": "operator-tokens.json",
 "operatorAllowedOrigins": ["https://dash.example"]}
```

(`--operator-listen`, `--operator-tokens`, `--operator-allowed-origin` on a
node started with flags). Its port must differ from `listen`, `rpc`,
`publicRead` and `webSocket`. It serves the operator listener's routes (the
same handlers), but:

- Every request, `/health` included, carries `Authorization: Bearer <token>`
  for a token in the file. No known token: `401`. The cookie is not a token
  here.
- Each token has a role or a route list. `admin` may use every route; `read`
  every `GET`/`HEAD` except `/tokens`; a route list only the routes it names.
  Anything else, an unknown path included, is `403`; `GET /whoami` is
  open to every token, whatever its role or routes. A route is the method
  and the path as the node registers it, a parameter in braces:
  `GET /api/state/account/{addr}`, `GET /fetch/{cid}`. A route without a
  parameter may name one path instead: `PUT /config/fragments/hostmarket`
  reaches that fragment and no other, while `PUT /config/fragments/{name}`
  reaches every one. A fragment is the unit of scope: a token that may write
  a fragment may set any key in it, not some keys only. `?chainPath=` is not
  part of a route; a token reaches every chain the node hosts. Only `admin`
  reaches `/tokens`. A token allowed `PUT /config/fragments/{name}`,
  `POST /restart`, `POST /stop` or `POST /wipe` controls the node as fully as
  `admin` does, short of tokens: give those routes only where `admin` would
  do.
- No field may name a file on the node's disk: a fragment that changes
  `operatorTokens` is `400`. That is set beside the node.
- A request with an `Origin` header is `403` unless `operatorAllowedOrigins`
  lists that exact origin; a listed one gets CORS preflight answers (methods
  `GET, HEAD, POST, PUT, DELETE`; headers `Authorization, Content-Type,
  If-Match`), `Access-Control-Allow-Origin` and `ETag` exposed, and still
  needs a token.
- The loopback `Host` check does not apply (a bearer token is not a
  credential a browser sends on its own).

The token file is a JSON array; it holds each token's SHA-256, never the
token. Entries carry `role` or `routes` (a file of `routes` entries only, as
earlier nodes read, still reads):

```json
[{"name": "ops", "sha256": "<hex SHA-256 of the token>", "role": "admin"},
 {"name": "seller", "sha256": "<hex>", "routes": ["GET /config", "PUT /config/fragments/{name}"]}]
```

Tokens are made and revoked through the API ([Tokens](#tokens)); a change
applies from the next request.

The listener is plain HTTP: put it on a private network (a VPN, a private
subnet), or behind a proxy that terminates TLS, and never on a public
address without one. `--rpc-bind` stays loopback-only.

## Integer encoding

Every 64- or 128-bit consensus integer, in responses and in the
`POST /transactions` body, is a canonical base-10 JSON **string**: `0`, or
an optional `-` then a nonzero digit then digits (`^(?:0|-?[1-9][0-9]*)$`).
A JSON number, a leading `+` or zero, `-0`, or an out-of-range value is
refused (400). These are heights, revisions, timestamps, block nonces,
balances, account and transaction nonces, deltas, deposit/receipt/withdrawal
nonces and amounts, `rewardCredited`, `minRelayFee`, `finalityWindow`, and the chain spec's
64-bit fields. Small counts and sizes (`transactionCount`, `mempoolCount`,
`mempoolBytes`, `count`, `version`, `maxBlockSize`, offsets) stay JSON
numbers. Targets are hex strings. An absent optional field is omitted, never
`null`.

The mining routes (`/mining/templates`, `/mining/events`, `/mining/work`) are the miner's
protocol, not this read/submit contract, and are unchanged: their `block` is
the consensus block's own encoding. The miner is a separate process, a client
of these routes (`lattice mine run`, or `lattice-mining-coordinator`); the
node runs none and keeps no mining settings. Each template request carries
its recipients. On the remote listener a miner's token needs only
`POST /mining/templates`, `POST /mining/work` and `GET /status` (the
coordinator's freshness probe).

## Selecting a hosted chain

GET routes accept an optional absolute query value:

```text
?chainPath=Nexus/Alpha
```

Omitting it selects Nexus. A named path must be hosted by this process or the
request returns 404.

Transactions carry `body.chainPath`; the node routes them to that level.
Mining templates are requested at Nexus and can carry every hosted descendant.

## Read routes

| Route | Purpose | Public-read listener |
|---|---|---|
| `GET /health` | Published chain and mempool status | yes |
| `GET /transactions/:cid` | Content-verified transaction by CID | yes |
| `GET /volumes/:cid` | Complete Volume as the Ivy binary archive | yes |
| `GET /volumes?cids=<cid>,<cid>,...` | The complete Volumes this node holds, many in one body | yes |
| `GET /accounts/:owner?block=<cid>` | Account balance and next nonce at an accepted block | yes |
| `GET /api/block/latest` | Latest executed block summary | yes |
| `GET /api/block/:height-or-cid` | Block detail | yes |
| `GET /api/blocks?before=<height>&limit=<n>` | Page of canonical block summaries, newest first | yes |
| `GET /api/block/:cid/transactions` | Paginated block transactions | yes |
| `GET /api/block/:cid/children` | Bounded child commitments | yes |
| `GET /api/transaction/:cid` | Explorer transaction model | yes |
| `GET /api/state/account/:addr` | Account at the current executed tip | yes |
| `GET /api/deposits?limit=<n>&after=<key>` | Page of active deposits, with a state proof | yes |
| `GET /api/deposit-state?key=<demander/amount/nonce>` | One deposit key: its locked amount, `0` once withdrawn, or absent; with a state proof | yes |
| `GET /api/receipt-state?demander=&amount=&nonce=&chainPath=P/D` | The withdrawer a receipt on `P` records for a deposit on `P/D`, with a state proof | yes |
| `GET /api/mempool` | Bounded mempool listing | yes |
| `GET /api/fees` | The blocks this node's pool would fill next, for fee pricing | yes |
| `GET /api/peers?chainPath=P` | The chain's own current peer count: the open sessions that serve it. Without `chainPath`, Nexus's, which is every ready session | yes |
| `GET /api/chain/info` | Chain metadata | yes |
| `GET /api/chain/spec` | Active chain spec | yes |
| `GET /api/chain/genesis` | Selected genesis CID | yes |
| `GET /api/chain/children?chainPath=P` | The child directories P's executed blocks have committed, paged | yes |
| `GET /api/chain/endpoints?chainPath=P/D` | Declared read URLs of a child chain, unverified | yes |
| `GET /status` | Operator status including template digest | no |
| `GET /metrics` | Prometheus exposition | no |
| `GET /core/snapshot` | Internal root snapshot | no |

Block transaction pages accept `offset` and `limit`; limits are capped at
100. CID and response sizes are bounded before decoding.

`GET /volumes/:cid` returns `application/vnd.lattice.volume`: Ivy's canonical
complete-Volume archive (big-endian count and length framing, CID-sorted
entries), capped at 64 MiB. On the loopback port it serves only a Volume the
node holds. On the public read listener, a Volume the node does not hold is
read from peers, checked against its CID, served and not kept; readers asking
for the same Volume share one read, and `--public-read-fetches` (default 4)
caps how many are read at once. No more run than fit, at the 64 MiB cap
each, in half of the node's in-flight content budget
(`--serving-max-in-flight-volume-bytes`), so its own sync keeps the other half;
at least one always runs. At the default budget (128 MiB) that is one at a
time; the node prints the number at start. Past the limit a reader waits,
first come first served, for a read to end; it is never refused for that
alone, and one that closes its connection while it waits gives up its place.
A reader that waited 30 seconds without a place is answered 503 with
`Retry-After: 30`; one whose read found the budget or the node's pending peer
requests with no room, 503 with `Retry-After: 1`. Neither is 404: a reader
should ask again. A request read from peers is answered with
`Connection: close` (200, 404 and 503 alike) and its connection is closed
after the answer; a request pipelined behind it on that connection is dropped
with it, and a client sends it again on a new one. Behind a
proxy that presents every client as one address, all clients share these
reads. `--public-read-fetches 0` serves only what the node holds. A Volume no
peer served within the caps above is 404. Like the other per-level reads, a hosted child is selected
with `?chainPath=Nexus/Alpha`; omitting it selects Nexus.

`GET /volumes?cids=<cid>,<cid>,...` answers many Volumes in one request, for a
client that walks content-addressed state itself and knows several CIDs at
once. The node resolves nothing: it serves only the CIDs named. It returns
`application/vnd.lattice.volumes`: for each requested CID the node holds as a
complete Volume, in request order and once however often it is named, one
record:

```text
u16 BE root CID length | root CID (UTF-8) | u32 BE archive length | archive
```

The archive is exactly what `GET /volumes/:cid` serves. A CID the node does not
hold is left out and is never read from peers here; a client reads it with
`GET /volumes/:cid`, where the public listener may read it from peers. The body
is at most 4 MiB (one protocol frame): the first record that would take it past
that ends the body, and every CID after it is left out unread, so a single
archive over 4 MiB is never in it, never truncated. At most 32 CIDs are
accepted; more, none, or any that is not a CID is `400`. When every requested
CID is in the body the response is immutable like `/volumes/:cid`; otherwise
it is cached for the status max-age only, since the node may hold more later.
It takes `?chainPath=` like the single route.

Both `/api/block/latest` and `/api/block/:height-or-cid` report the block's
coinbase. `rewardRecipient` is the header's recipient address; it is omitted
when the block burns its reward. `rewardCredited` is what consensus
credited that recipient (`Block.coinbaseAmount`): the block reward at that
height plus the block's fees, the balance excess of its transactions. It is
`0` for a burned block and omitted only when this node does not hold the
block's spec or transaction bodies.

`/api/blocks` lists the chain to the tip this node acts on, newest first,
at any hosted level (`?chainPath=`). It returns
`{"blocks": [...], "nextBefore": "<height>"}`; each row is `height`,
`hash`, `previousBlock`, `timestamp`, `transactionCount` and
`rewardRecipient`. Rows are read from block headers and the transactions
dictionary root only — no transaction body — so there is no `rewardCredited`
(read `/api/block/:height-or-cid` for it). `before` (default: tip + 1, and
clamped to it) is exclusive; `limit` defaults to 10 and is capped at 25; at
most `limit` heights are visited, and a height whose block this node does not
hold is omitted. Pass `nextBefore` as the next page's `before`; it is
omitted once height 0 is listed. A non-numeric `before`, or a non-numeric or
non-positive `limit`, is 400.

`/api/block/:cid/children` works at any hosted level (`?chainPath=`). Each
entry is the child's `directory` and committed `blockHash`; `height` and
`transactionCount` are omitted when this node does not hold the child block (it
does not host that child chain).

## Child directories

`GET /api/chain/children?chainPath=Nexus/Alpha` lists, in order, the child
directories the chain's executed blocks have committed. The node keeps the list
in memory: built from the blocks it holds when it starts, then grown by every
block that executes valid. It only grows. A listed child is reached through
its hosts (`/api/chain/endpoints`).

The list is paged: `limit` (default and cap 200) names, starting after the
name `after` (any string; omitted, from the first). `next` is the `after` for
the following page and is absent on the last. A node predating paging
answers the whole list without `next`.

```json
{ "chainPath": ["Nexus", "Alpha"], "directories": ["Beta", "Gamma"], "next": "Gamma" }
```

## Child read endpoints

`GET /api/chain/endpoints?chainPath=Nexus/Alpha/Beta` names a child; this node
must host its parent (`Nexus/Alpha`), else 404. 400 for a missing or
malformed path, or `Nexus` itself.

```json
{
  "chainPath": ["Nexus", "Alpha", "Beta"],
  "committedBlock": "<cid of the newest child block the parent commits, or null>",
  "endpoints": ["https://reads.example.org"],
  "submitEndpoints": ["https://reads.example.org"]
}
```

`submitEndpoints` is the subset of `endpoints` whose hosts also declare that
they accept `POST /transactions` at that URL (equally unverified: confirm with
`GET /api/chain/info` there, whose `acceptsSubmit` is true). A host that
accepts submits answers `.response.v2` (the v1 fields plus `acceptsSubmit`)
before its `.response.v1`; an older reader drops the unknown topic and still
gets the URL, and a v1 answer alone counts as not accepting. An answer from a
node predating the field has no `submitEndpoints`; read it as empty.

`endpoints` lists this node's own declared URL first when it hosts the child,
then URLs other hosts declared over the overlay
(`lattice.overlay.read-endpoint.request.v1` / `.response.v1`; a node answers
only for a level it hosts). The lookup asks at most 8 hosts found through the
child's read-endpoint provider records, in random order, takes at most 2 URLs
from any one, ends within 2 seconds (provider discovery included), closes any
session it dialed only to ask, coalesces identical concurrent lookups,
caches a result for 30 seconds (an empty one for 5), and runs at most 16
lookups at once: past that, a lookup for another name finds nothing and is
not cached. The URLs are NOT
verified and may name any host, internal addresses included: check what a URL
serves before using it (`GET /api/chain/info?chainPath=...` there names the
chain), and do not dial a non-public host on a third party's behalf.

A child is found through the hosts that announce it, so it is listed whether
or not the parent's recent blocks commit it. `committedBlock` is information
only: the newest child block the parent's last 64 canonical blocks commit,
null when they commit none. It can be a block the child chain did not keep,
or one nobody serves, so a reader never requires a URL to serve it. The route
answers 404 when this node does not host the parent, or when nothing hosts,
declares or commits the child.

## Health and status

```json
{
  "phase": "active",
  "chainPath": ["Nexus"],
  "nexusGenesisCID": "bafyreiggtg4ezifboyekbf4gxst2jr3mpjqcxsbmopy7w6fp46g4ngpgxa",
  "tipCID": "<cid>",
  "height": "42",
  "mempoolCount": 3,
  "mempoolBytes": 2048,
  "bestHeaderHeight": "57"
}
```

`GET /status` (operator only) also carries `version`, the node's build version
as `lattice-node --version` prints it, and `startedAt`, when the node process
started (unix seconds; a restart changes it); `/health` carries
neither.

`bestHeaderHeight` is the height of the best header chain the node knows (absent
before any header); `height` is the height of the heaviest executed tip, the
block the node acts on. It is on the best header chain unless a heavier
chain's bodies are not held, so sync progress is `height` of
`bestHeaderHeight`. Both are per level (`?chainPath=`).

`waiting` is present while the level's next block cannot be executed, and says
which block and why, as `body of <cid>: <reason>`. The reason is one of a fixed
set: `exceeds this node's byte budget` (verified content of the body is past
what this node holds for one fetch), `not obtained from any peer`, `local
storage failed`, or `not connected: <failure>` (its connect ended without a
verdict; `<failure>` is the import failure's name). No error text and no
setting's value is shown: the error behind a reason, and the budget, are in
the node's log. The node keeps retrying; the field goes when the block
executes, is excluded, or leaves the best chain.

`GET /status` (operator only) also carries `sync`, counts of what the level's
sync holds as its last step left them: `pendingHeaders` (received, not yet
weighed, most waiting for their parent header), `headersAwaitingProof` (child
headers waiting for a proof that weighs them), `proofChecksRunning` (peers'
proofs in a check, one job per page of headers), `bodyWindow` (the blocks it asks to execute next: every
fork child on the act-on path and the best chain's look-ahead),
`bodiesRequested` (asked of peers, not arrived), `bodiesUnavailable` (window
blocks whose last fetch failed), `bodiesParked` (failed at least once, still in
the window) and `awaitingParentFacts` (a connect needs a parent-chain fact not
executed yet). `/status?chainPath=` answers for a hosted level, 404 for one
not hosted; a hosted child's answer carries no `templateDigest` (the digest is
the root's).

`/health` reads an immutable published view and never enters the core loop. It
has no `templateDigest`. `/status` uses the root runtime's current template
digest so a miner can detect any hosted-tree input change.

A hosted child with no executed genesis reports `awaitingGenesis` and null tip
fields. A child genesis is a normal child root secured by a proof from a mined
ancestor grind; no deployment endpoint or parent authorization transaction is
involved.

## Submit a transaction

### `POST /transactions`

```json
{
  "transaction": {
    "signatures": {"<public-key-hex>": "<signature-hex>"},
    "body": {
      "accountActions": [],
      "actions": [],
      "depositActions": [],
      "receiptActions": [],
      "withdrawalActions": [],
      "signers": ["<address>"],
      "nonce": "0",
      "chainPath": ["Nexus", "Alpha"]
    }
  }
}
```

Response:

```json
{
  "transactionCID": "<cid>",
  "mempoolCount": 4,
  "mempoolBytes": 2600
}
```

The body is content-bound and the signature, nonce, funding, fee, and path are
validated before admission. An unhosted path returns 404. A transaction must
fit in a block by itself: past `maxBlockSize` less 2048 bytes for the block's
own content and its place in it, the refusal is `tooLarge` (so a chain whose `maxBlockSize` is
2048 or less admits nothing). So is one whose state growth, at most (Lattice's
`stateGrowthCeiling`), is past `maxStateGrowth` less 128 bytes for the
coinbase's.

The node's pool admits only transactions paying at least the operator's
`--min-relay-fee` (default 1): the fee is the transaction's balance excess,
which the block's recipient is credited. Below it the refusal is
`belowMinRelayFee`. This is node relay policy, never consensus: a block
carrying a cheaper transaction stays valid, and other nodes choose their own
floor. `GET /api/chain/info` reports this node's as `minRelayFee`.

A refusal names its reason. The retriable ones say to send the same
transaction again later; the rest say to change it.

| Reason | Meaning | Retry as is |
|---|---|---|
| `nonceAhead` | an earlier transaction from its first signer is not mined yet | yes, once it is |
| `unavailable` | this node cannot judge it yet (state, a policy module, a withdrawal's receipt) | yes |
| `insufficientFunds` | an account it debits cannot also pay what pooled transactions debit it, and displacing them would not put it in the next block and make that block pay the relay floor more | yes, once those are mined |
| `full` | the pool is full of transactions paying a higher rate (429) | yes |
| `feeTooLow` | it shares a nonce, state key, deposit or receipt with pooled transactions, and displacing them would not put it in the next block and make that block pay the relay floor more (uncongested: all their fees plus the floor) | no: raise the fee |
| `belowMinRelayFee` | its fee is under this node's floor | no: raise the fee |
| `tooLarge`, `invalidState` | it can never be pooled | no |

`GET /api/chain/info` also reports the chain's
[node-local finality](operations.md#node-local-finality) window, in blocks,
as `finalityWindow`: the operator's `--finality-window` for that chain. It is
node policy, never consensus, and is absent when off (the default).

### Fee pricing

`GET /api/fees` projects the next blocks (up to 12) this node's pool would
fill if nothing else arrived, as this node's builder fills them: pooled
transactions by fee per weight, each block taking them up to the chain's
transaction count, `maxBlockSize` (each charged its place in the block) and
`maxStateGrowth` (each charged its state growth at most), skipping one that
does not fit for a smaller one behind it. A block's rate is the lowest it
carries. It is recomputed on each new tip and, while the pool changes, at
most once a second.

A transaction's weight is the most of a block it takes of any limit, in the
block's bytes: the largest of its size plus `transactionAllowance` (its place
in the block), its state growth (Lattice's `stateGrowthCeiling`) times
`blockRoom / growthRoom` rounded up, and `blockRoom / maxTransactions`. Where
neither growth nor count binds before size, as on Nexus, weight is the bytes a
block charges it. `weight` gives the four for this chain.

```json
{
  "minRelayFee": "1",
  "blocks": [
    { "transactionCount": 1500, "bytes": 570000, "lowestFee": "40", "lowestFeeBytes": 380, "lowestFeeWeight": 636, "full": true },
    { "transactionCount": 400, "bytes": 140000, "lowestFee": "1", "lowestFeeBytes": 350, "lowestFeeWeight": 606, "full": false }
  ],
  "weight": { "blockRoom": 998208, "growthRoom": 2999872, "maxTransactions": 5000, "transactionAllowance": 256 }
}
```

A block is `full` when ready transactions were left for a later one. While
none is full (or `blocks` is empty), a fee at the floor makes the next block.
To be in the first `k` blocks when block `k` is full, a transaction of weight
`w` pays more than `lowestFee * w / lowestFeeWeight` of that block. Older nodes
omit `weight` and `lowestFeeWeight`; their rates are per byte. An older client
that prices per byte against this node is close where weight tracks size, as
on Nexus, and underpays on a chain whose growth or count binds first.

This is an estimate from one node's pool, not a promise: other miners fill
their blocks otherwise, other pools differ, and new transactions arrive. Fees
above `UInt64` never occur for pooled transactions, which are funded.

## Transaction inclusion

`GET /api/transaction/:cid` reports `blockHeight`, `blockHash` and
`timestamp` (the block's) when the transaction is in this chain's canonical
executed chain, and omits them otherwise (pending, never mined, or left by a
reorg). Nothing is indexed: a signer's next nonce only rises along the
canonical chain, and executing the transaction is what moves its first
signer's nonce past the transaction's, so the node binary-searches the
canonical post-states (at most ~64 account reads) for the first block whose
nonce exceeds it, then confirms that block's transaction list holds the CID
(a rival at the same nonce also moves the nonce). Reorg-correct because it
reads the current canonical chain; the answer is cached for 3 seconds, not
as immutable. When the
post-state or block content needed is not held here, inclusion is omitted.

### Public submit

`POST /transactions` on the public-read listener exists only when the
operator starts the node with `--public-submit` (`"publicSubmit": true` in
`lattice.json`); otherwise it is 404. When on, it takes the same body and
gives the same answer and named refusals as the operator route, without the
operator route's loopback `Host` and `Content-Type` checks (CORS allows POST
on that listener). Differences:

- the body is capped at 1 MiB before decoding (`413` above it);
- the listener bills it to a separate submit budget (`--public-submit-rate`,
  default 10/s): `429` over it;
- the transaction is volatile, never written to the local journal, and is
  held to the pool's ordinary capacity rules (fee-rate eviction and
  replacement) with no priority over peer gossip. While it waits for its
  preflight verdict it counts against its own bound (`full` when over).
  Once admitted it is relayed by ordinary gossip.

`GET /api/chain/info` reports `acceptsSubmit` for the listener that answers:
`true` on the operator listener, and on the public listener only when public
submit is on.

## Request mining work

### `POST /mining/templates`

```json
{
  "recipients": [
    {"chainPath": ["Nexus"], "address": "<address>"},
    {"chainPath": ["Nexus", "Alpha"], "address": "<address>"}
  ],
  "minimumWork": [
    {"chainPath": ["Nexus"], "work": "0x100000000"}
  ]
}
```

`recipients` names the reward and fee destination by absolute path. A missing
entry burns that level's payout. Each block commits its recipient in its
proof-of-work preimage.

`minimumWork` is a miner-local search filter. It can demand harder hashes than
the scheduled target but cannot make consensus easier and is not committed as
the chain's target.

The response contains:

- `workID` — opaque issued-work identifier;
- `block` — complete nonce-zero Nexus candidate carrying child candidates;
- `searchTarget` — the easiest threshold that can advance at least one carried
  level, constrained by the request's minimum-work plan;
- `targets` — thresholds useful to the worker;
- `chainPath` — `['Nexus']`;
- `expiresInMilliseconds` — always 30000, kept for clients that require the
  field; it is not a validity bound;
- `templateDigest` — fingerprint of the complete hosted tree's template
  inputs.

A change to what the next block at any hosted level would carry, or a new
candidate, changes the digest, even if the Nexus tip did not move.

Issued work never expires on a clock: proof-of-work arrivals are memoryless,
so the time spent on a template says nothing about when the next tip comes.
Nor does the tip moving retire it: work on an old tip is still work on that
tip, and a solution for it is accepted as a side block (`acceptedSide`), as
Bitcoin's `submitblock` checks no tip. The digest pushed on `GET
/mining/events` tells a miner to fetch new work (Stratum's `clean_jobs`
tells it to stop searching, not the server to forget). The node keeps the
last 512 templates issued, least recently issued dropped first.

A template request is never refused because the tip moved while it was
built: it is answered with the template its build produced, on the tip the
build read, and the digest push that followed the move sends the miner back
for work on the new tip. The only refusals are `busy` (503, too many
requests waiting on builds) and `buildFailed`.

### `GET /mining/events`

A `text/event-stream` of the template digest: the current one at once, then
each time it changes.

```
data: 3f2a...

: keepalive
```

The digest is the one `/status` and every template carry. It changes when a
hosted level's act-on tip moves, when what any hosted level's next block
would carry changes, and when the hosted chains change.
A client fetches a template (`POST /mining/templates`) when it sees a new
digest; work it already holds stays submittable, a solution on an old tip
being a side block.

A client that reads slowly skips to the latest digest: the node holds only
the newest one for it, never a queue. A comment line `: keepalive` every 15
seconds only shows the connection is alive; a quiet chain sends nothing else.
The stream closes when the node stops. Losing it says nothing about the
chain.

## Submit mining work

### `POST /mining/work`

```json
{"workID": "<opaque work id>", "nonce": 123456}
```

Response:

```json
{
  "accepted": true,
  "disposition": "canonicalized",
  "tipCID": "<cid>",
  "durableChildProofs": []
}
```

Possible dispositions are `canonicalized`, `acceptedSide`, `childOnly`,
`duplicate`, and `invalid`. `childOnly` means the hash missed Nexus but met at
least one carried child target. The node stores only child blocks actually
secured by that hash.

The reply is sent after the resulting node step is durable. Every affected
level's facts and stream cursors commit in one `state.db` transaction.

## Child blocks

A hosted child chain's block can be carried by miners of its parent that do
not host it: a parent transaction `child/X` = `C@P` asks them to commit `C`
at `children[X]` (Lattice spec §6.3), and the block's author pushes `C`
until a carrier weighs it ([push-only derived
grinds](design/proof-derived-work.md#push-only-derived-grinds)).
`lattice child commit` drives these routes
([operator CLI](operator-cli.md#committing-a-child-block-on-its-parent)).
They are on the operator port only. `block`, `children` and `spec` are the
base64 bytes of the block node, its child index and a child genesis's spec.

### `POST /child-blocks`

```json
{
  "chainPath": ["Nexus", "Alpha"],
  "block": "<base64 bytes>",
  "children": "<base64 bytes>",
  "spec": "<base64 bytes>"
}
```

`spec` is given only for a genesis. The bytes must be canonical, as on the
gossip wire. The block is taken as a header gossiped without proofs from no
peer would be, and stored as a received header is. Nothing records the
submit.

Response, read after the submit's step:

```json
{"blockCID": "<cid>", "status": "tree"}
```

| `status` | Meaning |
|---|---|
| `tree` | weighed in the child's block tree: done |
| `pending` | proved, waiting for its previous block to be weighed |
| `awaiting` | taken, waiting for a proof that weighs |
| `dropped` | not taken: no connected parent block commits it yet, or the level let it go |

Only `tree` is final. The author submits again on any other status, and
after a restart, an unhost or an eviction. `400` `invalidChainPath` for a
root path, `400` `malformedBlock` for bytes that do not parse or are not
canonical, `404` `unknownChain` for an unhosted chain.

### `POST /child-blocks/build`

```json
{"chainPath": ["Nexus", "Alpha"], "recipient": "<address>"}
```

Builds the child's next block `C` as this node's next template carries it
(its executed tip extended, or its genesis), paying the block reward to
`recipient` (optional; omitted burns it), and stores and retains it with its
closure as a mined block is. Response:

```json
{
  "blockCID": "<cid>",
  "parentState": "<cid>",
  "previous": "<cid>@<cid>",
  "submit": {"chainPath": ["Nexus", "Alpha"], "block": "<base64 bytes>", "children": "<base64 bytes>"}
}
```

`parentState` is the parent state `P` the block was built on. `previous` is
`child/X` in `P`'s general state, the commitment's `oldValue`; it is omitted
when unset (the first commitment). `submit` is the `POST /child-blocks` body
that pushes the block, with `spec` for a genesis.

`400` `invalidChainPath` for a path that is not below this node's chain,
`400` `invalidRecipientPlan` for a recipient that is not an address, `404`
`unknownChain` for an unhosted chain, `400` `noChildCandidate` when the
template carries no block for the chain (its genesis is weighed but not
executed, or it has no spec to start from), `404` `notHeld` when `P`'s state
is not readable here. `previous` is never guessed.

### `GET /child-blocks/commitment`

```text
GET /child-blocks/commitment?chainPath=Nexus/Alpha
```

Read only: nothing is built or retained.

```json
{"parentState": "<cid>", "value": "<cid>@<cid>"}
```

`parentState` is the post-state of the parent's executed tip, the state its
next block enters. `value` is `child/X` there, read as the build route reads
`previous`; omitted when unset. `400` `invalidChainPath`, `404`
`unknownChain`, and `404` `notHeld` when the parent has no executed tip or
its state is not readable here.

## Operator control

A node started as `lattice-node --root <root>` (what `lattice up` runs) takes
its configuration from layers, as systemd drop-ins and `sudoers.d` do:
`<root>/lattice.json`, then each `<root>/config.d/<name>.json` in name order
(byte order; number them, `10-deploy`, `50-hostmarket`, to order them). Name
order is the only precedence: no layer outranks another otherwise. Each
writer owns one fragment (a deploy script `deploy`, a hosting seller its
own, people and `lattice config set` `operator`); the node never writes
`lattice.json`. A file of `config.d` whose name is not a fragment's
(`README`, `x.json.bak`, `Deploy.json`) is not read, and is reported. Every
layer has `lattice.json`'s keys, and they merge:

- a value (a port, a rate, a mode): the later layer's;
- `hostedChains`, each chain's `peers`, `rpcAllowedOrigins`,
  `operatorAllowedOrigins`: the union of every layer's;
- `stateWindows`, `finalityWindows`: per chain path, the later layer's.

A key set to `null` is as if the layer did not set it: it does not unset an
earlier layer's value (remove the key from the layer that sets it).

A `hostedChains` entry is a chain's path. A child chain runs only under its
parent (its blocks ride in the parent's, and validating it reads the
parent's state), so the node hosts the smallest tree rooted at Nexus that
holds every listed chain: the listed chains and their ancestors. An
ancestor no layer lists is hosted implied by the listed chains under it, as
apt installs a package's dependencies: a chain stops only once no layer
lists it or any chain under it. A path created on this node (its spec under
`<root>/specs/`, written by [`POST /chains`](#post-chains)) is mined from
that spec; any other is synced from its peers. A chain that does not start
is not hosted and its status says why. A chain's settings (its `peers`,
`stateWindows` and `finalityWindows` entries) apply wherever it is in the
tree, listed or implied. A setting for a chain not in the tree, or a state
window while `state` is not `recent`, is inert: left out and listed in
`status.inert`, not an error. Anything else wrong (a file that is not one JSON object, an unknown
key, a merged result that does not check) is the whole configuration's: the
node does not start (exit 78), and a change that would make it so is `400`.

The node reads the layers at its start, again on `SIGHUP` (systemd's
`ExecReload`), and after each change of a fragment through this API; a
re-read is checked as a change is, and one that does not check is not used.
Hosted chains and child chains' peers apply at once; every other key (ports,
Nexus's peers, retention, listeners, serving limits, relay fee, ...) at the
next start, listed as `pendingRestart` until [`POST /restart`](#post-restart).
A node started with flags has no configuration of its own: these routes
answer `409` there.

### `GET /config`

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

`spec.hostedChains` lists the chains the tree holds, parent first.
`status.chains` lists each of them: a listed chain with the layers that
list it (`from`), an implied one with `from` empty and the listed chains
under it that keep it (`impliedBy`); and any chain still running that the
tree no longer holds, with an `error`. `errors` holds
what else does not match: a re-read (`SIGHUP`) the node could not use (it
keeps the configuration it had), an operator listener that could not open
(the node runs on without it, reachable on loopback). `inert` holds what the
layers set that does not apply, and why.

### `GET /config/fragments/{name}`

The fragment's file as it is (`application/json`), its version in `ETag`
(the SHA-256 of its bytes); `lattice` is `lattice.json`. `404` when there is
none.

### `PUT /config/fragments/{name}`

Replaces the fragment with the body, one JSON object
(`Content-Type: application/json`), and answers as `GET /config`. A name is
lowercase letters, digits, `.`, `_` and `-`, starting with a letter or digit
(`deploy`, `50-hostmarket`); `lattice.json` is not written here. `400` when
the configuration it makes does not check, including one the node would not
start from (its start-time checks are run on it): nothing is written. A
chain that does not start is reported in `status`, not refused. On the
remote listener a fragment may not change `operatorTokens` (a file on the
node's disk): `400`. With `If-Match` (the `ETag` a `GET` answered, or `*`
for any version), it is written only while the fragment is still that
version: `412` otherwise, nothing written; read it again and redo the change.
With `If-None-Match: *`, it is written only while there is no such fragment
yet (`412` otherwise). A client that edits a fragment others write too sends
one of them: `If-Match` for the version it read, `If-None-Match: *` when it
read none.

### `DELETE /config/fragments/{name}`

Removes the fragment, answering as `GET /config`; `400` when what is left
does not check, `404` when there is none, `412` as for `PUT` with an
`If-Match` that is not its version. A chain no layer lists any more stops,
unless a chain listed under it keeps it, implied; what it stored stays, and
hosting it again resumes it.

### `POST /chains`

Creates a child chain, once: the body is what fixes its genesis,

```json
{"path": "Nexus/Beta",
 "spec": {"...": "a ChainSpec, as in a spec file"},
 "premineTo": "<address, when the spec pays a premine>",
 "genesisTransactions": [{"transaction": {"...": "as POST /transactions takes"}}],
 "policyModules": ["<base64 WASM module the spec names>"]}
```

checked as `lattice child create` checks it and kept under `<root>/specs/`.
`200 {"path": "Nexus/Beta", "created": true}`; `created` is false when the
chain was created with exactly this already. `409` when it was created with
something else, or the node already follows it without a spec (it is in the
hosted tree, listed or implied, running or not, or its storage holds the
chain's blocks: a spec would mine a rival genesis); `400` when the body does
not check. Creating
does not host the chain: list its path in a fragment's `hostedChains` to
mine its genesis and then its blocks. A created spec stays even if the
chain is never hosted or never starts: to create the path otherwise, remove
its files under `<root>/specs/` by hand while the node is stopped.

### `GET /hosted-chains`

```json
{"chains": ["Nexus/Alpha"], "configured": ["Nexus/Alpha", "Nexus/Beta"]}
```

The child chains running, parent first, and those the configuration hosts
(the tree: listed or implied, `spec.hostedChains` of `GET /config`, whose
`status.chains` this summarises). `configured` is absent on a node started
with flags.

A peer that connects afterwards is told the new list in the hello. A peer
already connected learns a newly hosted chain from its provider record, and a
peer that asks for a stopped one is answered as by any node that does not
host it.

### `GET /logs?tail=N`

The last `N` lines (default 200, at most 10000) of the node's log, as
`text/plain`. Each line the node logs goes to its standard error (where its
process manager collects it) and is kept in memory, the last 10000 lines and
at most 4 MiB: lines from before its last start are not here, nor is
anything else on standard error, such as a crash report or
`LATTICE_SYNC_TRACE=1` output. `?file=node` is
accepted; any other `file` is `404` (a client beside the node keeps its own
log).

### `GET /disk`

```json
{"storage": "/var/lib/lattice/chains/Nexus",
 "stores": [{"name": "state.db", "bytes": 7352320}, {"name": "volumes.db", "bytes": 1744896}],
 "totalBytes": 15183872, "freeBytes": 112642072576}
```

Bytes per store in the data directory, and the free bytes on its volume.

### `POST /restart`

`409` when the configuration as it is on disk would not start the node (it
is read and checked as a start would), or when a stop or restart is already
under way. Otherwise `202 {"restarting": true}`,
then the node stops as on SIGTERM and exits with status 75 (`EX_TEMPFAIL`).
Its process manager starts it again (systemd `Restart=on-failure`, launchd
`KeepAlive`, `docker run --restart on-failure`), and the new process reads
`lattice.json` afresh; the node never starts itself. Clients wait until
`startedAt` in `GET /status` changes.

### `POST /stop`

`202 {"stopping": true}`, then the node stops as on SIGTERM and exits 0,
which a process manager leaves stopped. Clients wait until nothing answers.

### `POST /wipe`

`202 {"restarting": true, "wiping": true}`; root mode only. The wipe runs at
the node's next start, before it opens its storage: the node records it,
exits 75 as for a restart, and the started process deletes every chain's
data (`<root>/chains`). Identity, `lattice.json`, specs and tokens stay.
Nexus syncs again from its peers, and hosted chains from theirs. Per-chain
wipes are not offered: chains share one store. `409`, with no wipe recorded,
once a stop or restart is already under way, since that start may not come.

### Tokens

`GET /tokens` → `{"tokens": [{"name": "ops", "role": "admin"}, {"name": "seller", "routes": ["GET /status"]}]}`.

`POST /tokens` `{"name": "dash", "role": "read"}` (or `"routes": [...]`) →
`{"name": "dash", "token": "<64 hex>"}`. The token is shown this once; the
file keeps its SHA-256 (written atomically, mode `0600`, created on first
use). `409` for a name in use; `400` for an unknown role, or both a role and
routes.

`DELETE /tokens/{name}` revokes it; `404` for an unknown name.

`GET /whoami` names the caller's own credential, so a client can offer only
what it may do: `{"name": "seller", "routes": ["GET /hosted-chains"]}`, or
`{"name": "ops", "role": "admin"}`. `role` is absent for a route-list token
and `routes` for a role. The cookie answers `{"name": "cookie", "role":
"admin"}`. It never includes a secret or its hash. Every credential the
listener accepts may call it; none: `401`.

The cookie (on the operator port) and `admin` tokens (on the remote listener)
reach these routes. `409` when the node has no token file
(`operatorTokens`).

## Operator pins

A Volume the operator names by its root CID is held, served to peers and
announced as held, until the operator unpins it. With
`--no-announce-pins` pins are held and served but never announced: a
holder of many Volumes need not send a record per Volume. The node does not look
inside it or follow anything it names, and it is kept whatever
`blockBodies` says. These routes are on the operator port only.

### `GET /pins`

```json
{"pins": ["<cid>"]}
```

### `POST /pins`

```json
{"cid": "<cid>", "entries": {"<cid>": "<base64 bytes>"}}
```

Pins the Volume and answers the pins as `GET /pins` does. A Volume the node
holds needs only `cid`. One it does not hold is stored only as the operator
provides it in `entries`, the root and the entries it lists, each checked
against its CID; the node never reads a pin from peers. `404` (`notHeld`)
when the node does not hold it and `entries` does not provide it; `400`
(`invalidVolume`) when `entries` lacks the root or an entry is not the bytes
its CID names; `409`
(`conflictingVolume`) when the store holds that root with other entries.
A Volume that leaves the store before it is pinned answers `404`
(`notHeld`).

### `GET /fetch/:cid`

Reads the Volume from peers and answers it in the shape `POST /pins` takes,
each entry checked against its CID, without storing it: an application
validates what it reads and pins it if it keeps it. `404` (`notServed`)
when no peer serves it.

### `DELETE /pins/:cid`

Unpins the Volume and answers the pins left. It goes from the store unless
something else the node keeps names it. A CID the operator did not pin
changes nothing.

## Serving standing

Serving is free while the holder has a free slot. Only when every slot is
busy do waiting requests share freed slots by weight, which grows with the
peer's standing: one non-negative byte count per peer. Standing goes up by
bytes the operator credits (paid for, say, through a sponsor such as
lattice-sponsor) and by verified content the peer served this node on
request. It goes down by the Volume archive bytes this node serves the peer,
contended or not, and never below zero. It does not decay (see
[operations.md](operations.md#serving-standing)).

A peer is named by its Ed25519 public key as Ivy and the node print it (the
`storage:` line at start, `PeerEndpoint.publicKey`): exactly 64 lowercase hex
characters, without the `ed01` multikey prefix. Any other spelling is `400`
(`invalidPeer`).

### `GET /serving-credit/:peer`

Operator port only.

```json
{"peer": "<peer key>", "standing": 7168}
```

### `POST /serving-credit`

Operator port only: credits `bytes` (at least 1) to `peer`'s standing and
answers it as `GET /serving-credit/:peer` does. A sponsor uses it to credit
work. `400` `invalidPeer` or `invalidBytes`; `503` `notSaved` (the credit
could not be written, and was not applied).

```json
{"peer": "<peer key>", "bytes": 1048576}
```

Every standing is kept in `<data-directory>/serving.json`, written before
each credit is applied, on every maintenance pass and at a clean stop. A
crash loses only the changes since the last write, never a credit. It must
move with the data directory: a node started without it starts with no
standings. Fields it does not know (an earlier node's credited transactions)
are ignored.

## Errors

- `400 Bad Request` — malformed JSON, invalid content, policy refusal, or
  invalid work;
- `413 Content Too Large` — public submit body over 1 MiB;
- `401 Unauthorized` — operator route without the node's cookie, or on the
  remote operator listener without a known bearer token (no challenge header);
- `403 Forbidden` — browser `Origin` not listed, a non-loopback `Host`, or a
  route the remote operator listener's token does not list;
- `404 Not Found` — unknown resource or unhosted `chainPath`;
- `409 Conflict` — a pin whose root the store holds with other entries;
- `415 Unsupported Media Type` — operator POST without JSON content type;
- `429 Too Many Requests` — mempool or public-read rate limit;
- `503 Service Unavailable` — stopping process or transient core context.

Error bodies use Hummingbird's JSON error envelope and preserve the named
refusal where available.
