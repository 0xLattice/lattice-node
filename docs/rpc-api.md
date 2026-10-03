# HTTP API

Base operator URL: `http://127.0.0.1:<rpc-port>`

The API has one unversioned route set. `/v1/...` does not exist. The operator
listener is unauthenticated and loopback-only. The optional public-read
listener registers only the GET routes in the read table below.

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
| `GET /api/block/:cid/transactions` | Paginated block transactions | yes |
| `GET /api/block/:cid/children` | Bounded child commitments | yes |
| `GET /api/transaction/:cid` | Explorer transaction model | yes |
| `GET /api/state/account/:addr` | Account at the current executed tip | yes |
| `GET /api/mempool` | Bounded mempool listing | yes |
| `GET /api/peers` | Ready peer count | yes |
| `GET /api/chain/info` | Chain metadata | yes |
| `GET /api/chain/spec` | Active chain spec | yes |
| `GET /api/chain/genesis` | Selected genesis CID | yes |
| `GET /status` | Operator status including template digest | no |
| `GET /metrics` | Prometheus exposition | no |
| `GET /core/snapshot` | Internal root snapshot | no |

Block transaction pages accept `offset` and `limit`; limits are capped at
100. CID and response sizes are bounded before decoding.

## Health and status

```json
{
  "phase": "active",
  "chainPath": ["Nexus"],
  "nexusGenesisCID": "bafyreigv5sprcqkq52sonreff7yh6bgg5lgaekvzceiddnkckzb2vzguem",
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
- `404 Not Found` — unknown resource or unhosted `chainPath`;
- `415 Unsupported Media Type` — operator POST without JSON content type;
- `429 Too Many Requests` — mempool or public-read rate limit;
- `503 Service Unavailable` — stopping process or transient core context.

Error bodies use Hummingbird's JSON error envelope and preserve the named
refusal where available.
