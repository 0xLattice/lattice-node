# HTTP API: reads and transactions

The routes an app, wallet or explorer uses: read a chain, read an account,
submit a transaction, and find out whether it was included.

Every route here is served by the public read listener (`POST /transactions`
only when its operator turns [public submit](#public-submit) on) and by the
operator API. How to reach each, how integers are encoded, how to select a
chain with `?chainPath=`, and the error format are in
[HTTP API](rpc-api.md). In the tables below, "decimal string" is the
[integer encoding](rpc-api.md#integers) described there, and a field marked
optional is omitted when it has no value.

## Sending a transaction, start to finish

1. Find a node that accepts submits. `acceptsSubmit` in
   [`GET /api/chain/info`](#get-apichaininfo) says whether the listener you
   are talking to does. For a child chain,
   [`GET /api/chain/endpoints`](#get-apichainendpoints) on a node hosting its
   parent lists hosts that declare they do.
2. Read the signer's next nonce from
   [`GET /api/state/account/:addr`](#get-apistateaccountaddr).
3. Choose a fee: at least `minRelayFee`, and more when
   [`GET /api/fees`](#get-apifees) shows full blocks ahead.
4. Sign the transaction and send it with
   [`POST /transactions`](#post-transactions). Keep the `transactionCID` it
   answers.
5. Poll [`GET /api/transaction/:cid`](#get-apitransactioncid). The
   transaction is included once the answer carries `blockHeight`.

## Chain status

### `GET /health`

A chain's phase, tip and pool size. `HEAD /health` answers the same headers
without a body. On the operator API this is the one route that needs no
cookie. It reads a published view and never enters the node's core loop, so
polling it cannot hold up the node's own work.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

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

| Field | Type | Meaning |
|---|---|---|
| `phase` | string | `active`, or `awaitingGenesis` for a hosted child chain with no executed genesis yet. |
| `chainPath` | array of strings | The chain answered for. |
| `nexusGenesisCID` | string | The Nexus genesis this node follows. |
| `tipCID` | string, optional | The heaviest executed tip: the block the node acts on. Omitted while `awaitingGenesis`. |
| `height` | decimal string, optional | That tip's height. Omitted while `awaitingGenesis`. |
| `mempoolCount` | number | Transactions in this chain's pool. |
| `mempoolBytes` | number | Their size in bytes. |
| `bestHeaderHeight` | decimal string, optional | The height of the best header chain the node knows. Omitted before any header. |
| `waiting` | string, optional | Present while the chain's next block cannot be executed: which block, and why. |

Reading it:

- **Sync progress** is `height` of `bestHeaderHeight`. The tip is on the best
  header chain unless a heavier chain's bodies are not held.
- **`waiting`** has the form `body of <cid>: <reason>`. The reason is one of
  a fixed set:
  - `exceeds this node's byte budget`: the body's verified content is past
    what this node holds for one fetch;
  - `not obtained from any peer`;
  - `local storage failed`;
  - `not connected: <failure>`: connecting the block ended without a
    verdict, and `<failure>` is the import failure's name.

  No error text and no setting's value is shown; those are in the node's
  log. The node keeps retrying, and the field goes when the block executes,
  is excluded, or leaves the best chain.
- **`awaitingGenesis`**: a child chain's genesis is an ordinary child block,
  secured by a proof from a mined ancestor. No deployment endpoint or
  parent authorization transaction is involved
  ([Child chains](child-chains.md#a-chain-stuck-at-awaitinggenesis)).

The response has no `templateDigest`, `version`, `startedAt` or `sync`:
those are on the operator's [`GET /status`](api-operator.md#get-status).

**Errors**: `404` for a chain this node does not host.

### `GET /api/chain/info`

A chain's tip, and the policy of the node and listener that answered.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `genesisHash` | string, optional | The CID of this chain's block at height 0. |
| `height` | decimal string, optional | The executed tip's height. |
| `tipCID` | string, optional | The executed tip. |
| `chain` | array of strings | The chain's path. |
| `acceptsSubmit` | boolean | Whether the listener that answered accepts `POST /transactions`: `true` on the operator API, and on the public read listener only when public submit is on. |
| `minRelayFee` | decimal string | The smallest fee this node admits to its pool. Node policy, never consensus; `0` admits any fee. |
| `finalityWindow` | decimal string, optional | This node's [node-local finality](configuration.md#node-local-finality) window for the chain, in blocks. Node policy, never consensus. Omitted when off, the default. |

**Errors**: `404` for a chain this node does not host.

### `GET /api/chain/spec`

The spec the chain's tip block carries.

**Request**: optional `chainPath` query value.

**Response**

| Field | Type |
|---|---|
| `targetBlockTime` | decimal string |
| `initialReward` | decimal string |
| `halvingInterval` | decimal string |
| `maxBlockSize` | number |
| `maxNumberOfTransactionsPerBlock` | decimal string |
| `premine` | decimal string |
| `halfLife` | decimal string |

**Errors**: `404` for a chain this node does not host, or one with no
executed tip.

### `GET /api/chain/genesis`

**Request**: optional `chainPath` query value.

**Response**

| Field | Type | Meaning |
|---|---|---|
| `genesisHash` | string | The genesis CID the node reports as `nexusGenesisCID` in `/health`. |

For a chain's own first block, read `genesisHash` from
[`GET /api/chain/info`](#get-apichaininfo).

**Errors**: `404` for a chain this node does not host.

### `GET /api/peers`

The chain's current peer count: the open sessions that serve it.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `chainPath` | query | Optional. Without it the count is Nexus's, which is every ready session. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `count` | number | The chain's current peers. |
| `peers` | array | Always empty. The node does not list its peers here. |

**Errors**: `404` for a chain this node does not host.

## Accounts

Account reads are the node's own answer, read from state it has verified.
They carry no proof a client could check.

### `GET /api/state/account/:addr`

An account at the chain's current executed tip.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `addr` | path | The account's address. |
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `owner` | string | The address asked for. |
| `balance` | decimal string | Its balance. |
| `nonce` | decimal string | The next nonce the chain expects from it: the nonce its next transaction carries. |

**Errors**: `400` for an address that is not a CID; `404` for a chain this
node does not host, one with no executed tip, or state it cannot read.

### `GET /accounts/:owner`

An account as of one block's post-state.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `owner` | path | The account's address. |
| `block` | query | Required. The CID of a block this node executed. |
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `owner` | string | The address asked for. |
| `block` | string | The block asked for. |
| `balance` | decimal string | The balance in that block's post-state. |
| `nonce` | decimal string | The next expected nonce in that block's post-state. |

**Errors**: `400` when `owner` or `block` is missing or not a CID; `404`
when this node did not execute the block or cannot read its state.

## Blocks

### `GET /api/block/latest`

The tip block's summary.

**Request**: optional `chainPath` query value.

**Response**

| Field | Type | Meaning |
|---|---|---|
| `height` | decimal string | The block's height. |
| `hash` | string | The block's CID. |
| `transactionCount` | number | Transactions in the block. |
| `timestamp` | decimal string | The block's timestamp. |
| `previousBlock` | string, optional | The previous block's CID. |
| `rewardRecipient` | string, optional | The address the header pays. Omitted when the block burns its reward. |
| `rewardCredited` | decimal string, optional | What consensus credited the recipient. See [the block reward](#the-block-reward). |

**Errors**: `404` for a chain this node does not host, or one with no tip.

### `GET /api/block/:height-or-cid`

One block, by its height on the canonical chain or by its CID.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `height-or-cid` | path | A decimal height, or a block CID. A value that parses as a number is a height. |
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `height` | decimal string | The block's height. |
| `hash` | string | The block's CID. |
| `timestamp` | decimal string | The block's timestamp. |
| `previousBlock` | string, optional | The previous block's CID. |
| `transactionCount` | number | Transactions in the block. |
| `childBlockCount` | number | Child blocks the block commits. |
| `nonce` | decimal string | The proof-of-work nonce. |
| `version` | number | The block version. |
| `target` | hex string | The block's target. |
| `nextTarget` | hex string | The target it sets for the next block. |
| `transactionsCID` | string | The root of its transactions. |
| `postStateCID` | string | The root of the state it leaves. |
| `chain` | array of strings | The chain's path. |
| `rewardRecipient` | string, optional | The address the header pays. Omitted when the block burns its reward. |
| `rewardCredited` | decimal string, optional | What consensus credited the recipient. See [the block reward](#the-block-reward). |

A block read by CID is cached as immutable; one read by height is not, since
a reorganization can change which block has that height.

**Errors**: `400` for a value that is neither a height nor a CID; `404` for
a height with no canonical block, or a block this node does not hold.

#### The block reward

`rewardCredited` is the block reward at that height plus the block's fees
(the balance excess of its transactions): `Block.coinbaseAmount`.

- It is `0` for a block that burns its reward.
- It is omitted only when this node does not hold the block's spec or
  transaction bodies.

### `GET /api/blocks`

A page of the canonical chain, newest first, up to the tip this node acts
on.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `before` | query | Optional, exclusive: list blocks below this height. Defaults to the tip plus one, and is clamped to it. |
| `limit` | query | Optional. Defaults to 10; capped at 25. |
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

```json
{"blocks": [{"height": "41", "hash": "<cid>", "previousBlock": "<cid>",
             "timestamp": "<timestamp>", "transactionCount": 3,
             "rewardRecipient": "<address>"}],
 "nextBefore": "41"}
```

| Field | Type | Meaning |
|---|---|---|
| `blocks` | array | One row per block. |
| `blocks[].height` | decimal string | The block's height. |
| `blocks[].hash` | string | The block's CID. |
| `blocks[].previousBlock` | string, optional | The previous block's CID. |
| `blocks[].timestamp` | decimal string | The block's timestamp. |
| `blocks[].transactionCount` | number | Transactions in the block. |
| `blocks[].rewardRecipient` | string, optional | The address the header pays. |
| `nextBefore` | decimal string, optional | The `before` for the next, older page. Omitted once height 0 is listed. |

Rows are read from block headers and the root of each block's transactions,
never a transaction body, so they have no `rewardCredited`; read
[`GET /api/block/:height-or-cid`](#get-apiblockheight-or-cid) for it. At most
`limit` heights are visited, and a height whose block this node does not
hold is left out, so a page can have fewer rows than `limit`.

**Errors**: `400` for a non-numeric `before`, or a non-numeric or
non-positive `limit`; `404` for a chain this node does not host.

### `GET /api/block/:cid/transactions`

A page of a block's transactions, in block order.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `cid` | path | The block's CID. A height is not accepted here. |
| `offset` | query | Optional. Defaults to 0. |
| `limit` | query | Optional. Defaults to 20; capped at 100. |
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `transactions` | array | One summary per transaction. |
| `transactions[].txCID` | string | The transaction's CID. |
| `transactions[].signers` | array of strings | Its signers' addresses. |
| `transactions[].accountActionCount` | number | Account actions it carries. |
| `transactions[].depositActionCount` | number | Deposit actions. |
| `transactions[].receiptActionCount` | number | Receipt actions. |
| `transactions[].withdrawalActionCount` | number | Withdrawal actions. |
| `nextOffset` | number, optional | The `offset` of the next page. Omitted on the last. |

**Errors**: `400` for a value that is not a CID, a negative or non-numeric
`offset`, or a non-positive or non-numeric `limit`; `404` for a block this
node does not hold.

### `GET /api/block/:cid/children`

The child blocks a block commits, one per child directory.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `cid` | path | The block's CID. |
| `limit` | query | Optional. Defaults to 100 and is capped at 100. The first `limit` directories in name order are answered. |
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `children` | array | One entry per child directory. |
| `children[].directory` | string | The child chain's directory name. |
| `children[].blockHash` | string | The child block the parent block commits. |
| `children[].height` | decimal string, optional | The child block's height. |
| `children[].transactionCount` | number, optional | Transactions in the child block. |

`height` and `transactionCount` are omitted when this node does not hold the
child block, which is the case when it does not host that child chain.

**Errors**: `400` for a value that is not a CID or a bad `limit`; `404` for
a block this node does not hold.

## Transactions

### `GET /api/transaction/:cid`

A transaction's signers and actions, and the block that included it. It
answers for any transaction whose content this node holds, pending ones
included.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `cid` | path | The transaction's CID. |
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `txCID` | string | The transaction's CID. |
| `blockHeight` | decimal string, optional | The height of the block that included it. |
| `blockHash` | string, optional | That block's CID. |
| `timestamp` | decimal string, optional | That block's timestamp. |
| `nonce` | decimal string | The transaction's nonce. |
| `signers` | array of strings | Its signers' addresses. |
| `chainPath` | array of strings | The chain the transaction names. |
| `chain` | array of strings | The same path as `chainPath`. |
| `accountActions` | array | `owner` (string), `delta` (decimal string, signed). |
| `depositActions` | array | `nonce` (decimal string), `demander` (string), `amountDemanded`, `amountDeposited` (decimal strings). |
| `receiptActions` | array | `withdrawer` (string), `nonce` (decimal string), `demander` (string), `amountDemanded` (decimal string), `directory` (string). |
| `withdrawalActions` | array | `withdrawer` (string), `nonce` (decimal string), `demander` (string), `amountDemanded`, `amountWithdrawn` (decimal strings). |

The transaction's key-value `actions` are not in this answer. Read them from
[`GET /transactions/:cid`](#get-transactionscid).

**Inclusion.** `blockHeight`, `blockHash` and `timestamp` are present when
the transaction is in this chain's canonical executed chain. They are
omitted when it is pending, was never mined, or was left behind by a
reorganization, and also when this node does not hold the state or block
content needed to tell. Inclusion is reported only when the request selects
the chain the transaction names.

The answer follows reorganizations: it is read from the current canonical
chain each time and cached for 3 seconds, never as immutable. Nothing is
indexed. The node finds the block by searching the canonical post-states
for the first one in which the first signer's next nonce passed the
transaction's (at most about 64 account reads), then confirms that block's
transaction list holds the CID, since a rival transaction at the same nonce
moves the nonce too.

**Errors**: `400` for a value that is not a CID; `404` for a transaction
whose content this node does not hold, or a chain it does not host.

### `GET /transactions/:cid`

A transaction's full content by CID, checked against the CID.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `cid` | path | The transaction's CID. |
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `cid` | string | The CID asked for. |
| `transaction` | object | The transaction, in Lattice's own JSON encoding. |

The response is immutable.

**Errors**: `400` for a value that is not a CID; `404` when this node does
not hold it, or it is not a transaction.

### `GET /api/mempool`

The transactions pending in this node's pool for the chain.

**Request**: optional `chainPath` query value.

**Response**

| Field | Type | Meaning |
|---|---|---|
| `count` | number | Transactions in the pool. |
| `transactions` | array of strings | Their CIDs, at most 200. |

**Errors**: `404` for a chain this node does not host.

## Submitting a transaction

### `POST /transactions`

Submits a signed transaction to the pool of the chain it names.

**Request**

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

| Field | Type | Meaning |
|---|---|---|
| `transaction.signatures` | object | Each signer's public key (hex) to its signature (hex). |
| `transaction.body.accountActions` | array | `owner` (string), `delta` (decimal string, signed). |
| `transaction.body.actions` | array | Key-value state actions: `key` (string), `oldValue`, `newValue` (strings, each optional). |
| `transaction.body.depositActions` | array | `nonce`, `amountDemanded`, `amountDeposited` (decimal strings), `demander` (string). |
| `transaction.body.receiptActions` | array | `withdrawer`, `demander`, `directory` (strings), `nonce`, `amountDemanded` (decimal strings). |
| `transaction.body.withdrawalActions` | array | `withdrawer`, `demander` (strings), `nonce`, `amountDemanded`, `amountWithdrawn` (decimal strings). |
| `transaction.body.signers` | array of strings | The signers' addresses. |
| `transaction.body.nonce` | decimal string | The transaction's nonce: its first signer's next nonce. |
| `transaction.body.chainPath` | array of strings | The chain the transaction is for. |

The body is sent whole, not by reference: the node computes its CID from
it. The request may be at most 1 MiB.

**Response**

```json
{
  "transactionCID": "<cid>",
  "mempoolCount": 4,
  "mempoolBytes": 2600
}
```

| Field | Type | Meaning |
|---|---|---|
| `transactionCID` | string | The transaction's CID. |
| `mempoolCount` | number | Transactions now in that chain's pool. |
| `mempoolBytes` | number | Their size in bytes. |

**What is checked.** The signature, nonce, funding, fee and path are checked
before the transaction is admitted.

- **Size.** A transaction must fit in a block by itself. One larger than
  `maxBlockSize` less 2048 bytes (for the block's own content and the
  transaction's place in it) is `tooLarge`, so a chain whose `maxBlockSize`
  is 2048 or less admits nothing. So is one whose state growth, at most
  (Lattice's `stateGrowthCeiling`), is past `maxStateGrowth` less 128 bytes
  for the coinbase's.
- **Fee.** The fee is the transaction's balance excess, which the block's
  recipient is credited. The pool admits only transactions paying at least
  the operator's `minRelayFee` (default 1); below it the refusal is
  `belowMinRelayFee`. This is the node's relay policy, never consensus: a
  block carrying a cheaper transaction stays valid, and other nodes choose
  their own floor.

**Errors**

A refusal names its reason in the error message. The retriable ones say to
send the same transaction again later; the rest say to change it.

| Reason | Status | Meaning | Retry as is |
|---|---|---|---|
| `nonceAhead` | 400 | An earlier transaction from its first signer is not mined yet. | Yes, once it is |
| `unavailable` | 400 | This node cannot judge it yet (state, a policy module, a withdrawal's receipt). | Yes |
| `insufficientFunds` | 400 | An account it debits cannot also pay what pooled transactions debit it, and displacing them would not put it in the next block and make that block pay the relay floor more. | Yes, once those are mined |
| `full` | 429 | The pool is full of transactions paying a higher rate. | Yes |
| `feeTooLow` | 400 | It shares a nonce, state key, deposit or receipt with pooled transactions, and displacing them would not put it in the next block and make that block pay the relay floor more (uncongested: all their fees plus the floor). | No: raise the fee |
| `belowMinRelayFee` | 400 | Its fee is under this node's floor. | No: raise the fee |
| `tooLarge`, `invalidState` | 400 | It can never be pooled. | No |

Other statuses:

| Status | When |
|---|---|
| `400` | The body is not the JSON above, or an integer is not a canonical decimal string. |
| `404` `unknownChain` | The node does not host `body.chainPath`. |
| `503` `busy` or `shuttingDown` | The node cannot take it now. `busy` carries `Retry-After: 1`. |
| `403`, `415` | Operator API only: a non-loopback `Host`, or no `Content-Type: application/json`. |
| `413`, `429` | Public submit only: see below. |

### Public submit

`POST /transactions` exists on the public read listener only when the
operator turns it on (`"publicSubmit": true` in `lattice.json`, or
`--public-submit`). Otherwise it is `404` there.

When on, it takes the same body and gives the same answer and named refusals
as the operator route. The differences:

| | Operator API | Public read listener |
|---|---|---|
| `Host` and `Content-Type` checks | Required | None. CORS allows `POST` from any origin. |
| Body limit | 1 MiB | 1 MiB, checked before decoding: `413` above it. |
| Rate | Not limited | A submit budget for all clients together (`publicSubmitRate`, default 10 per second): `429` over it. |
| Local journal | Written to it | Never written to it: the transaction is volatile. |
| Pool treatment | The pool's ordinary rules | The pool's ordinary rules (fee-rate eviction and replacement), with no priority over transactions from peers. |

While a public submit waits for its verdict it counts against a bound of its
own, and is refused `full` when that is over. Once admitted it is relayed by
ordinary gossip.

How an operator turns this on is in
[Networking](networking.md#public-submit).

## Fees

### `GET /api/fees`

The next blocks this node's pool would fill if nothing else arrived, for
pricing a fee.

**Request**: optional `chainPath` query value.

**Response**

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

| Field | Type | Meaning |
|---|---|---|
| `minRelayFee` | decimal string | This node's relay floor, as in chain info. |
| `blocks` | array | The projected blocks in order, at most 12. |
| `blocks[].transactionCount` | number | Transactions the block would carry. |
| `blocks[].bytes` | number | Their bytes. |
| `blocks[].lowestFee` | decimal string | The fee of the lowest-rate transaction in the block. |
| `blocks[].lowestFeeBytes` | number | That transaction's size in bytes. |
| `blocks[].lowestFeeWeight` | number, optional | That transaction's weight. |
| `blocks[].full` | boolean | Whether ready transactions were left for a later block. |
| `weight` | object, optional | What a transaction's weight is measured against on this chain. |
| `weight.blockRoom` | number | The block's room for transactions, in bytes. |
| `weight.growthRoom` | number | The block's room for state growth. |
| `weight.maxTransactions` | number | The block's transaction count limit. |
| `weight.transactionAllowance` | number | Bytes charged to each transaction for its place in the block. |

**Choosing a fee**

- While no block is `full`, or `blocks` is empty, a fee at `minRelayFee`
  makes the next block.
- To be in the first `k` blocks when block `k` is full, a transaction of
  weight `w` pays more than `lowestFee * w / lowestFeeWeight` of that block.

**A transaction's weight** is the most of a block it takes of any limit, in
the block's bytes. It is the largest of:

- its size plus `transactionAllowance`;
- its state growth (Lattice's `stateGrowthCeiling`) times
  `blockRoom / growthRoom`, rounded up;
- `blockRoom / maxTransactions`.

Where neither growth nor count binds before size, as on Nexus, weight is the
bytes a block charges the transaction.

**How the projection is made.** The node fills blocks as its own builder
does: pooled transactions by fee per weight, each block taking them up to
the chain's transaction count, `maxBlockSize` (each charged its place in the
block) and `maxStateGrowth` (each charged its state growth at most),
skipping one that does not fit for a smaller one behind it. A block's rate
is the lowest it carries. The projection is recomputed on each new tip and,
while the pool changes, at most once a second.

This is an estimate from one node's pool, not a promise: other miners fill
their blocks otherwise, other pools differ, and new transactions arrive.
Fees above `UInt64` never occur for pooled transactions, which are funded.

**Nodes without `weight`.** A node that omits `weight` and `lowestFeeWeight`
gives rates per byte. A client that prices per byte against a node that
sends them is close where weight tracks size, as on Nexus, and underpays on
a chain whose growth or count binds first.

**Errors**: `404` for a chain this node does not host.

## Deposits and receipts

A deposit is made on a child chain `P/D`. A receipt for it is recorded on
the parent chain `P` and names who withdraws it. These three routes read
that state at the chain's executed tip, and each answer carries a
[state proof](#state-proofs).

### `GET /api/deposits`

A page of a chain's active deposits.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `limit` | query | Optional. Defaults to 100 and is capped at 100. |
| `after` | query | Optional. The `next` of the previous page. |
| `chainPath` | query | Optional. The chain; Nexus when omitted. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `deposits` | array | The active deposits on this page. |
| `deposits[].key` | string | The deposit's key, `demander/amount/nonce`. |
| `deposits[].demander` | string | The demander's address. |
| `deposits[].amountDemanded` | decimal string | The amount demanded. |
| `deposits[].nonce` | decimal string | The deposit's nonce. |
| `deposits[].amountDeposited` | decimal string | The amount still locked. |
| `deposits[].blockHeight` | decimal string, optional | The height of the canonical block that created the deposit. |
| `deposits[].blockHash` | string, optional | That block's CID. |
| `count` | number | The number of entries in `deposits`. |
| `chain` | string | The chain's path, joined with `/`. |
| `next` | string, optional | The `after` for the next page. Omitted on the last. |
| `proof` | object | A [state proof](#state-proofs) of every key on the page. |

- A withdrawn deposit stays in state with the value `0`. It is left out of
  `deposits` but is among the proof's claims, so a page can list fewer than
  `limit` deposits and still have a `next`.
- `blockHeight` and `blockHash` are the node's own report, not covered by
  the proof. They are omitted when the node no longer holds the states
  needed to find the block.

**Errors**: `400` for a bad `limit`; `404` for a chain this node does not
host, or one whose tip state it cannot read.

### `GET /api/deposit-state`

One deposit key: the amount still locked, `0` once withdrawn, or absent.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `key` | query | Required. The deposit's key, `demander/amount/nonce`. |
| `chainPath` | query | Optional. The chain the deposit is on; Nexus when omitted. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `exists` | boolean | Whether the key is in state. |
| `key` | string | The key asked for. |
| `value` | string, optional | The amount still locked, as a decimal string; `0` once withdrawn. Omitted when the key was never deposited. |
| `chain` | string | The chain's path, joined with `/`. |
| `proof` | object | A [state proof](#state-proofs) of the value, or of its absence. |

**Errors**: `400` for a missing or malformed `key`; `404` for a chain this
node does not host, or one whose tip state it cannot read.

### `GET /api/receipt-state`

The withdrawer a receipt on a parent chain records for a deposit on its
child.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `demander` | query | Required. The deposit's demander. |
| `amount` | query | Required. The amount demanded, a decimal integer. |
| `nonce` | query | Required. The deposit's nonce, a decimal integer. |
| `chainPath` | query | Required. The **child** chain the deposit is on, `P/D`. The receipt is read from its parent `P`, which this node must host. |

**Response**

| Field | Type | Meaning |
|---|---|---|
| `exists` | boolean | Whether the parent's state holds the receipt. |
| `withdrawer` | string, optional | The address the receipt names. Omitted when there is no receipt. |
| `directory` | string | The child's directory name, `D`. |
| `chainPath` | array of strings | The child chain's path. |
| `key` | string | The receipt's key, in readable form. |
| `proof` | object | A [state proof](#state-proofs) of the withdrawer, or of the receipt's absence. |

**Errors**: `400` when a parameter is missing or malformed, or `chainPath`
is Nexus; `404` when this node does not host the parent chain or cannot
read its tip state.

### State proofs

A state proof lets a client check a deposit or receipt answer without
trusting the node that gave it, given a block it already trusts.

| Field | Type | Meaning |
|---|---|---|
| `blockHash` | string | The CID of the block whose post-state is proven: the chain's executed tip when the answer was made. |
| `blockHeight` | number | That block's height. A JSON number, unlike other heights. |
| `block` | object | The block node: `cid` (string) and `data` (its bytes, base64). |
| `stateRoot` | string | The CID of the block's post-state. |
| `dictionary` | string | `deposits` or `receipts`: which part of the state is proven. |
| `dictionaryRoot` | string | The CID of that dictionary's root. |
| `claims` | array | What is claimed: each a `key` (string) and its `value` (string, omitted for a key that is absent). |
| `witness` | array | The state nodes the claims are checked through: each a `cid` (string) and `data` (its bytes, base64). |

For a deposit, a claim's value is the locked amount as a decimal string. For
a receipt, it is the withdrawer, and the claim's `key` is the key as the
state stores it, not the readable `key` of the answer.

**Checking a proof**

1. Decode `block.data`. Check that `block.cid` equals `blockHash`, that the
   block's own CID is `blockHash`, that its height is `blockHeight`, and
   that its post-state CID is `stateRoot`.
2. Index `witness` by `cid`; a repeated CID fails. Decode the entry for
   `stateRoot` as the state and check that its CID is `stateRoot`.
3. Check that the state's deposit root (for `deposits`) or receipt root (for
   `receipts`) is `dictionaryRoot`.
4. With no claims, decode the entry for `dictionaryRoot` and check its CID.
   Otherwise, look each claim's `key` up in the dictionary, reading nodes
   only from `witness`, and check that what is found equals the claim's
   `value`, or that nothing is found for a claim without one.
5. Compare the claims with the answer: each listed deposit's key and amount,
   the deposit key's `value`, or the receipt's `withdrawer`.

In Swift, steps 1 to 4 are `LightClientProtocol.verify(_:)` in the
`LatticeNodeAPI` module.

The check ties the claims to the block `blockHash`. It does not show that
the block is on the heaviest chain: the client decides that by other means,
for example by comparing `blockHash` with the tip of nodes it trusts.

## Child chains

### `GET /api/chain/children`

The child directories a chain's executed blocks have committed, in order.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `chainPath` | query | Optional. The parent chain; Nexus when omitted. |
| `limit` | query | Optional. Defaults to 200 and is capped at 200. |
| `after` | query | Optional. List names after this one (any string). |

**Response**

```json
{ "chainPath": ["Nexus", "Alpha"], "directories": ["Beta", "Gamma"], "next": "Gamma" }
```

| Field | Type | Meaning |
|---|---|---|
| `chainPath` | array of strings | The parent chain. |
| `directories` | array of strings | Child directory names. |
| `next` | string, optional | The `after` for the next page. Omitted on the last. |

The node keeps the list in memory: built from the blocks it holds when it
starts, then grown by every block that executes valid. It only grows. A
listed child is reached through its hosts
([`GET /api/chain/endpoints`](#get-apichainendpoints)). A node that answers
the whole list without `next` does not page.

**Errors**: `400` for a bad `limit`; `404` for a chain this node does not
host.

### `GET /api/chain/endpoints`

The read URLs hosts declare for a child chain. The URLs are **not
verified**.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `chainPath` | query | Required. The **child** chain, for example `Nexus/Alpha/Beta`. This node must host its parent (`Nexus/Alpha`). |

**Response**

```json
{
  "chainPath": ["Nexus", "Alpha", "Beta"],
  "committedBlock": "<cid>",
  "endpoints": ["https://reads.example.org"],
  "submitEndpoints": ["https://reads.example.org"]
}
```

| Field | Type | Meaning |
|---|---|---|
| `chainPath` | array of strings | The child chain. |
| `committedBlock` | string, optional | The newest child block the parent's last 64 canonical blocks commit. Omitted when they commit none. |
| `endpoints` | array of strings | Declared read URLs: this node's own first when it hosts the child, then other hosts'. |
| `submitEndpoints` | array of strings | The subset of `endpoints` whose hosts also declare that they accept `POST /transactions` there. |

Using the answer:

- **Check every URL before using it.** A URL may name any host, internal
  addresses included. `GET /api/chain/info?chainPath=...` at the URL names
  the chain it serves, and its `acceptsSubmit` confirms a `submitEndpoints`
  entry. Do not dial a non-public host on a third party's behalf.
- **`committedBlock` is information only.** It can be a block the child
  chain did not keep, or one nobody serves, so do not require a URL to serve
  it.
- A child is found through the hosts that announce it, so it is listed
  whether or not the parent's recent blocks commit it.
- An answer without `submitEndpoints` declares none.

How the node finds the URLs, and the bounds on that lookup, are in
[Networking](networking.md#listing-a-chain-on-an-explorer).

**Errors**: `400` for a missing or malformed path, or `Nexus` itself; `404`
when this node does not host the parent, or when nothing hosts, declares or
commits the child.

## Volumes

A Volume is a unit of content-addressed data named by its root CID: a
block, a transaction, a part of the state. These routes serve Volumes whole,
for a client that walks content-addressed data itself.

### `GET /volumes/:cid`

One complete Volume.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `cid` | path | The Volume's root CID. |
| `chainPath` | query | Optional. The chain whose store is read; Nexus when omitted. |

**Response**: `application/vnd.lattice.volume`, Ivy's canonical
complete-Volume archive (big-endian count and length framing, CID-sorted
entries), at most 64 MiB. The response is immutable.

**A Volume the node does not hold.** The operator API serves only what the
node holds. The public read listener reads a Volume it does not hold from
peers, checks it against its CID, serves it and does not keep it, unless its
operator set `publicReadFetches` to `0`. For the client that means:

- The answer can take a while. A reader waits its turn; it is not refused
  for the queue alone.
- `503` with `Retry-After` means ask again, not "not found".
  `Retry-After: 30` follows a 30-second wait without a turn;
  `Retry-After: 1` means the node had no room for the read.
- `404` means no peer served the Volume within the node's limits.
- An answer read from peers carries `Connection: close` (`200`, `404` and
  `503` alike), and the connection is closed after it. A request pipelined
  behind it on that connection is dropped; send it again on a new one.

How many such reads run at once is the operator's setting
([Networking](networking.md#content-the-node-does-not-hold)).

**Errors**: `400` for a value that is not a CID; `404` and `503` as above.

### `GET /volumes`

Several Volumes in one request, for a client that already knows several
CIDs. The node resolves nothing: it serves only the CIDs named, and only
those it holds.

**Request**

| Parameter | In | Meaning |
|---|---|---|
| `cids` | query | Required. Up to 32 root CIDs, separated by commas. |
| `chainPath` | query | Optional. The chain whose store is read; Nexus when omitted. |

**Response**: `application/vnd.lattice.volumes`. For each requested CID the
node holds as a complete Volume, in request order and once however often it
is named, one record:

```text
u16 BE root CID length | root CID (UTF-8) | u32 BE archive length | archive
```

The archive is exactly what `GET /volumes/:cid` serves.

- A CID the node does not hold is left out. It is never read from peers
  here; read it with `GET /volumes/:cid`.
- The body is at most 4 MiB, one protocol frame. The first record that would
  take it past that ends the body, and every CID after it is left out
  unread. A single archive over 4 MiB is therefore never in the body, and
  never truncated.
- When every requested CID is in the body the response is immutable.
  Otherwise it is cached for 3 seconds, since the node may hold more later.

**Errors**: `400` for no `cids`, more than 32, or any that is not a CID.
