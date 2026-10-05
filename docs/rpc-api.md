# HTTP API

Base operator URL: `http://127.0.0.1:<rpc-port>`

The API has one unversioned route set. `/v1/...` does not exist. The operator
listener is unauthenticated and loopback-only. The optional public-read
listener registers only the GET routes in the read table below, plus
`POST /transactions` when its operator turns public submit on
([Public submit](#public-submit)); it is off by default.

Requests and responses are JSON unless noted. Operator POSTs require
`Content-Type: application/json` and a loopback `Host` authority.

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
| `GET /accounts/:owner?block=<cid>` | Account balance and next nonce at an accepted block | yes |
| `GET /api/block/latest` | Latest executed block summary | yes |
| `GET /api/block/:height-or-cid` | Block detail | yes |
| `GET /api/blocks?before=<height>&limit=<n>` | Page of canonical block summaries, newest first | yes |
| `GET /api/block/:cid/transactions` | Paginated block transactions | yes |
| `GET /api/block/:cid/children` | Bounded child commitments | yes |
| `GET /api/transaction/:cid` | Explorer transaction model | yes |
| `GET /api/state/account/:addr` | Account at the current executed tip | yes |
| `GET /api/mempool` | Bounded mempool listing | yes |
| `GET /api/peers` | Ready peer count | yes |
| `GET /api/chain/info` | Chain metadata | yes |
| `GET /api/chain/spec` | Active chain spec | yes |
| `GET /api/chain/genesis` | Selected genesis CID | yes |
| `GET /api/chain/endpoints?chainPath=P/D` | Declared read URLs of a child chain, unverified | yes |
| `GET /status` | Operator status including template digest | no |
| `GET /metrics` | Prometheus exposition | no |
| `GET /core/snapshot` | Internal root snapshot | no |

Block transaction pages accept `offset` and `limit`; limits are capped at
100. CID and response sizes are bounded before decoding.

Both `/api/block/latest` and `/api/block/:height-or-cid` report the block's
coinbase. `rewardRecipient` is the header's recipient address; it is omitted
(null) when the block burns its reward. `rewardCredited` is what consensus
credited that recipient (`Block.coinbaseAmount`): the block reward at that
height plus the block's fees, the balance excess of its transactions. It is
`0` for a burned block and omitted only when this node does not hold the
block's spec or transaction bodies.

`/api/blocks` lists the canonical chain to the executed tip, newest first,
at any hosted level (`?chainPath=`). It returns
`{"blocks": [...], "nextBefore": <height or null>}`; each row is `height`,
`hash`, `previousBlock`, `timestamp`, `transactionCount` and
`rewardRecipient`. Rows are read from block headers and the transactions
dictionary root only — no transaction body — so there is no `rewardCredited`
(read `/api/block/:height-or-cid` for it). `before` (default: tip + 1, and
clamped to it) is exclusive; `limit` defaults to 10 and is capped at 25; at
most `limit` heights are visited, and a height whose block this node does not
hold is omitted. Pass `nextBefore` as the next page's `before`; it is null
once height 0 is listed. A non-numeric `before`, or a non-numeric or
non-positive `limit`, is 400.

`/api/block/:cid/children` works at any hosted level (`?chainPath=`). Each
entry is the child's `directory` and committed `blockHash`; `height` and
`transactionCount` are null when this node does not hold the child block (it
does not host that child chain).

## Child read endpoints

`GET /api/chain/endpoints?chainPath=Nexus/Alpha/Beta` names a child; this node
must host its parent (`Nexus/Alpha`), else 404. It also answers 404 when none
of the parent's last 64 canonical blocks commits the child's directory and
the node does not host the child. 400 for a missing or malformed path, or
`Nexus` itself.

```json
{
  "chainPath": ["Nexus", "Alpha", "Beta"],
  "committedBlock": "<cid of the newest child block the parent commits>",
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
session it dialed only to ask, coalesces identical concurrent lookups, and
caches a result for 30 seconds (an empty one for 5). The URLs are NOT
verified and may name any host, internal addresses included: accept one only
after it serves `committedBlock` at `/api/block/<committedBlock>?chainPath=...`,
and do not dial a non-public host on a third party's behalf. `committedBlock`
is null only when this node hosts the child but the parent's recent blocks
commit none; there is then nothing to verify against. Billed to the expensive
public read budget.

## Health and status

```json
{
  "phase": "active",
  "chainPath": ["Nexus"],
  "nexusGenesisCID": "bafyreiggtg4ezifboyekbf4gxst2jr3mpjqcxsbmopy7w6fp46g4ngpgxa",
  "tipCID": "<cid>",
  "height": 42,
  "revision": null,
  "mempoolCount": 3,
  "mempoolBytes": 2048,
  "templateDigest": null
}
```

`/health` reads an immutable published view and never enters the core loop. Its
`templateDigest` is null. `/status` uses the root runtime's current template
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
      "nonce": 0,
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

## Errors

- `400 Bad Request` — malformed JSON, invalid content, policy refusal, or
  invalid work;
- `413 Content Too Large` — public submit body over 1 MiB;
- `404 Not Found` — unknown resource or unhosted `chainPath`;
- `415 Unsupported Media Type` — operator POST without JSON content type;
- `429 Too Many Requests` — mempool or public-read rate limit;
- `503 Service Unavailable` — stopping process or transient core context.

Error bodies use Hummingbird's JSON error envelope and preserve the named
refusal where available.
