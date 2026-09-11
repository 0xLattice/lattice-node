# Lattice Node HTTP API

This is the HTTP surface of the current one-process/one-chain daemon.

Base URL: `http://127.0.0.1:<rpc-port>`

The listener is unauthenticated and therefore loopback-only. Put a
same-host authenticated proxy in front of it if another machine must call it;
the daemon itself rejects non-loopback bind addresses.

Every request targets the chain owned by that process. There is no `chainPath`
query selector. Whenever a path appears in a body or response, it is an
absolute array whose first element is `"Nexus"`; paths that omit it are rejected.

Requests are JSON. Transaction-bearing fields use a content-bound form so the
receiver can reconstruct and verify the transaction body CID:

```json
{
  "signatures": {"<public-key-hex>": "<signature-hex>"},
  "body": {
    "accountActions": [],
    "actions": [],
    "depositActions": [],
    "genesisActions": [],
    "receiptActions": [],
    "withdrawalActions": [],
    "signers": [],
    "fee": 0,
    "nonce": 0,
    "chainPath": ["Nexus"]
  }
}
```

## Status

### `GET /health`

### `GET /v1/status`

Both routes return the same chain-process status:

```json
{
  "phase": "active",
  "chainPath": ["Nexus"],
  "nexusGenesisCID": "bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq",
  "tipCID": "<cid>",
  "height": 42,
  "revision": 57,
  "mempoolCount": 3,
  "mempoolBytes": 2048
}
```

A child reports `phase: "awaitingGenesis"`, with null tip and height, until its
authenticated immediate parent confirms the recorded genesis CID and the child
admits that genesis.
After bootstrap, it reports `phase: "active"` from its durable accepted graph;
parent connectivity does not change the meaning of proof-derived work.

`revision` is the local consensus mutation watermark.

## Transactions

### `POST /v1/transactions`

Submit one signed transaction whose body path exactly matches this process.

```json
{
  "transaction": {
    "signatures": {"<public-key-hex>": "<signature-hex>"},
    "body": {"chainPath": ["Nexus"], "...": "other TransactionBody fields"}
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

The premine is never accepted through RPC. It exists only in the locally
constructed Nexus bootstrap block whose recomputed CID matches the configured
trust anchor.

## Mining

Mining is an external pipeline: the node issues and later validates work,
`lattice-mining-coordinator` schedules ranges, and `lattice-miner` workers
search those ranges.

### `POST /v1/mining/templates`

Issue bounded, expiring work. This public route is Nexus-only; child candidates
are requested through the authenticated hierarchy plane while the template is
assembled.

```json
{
  "rewards": [
    {
      "chainPath": ["Nexus"],
      "transaction": {
        "signatures": {"<public-key-hex>": "<signature-hex>"},
        "body": {"chainPath": ["Nexus"], "...": "other TransactionBody fields"}
      }
    }
  ]
}
```

`rewards` is the only request field and may be empty; other fields are
ignored. Each reward is an externally signed transaction for one absolute chain
path; process identity is never converted into wallet identity. There is no
template mode: transactions carrying a `GenesisAction` are selected from the
pool like any other transaction.

Response fields:

- `workID`: CID of the nonce-zero candidate.
- `block`: the complete candidate block.
- `searchTarget`: the threshold the miner must hit. It is the easiest
  (numerically largest) of the Nexus candidate's own target and the search
  targets of the attached child candidates, each of which already accounts for
  its own descendants. A nonce that meets `searchTarget` but not the Nexus
  target can still advance a descendant chain.
- `chainPath`: always `["Nexus"]` on this route.
- `expiresInMilliseconds`: template lifetime.

### `POST /v1/mining/work`

```json
{"workID": "<candidate-cid>", "nonce": 123456}
```

Response fields are `accepted`, `disposition`, `tipCID`,
`parentCarrierLink`, `parentGenesisLinks`, and `durableChildProofs`. Child-proof
delivery is asynchronous; this field acknowledges local durability, not remote
receipt.
Possible dispositions are `canonicalized`, `acceptedSide`, `carrier`,
`duplicate`, `unavailable`, `temporarilyInvalid`, `invalid`, `localFailure`,
and `storageFailed`.

## Child genesis

No RPC route builds or carries a child genesis. A child genesis is
self-contained: it commits to the empty parent state and uses the maximum
target, so it is built offline and deterministically from a seed (the child
`ChainSpec`, an optional premine recipient, and a timestamp). The parent only
records its CID. The deployer constructs and signs an ordinary parent
transaction containing `GenesisAction(directory, blockCID)` and submits it
through `POST /v1/transactions`. Mining templates select it like any other
transaction; the accepted parent block records `directory -> genesisCID` in the
parent's committed genesis state. The parent's `GET /api/chain/children`
returns at most 100 of those entries with no offset, so on a parent with more
children a recorded child can be absent from it.

A child process launched with `--chain-path Nexus/Payments` and `--parent
<parent-key>@<host>:<fact-port>` stays `awaitingGenesis` until it can admit
that genesis, which it pursues by two concurrent paths. If its data directory
contains the seed as `child-genesis.json` at startup (the file is read only
then), it rebuilds the genesis from the seed. Independently, it asks its parent
for the CID recorded under its directory and fetches the genesis block by that
CID from child-overlay peers. Either way it admits the genesis only after its
authenticated immediate parent confirms that it recorded exactly that CID.
`lattice child deploy` performs these steps; see [Operator CLI](operator-cli.md).

## Errors and limits

- Malformed or invalid requests return `400 Bad Request`.
- Requests that require an active child before genesis return `409 Conflict`.
- Consensus-producing requests return `503 Service Unavailable` only when the
  process is not active or the requested local resource is temporarily
  unavailable.
- A full transaction pool returns `429 Too Many Requests`.
- A temporarily unavailable transaction policy returns `503 Service
  Unavailable`.
- Request bodies are bounded to 2 MiB, Hummingbird's default upload limit.
  Within that, a transaction submission and a template request's rewards are
  each bounded to 1 MiB once re-encoded.
