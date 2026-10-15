# HTTP API

Base operator URL: `http://127.0.0.1:<rpc-port>`

The API has one unversioned route set. `/v1/...` does not exist. The operator
listener is loopback-only and authenticated ([Authentication](#authentication)).
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

Browsers are refused: a request with an `Origin` header gets `403` unless the
operator lists that exact origin with `--rpc-allowed-origin` (`rpcAllowedOrigins`
in `lattice.json`), e.g. `chrome-extension://<extension id>`. A listed origin
gets CORS preflight answers (`GET, HEAD, POST`; headers `Authorization,
Content-Type`) and `Access-Control-Allow-Origin` on responses, refusals
included, and still needs the cookie.

## Integer encoding

Every 64- or 128-bit consensus integer, in responses and in the
`POST /transactions` body, is a canonical base-10 JSON **string**: `0`, or
an optional `-` then a nonzero digit then digits (`^(?:0|-?[1-9][0-9]*)$`).
A JSON number, a leading `+` or zero, `-0`, or an out-of-range value is
refused (400). These are heights, revisions, timestamps, block nonces,
balances, account and transaction nonces, deltas, deposit/receipt/withdrawal
nonces and amounts, `rewardCredited`, `minRelayFee`, and the chain spec's
64-bit fields. Small counts and sizes (`transactionCount`, `mempoolCount`,
`mempoolBytes`, `count`, `version`, `maxBlockSize`, offsets) stay JSON
numbers. Targets are hex strings. An absent optional field is omitted, never
`null`.

The mining routes (`/mining/templates`, `/mining/work`) are the miner's
protocol, not this read/submit contract, and are unchanged: their `block` is
the consensus block's own encoding.

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
| `GET /volumes/:cid` | Complete locally held Volume as the Ivy binary archive | yes |
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
| `GET /api/peers?chainPath=P` | The chain's own current peer count: the open sessions that serve it. Without `chainPath`, Nexus's, which is every ready session | yes |
| `GET /api/chain/info` | Chain metadata | yes |
| `GET /api/chain/spec` | Active chain spec | yes |
| `GET /api/chain/genesis` | Selected genesis CID | yes |
| `GET /api/chain/children?chainPath=P` | The child directories P's executed blocks have committed | yes |
| `GET /api/chain/endpoints?chainPath=P/D` | Declared read URLs of a child chain, unverified | yes |
| `GET /status` | Operator status including template digest | no |
| `GET /metrics` | Prometheus exposition | no |
| `GET /core/snapshot` | Internal root snapshot | no |

Block transaction pages accept `offset` and `limit`; limits are capped at
100. CID and response sizes are bounded before decoding.

`GET /volumes/:cid` returns `application/vnd.lattice.volume`: Ivy's canonical
complete-Volume archive (big-endian count and length framing, CID-sorted
entries), capped at 64 MiB. It serves only a Volume already held locally and
never turns an unauthenticated HTTP request into a DHT fetch. Missing or
incomplete content is 404. The immutable response is billed to the expensive
public-read budget. Like the other per-level reads, a hosted child is selected
with `?chainPath=Nexus/Alpha`; omitting it selects Nexus.

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

`GET /api/chain/children?chainPath=Nexus/Alpha` lists, in order, every child
directory the chain's executed blocks have committed. The node keeps the list
in memory: built from the blocks it holds when it starts, then grown by every
block that executes valid. It only grows. A listed child is reached through
its hosts (`/api/chain/endpoints`).

```json
{ "chainPath": ["Nexus", "Alpha"], "directories": ["Beta"] }
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
declares or commits the child. Billed to the expensive public read budget.

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
validated before admission. An unhosted path returns 404.

The node's pool admits only transactions paying at least the operator's
`--min-relay-fee` (default 0): the fee is the transaction's balance excess,
which the block's recipient is credited. Below it the refusal is
`belowMinRelayFee`. This is node relay policy, never consensus: a block
carrying a cheaper transaction stays valid, and other nodes choose their own
floor. `GET /api/chain/info` reports this node's as `minRelayFee`.

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
as immutable. Billed to the expensive public read budget. When the
post-state or block content needed is not held here, inclusion is omitted.

### Public submit

`POST /transactions` on the public-read listener exists only when the
operator starts the node with `--public-submit` (`"publicSubmit": true` in
`lattice.json`); otherwise it is 404. When on, it takes the same body and
gives the same answer and named refusals as the operator route, without the
operator route's loopback `Host` and `Content-Type` checks (CORS allows POST
on that listener). Differences:

- the body is capped at 1 MiB before decoding (`413` above it);
- each client is billed to its expensive read budget, and the listener to a
  separate submit budget (`--public-submit-rate`, default 10/s): `429` over
  either;
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
- `expiresInMilliseconds` — remaining lifetime;
- `templateDigest` — fingerprint of the complete hosted tree's template
  inputs.

A new transaction or candidate at any hosted level changes the digest, even if
the Nexus tip did not move.

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

## Hosted chains

The child chains the node hosts change while it runs. These routes are on the
operator port only.

### `GET /hosted-chains`

```json
{"chains": ["Nexus/Alpha"]}
```

The hosted child chains, parent first.

### `POST /hosted-chains`

```json
{"hostChain": ["Nexus/Alpha", "Nexus/Beta=/path/to/spec.json"],
 "premineTo": ["Nexus/Beta=<address>"],
 "chainPeer": ["Nexus/Alpha=<public-key>@host:port"],
 "policyModule": ["/path/to/module.wasm"]}
```

The node hosts these chains and only these, from now on. Each entry reads as
the start flag of the same name (`--host-chain`, ...); only `hostChain` is
required. A newly listed chain starts as it would at start and syncs from the
node's peers; a chain left out stops with every chain below it, and what it
stored stays, so listing it again resumes it. Answers as `GET
/hosted-chains`. `400` when the list does not hold together (a child before
its parent, a flag value that does not parse); `404` (`notHeld`,
`unknownChain`) when a chain could not start from what it stored.

The hello names what the node hosted at start. Peers learn a newly hosted
chain from its provider record, and a peer that asks for a stopped one is
answered as by any node that does not host it.

## Operator pins

A Volume the operator names by its root CID is held, served to peers and
announced as held, until the operator unpins it. The node does not look
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
(`conflictingVolume`) when the store holds that root with other entries;
`503` (`contextChanged`) when the Volume went from the store before it was
pinned.

### `GET /fetch/:cid`

Reads the Volume from peers and answers it in the shape `POST /pins` takes,
each entry checked against its CID, without storing it: an application
validates what it reads and pins it if it keeps it. `404` (`notServed`)
when no peer serves it.

### `DELETE /pins/:cid`

Unpins the Volume and answers the pins left. It goes from the store unless
something else the node keeps names it. A CID the operator did not pin
changes nothing.

## Errors

- `400 Bad Request` — malformed JSON, invalid content, policy refusal, or
  invalid work;
- `413 Content Too Large` — public submit body over 1 MiB;
- `401 Unauthorized` — operator route without the node's cookie (no challenge header);
- `403 Forbidden` — browser `Origin` not listed, or a non-loopback `Host`;
- `404 Not Found` — unknown resource or unhosted `chainPath`;
- `409 Conflict` — a pin whose root the store holds with other entries;
- `415 Unsupported Media Type` — operator POST without JSON content type;
- `429 Too Many Requests` — mempool or public-read rate limit;
- `503 Service Unavailable` — stopping process or transient core context.

Error bodies use Hummingbird's JSON error envelope and preserve the named
refusal where available.
