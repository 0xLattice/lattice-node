# HTTP API: mining routes

The three routes a miner uses: request work, learn when to request it again,
and submit a nonce. To run the miner that ships with the node, see
[Mining](mining.md); this page is for someone writing or debugging a client
of these routes.

The miner is a separate process and a client of these routes
(`lattice mine run`, or `lattice-mining-coordinator`). The node runs no
miner and keeps no mining settings: each template request carries its
recipients.

The routes are on the operator API and the remote operator listener, never
on the public read listener ([HTTP API](rpc-api.md#listeners)). On the
remote listener a miner's token needs only `POST /mining/templates`,
`POST /mining/work` and `GET /status`, which the coordinator probes for
freshness. Add `GET /mining/events` for a client that reads the stream.

These routes are the miner's protocol and do not follow the API's
[integer encoding](rpc-api.md#integers): `block` is the consensus block's
own encoding, and a submission's `nonce` is a JSON number.

## One round

1. Request work with [`POST /mining/templates`](#post-miningtemplates).
2. Search nonces for a hash at or below `searchTarget`
   ([External mining workers](mining-workers.md)).
3. Submit a nonce that clears it with
   [`POST /mining/work`](#post-miningwork).
4. Request new work when the digest on
   [`GET /mining/events`](#get-miningevents) changes, or when
   `templateDigest` in [`GET /status`](api-operator.md#get-status) differs
   from the template's.

## `POST /mining/templates`

Builds and issues work: a Nexus block candidate that carries a candidate for
every hosted chain below it.

**Request**

```json
{
  "recipients": [
    {"chainPath": ["Nexus"], "address": "<address>"},
    {"chainPath": ["Nexus", "Alpha"], "address": "<address>"}
  ],
  "minimumWork": [
    {"chainPath": ["Nexus"], "work": "0x100000000"}
  ],
  "exclude": [
    ["Nexus", "Beta"]
  ]
}
```

| Field | Type | Meaning |
|---|---|---|
| `recipients` | array, optional | Where each chain's reward and fees go: `chainPath` (array of strings, absolute) and `address` (string). A chain with no entry burns its payout. |
| `minimumWork` | array, optional | The miner's own minimum work per block for a chain: `chainPath` and `work` (hex string). |
| `exclude` | array of paths, optional | Hosted chains whose next block this template leaves out, each an absolute path below the template's own chain. |

A body with a `rewards` or `mode` field is refused with `400`.

**`recipients`.** Each block commits its recipient in its proof-of-work
preimage, so a relayer cannot swap it.

**`minimumWork`** is a search filter local to the miner. It can demand
harder hashes than the scheduled target. It cannot make consensus easier,
and it is not committed as the chain's target. A filter binds only chains
the template builds: a chain a block carries only by a pool transaction's
`child/X` commitment (by CID, not hosted here) does not limit the search.

**`exclude`.** No nonce for the work makes a block on an excluded chain, and
its threshold is in neither `searchTarget` nor `targets`.

- A block carries its descendants. Excluding a chain while a hosted chain
  below it is left in is refused (`excludedAncestor`); exclude the whole
  subtree instead.
- `excludedAncestor` is judged against the chains hosted when the request
  arrives. A child newly hosted under an excluded chain makes the same
  request a `400` until the miner adds it to `exclude`.
- An entry that is not below the template's chain, or repeats one, is
  refused (`invalidExclusion`).
- Excluding a chain this node does not host changes nothing.
- A carried chain's ancestors are carried too, and a hash that clears a due
  chain also makes a block on any ancestor whose target is easier. The hash
  is shared, so only the ancestors' difficulty schedule corrects that.
- Without the field every hosted chain is carried. A node that does not
  know the field ignores it, so a miner relying on it checks that no
  excluded path is in the response's `chains`, and treats a response without
  `chains` as not supporting `exclude`.

**Response**

| Field | Type | Meaning |
|---|---|---|
| `workID` | string | An opaque identifier for this work. |
| `block` | object | The complete Nexus candidate with nonce zero, carrying the child candidates, in the consensus block's own encoding. |
| `searchTarget` | hex string | The easiest threshold that can advance at least one carried chain, within the request's `minimumWork`. Excluded chains do not count. |
| `targets` | array of hex strings | Every target this work can clear, easiest first; `searchTarget` leads. |
| `chainPath` | array of strings | `["Nexus"]`. |
| `expiresInMilliseconds` | number | Always 30000. It is kept for clients that require the field and is not a validity bound. |
| `templateDigest` | string | A fingerprint of the whole hosted tree's template inputs. |
| `chains` | array, optional | Every block a nonce for this work commits, the root first. |
| `chains[].chainPath` | array of strings | The block's chain. |
| `chains[].target` | hex string | The target the block commits. |
| `chains[].height` | decimal string | The block's height. |
| `chains[].rewardRecipient` | string, optional | The address it pays. Omitted when it burns its reward. |

A hash makes a block on a chain in `chains` only when it clears both
`searchTarget` and that block's `target`.

**The digest.** A change to what the next block at any hosted chain would
carry, or a new candidate, changes `templateDigest`, even if the Nexus tip
did not move. It is the digest `GET /status` and `GET /mining/events` carry.

**How long work lasts.** Issued work never expires on a clock: proof-of-work
arrivals are memoryless, so the time spent on a template says nothing about
when the next tip comes. The tip moving does not retire it either. Work on
an old tip is still work on that tip, and a solution for it is accepted as a
side block (`acceptedSide`), as Bitcoin's `submitblock` checks no tip. The
node keeps the last 512 templates it issued and drops the least recently
issued first.

**Errors**

A request is never refused because the tip moved while its template was
built. It is answered with the template the build produced, on the tip the
build read, and the digest change that follows the move sends the miner
back for work on the new tip.

| Status | Reason | Meaning |
|---|---|---|
| `400` | `invalidRecipientPlan`, `invalidMinimumWork`, `minimumWorkPlanTooLarge` | The request's `recipients` or `minimumWork` does not check. |
| `400` | `invalidExclusion`, `excludedAncestor` | See `exclude` above. |
| `400` | `buildFailed` | The node could not build a block on the tip. |
| `503` | `busy` | Too many requests are waiting on builds. |
| `503` | `executing` | The chain has a backlog of blocks to execute: it is syncing, and has no template until it has executed them. |

## `GET /mining/events`

A stream that says when to request new work.

**Request**: no parameters.

**Response**: `text/event-stream`. The current template digest at once, then
each new digest as it changes.

```
data: 3f2a...

: keepalive
```

- The digest changes when a hosted chain's acted-on tip moves, when what any
  hosted chain's next block would carry changes, and when the hosted chains
  change.
- A client requests a template when it sees a new digest. Work it already
  holds stays submittable; a solution on an old tip is a side block.
- A client that reads slowly skips to the latest digest. The node holds only
  the newest one for it, never a queue.
- A comment line `: keepalive` every 15 seconds only shows the connection is
  alive. A quiet chain sends nothing else.
- The stream closes when the node stops. Losing it says nothing about the
  chain.

## `POST /mining/work`

Submits a nonce for issued work.

**Request**

```json
{"workID": "<opaque work id>", "nonce": 123456}
```

| Field | Type | Meaning |
|---|---|---|
| `workID` | string | The `workID` of a template. |
| `nonce` | number | The nonce found, an unsigned 64-bit integer as a JSON number. |

**Response**

```json
{
  "accepted": true,
  "disposition": "canonicalized",
  "tipCID": "<cid>"
}
```

| Field | Type | Meaning |
|---|---|---|
| `accepted` | boolean | `true` when `disposition` is `canonicalized` or `acceptedSide`. |
| `disposition` | string | What became of it; see below. |
| `tipCID` | string, optional | The tip after the block executed (`canonicalized`); otherwise the tip Nexus acts on. |

| `disposition` | Meaning |
|---|---|
| `canonicalized` | The block was executed on the chain the node acts on. |
| `acceptedSide` | The block was accepted as a side block: it builds on a tip the node no longer acts on. |
| `childOnly` | The hash missed Nexus's target but met at least one carried child's. The node stores only the child blocks that hash secures. |
| `duplicate` | The node already has this block. |
| `invalid` | The block was refused or did not validate. |

The reply is sent after the resulting step is durable: every affected
chain's facts and stream cursors commit in one `state.db` transaction.

**Errors**

| Status | Reason | Meaning |
|---|---|---|
| `400` | `unknownWork` | The node does not hold a template with this `workID`. |
| `400` | `missesSearchTarget` | The nonce's hash does not clear the template's `searchTarget`. |
| `400` | `invalidWorkID` | The `workID` is empty or too long. |
| `503` | `shuttingDown` | The node is stopping. |
