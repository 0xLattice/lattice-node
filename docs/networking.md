# Networking

What a node listens on, how it finds peers, and how to serve the public.
The keys named here are described in [Configuration](configuration.md).

## Ports

| Surface | Default | Expose it? |
|---|---:|---|
| Overlay | `4001/tcp` | Yes, to accept inbound peers. |
| Browser peers | `4002/tcp` and `4002/udp` | Yes, to accept browsers. `webSocket: 0` turns it off. |
| Operator API | `8080/tcp` | Never. It binds loopback only; the node refuses other addresses. |
| Remote operator listener | off | Private network only, or behind a TLS proxy: it is plain HTTP. |
| Public reads | off | Yes, once configured. |

One overlay port serves every chain the node hosts. There is no port per
chain.

Set `externalAddress` when the address other nodes observe is not one they
can dial, as behind a proxy.

## How a node finds peers

Every node hosts Nexus, so every open session is a Nexus peer. A child
chain's peers are the sessions whose peer says it hosts that chain. One
connection to a peer serves every chain that peer hosts.

On each maintenance pass, each hosted chain in turn, Nexus first:

1. **Counts its current peers.**
2. **Dials peers it remembers** for that chain, up to four, while it has
   fewer than eight current peers (`--peer-target`) or has stopped
   progressing.
3. **Discovers.** A child chain with no current peer, or one that has stopped
   progressing, asks its parent's peers who hosts it and dials up to four of
   them. With fewer than eight current peers it does the same at most once
   per `--peer-search-interval`.
4. **Dials its seeds**, only while it has fewer than two current peers
   (`--peers-before-seeds`). Nexus's seeds are the built-in ones. A child's
   seeds are the list its operator gave it, if any.

A chain that already knows its network rejoins through the peers it
remembers and never asks a seed. Left with fewer than two Nexus peers, the
node looks again within seconds.

"Stopped progressing" is judged from the locally verified tip, never from a
height a peer claims.

### Seeds

Nexus's built-in seeds, tried by name and then at a fixed address in case
names cannot be resolved:

| Name | Fixed address | Identity (public key) |
|---|---|---|
| `seed1.lattice.build:4001` | `137.66.36.149` | `139b8f36…7995fe64` |
| `seed2.lattice.build:4001` | `137.66.14.188` | `35edf67b…5be6eb7d` |
| `seed3.lattice.build:4001` | `137.66.16.78` | `9cace839…065acd4e` |
| `seed4.lattice.build:4001` | `169.155.61.57` | `57f80deb…7bb22d0f` |

A seed is accepted by its key, so whoever answers at a seed's name or
address without the pinned key is refused. A fixed address is the host's
address at release time; a stale one costs a failed dial and nothing else.

To use your own peers instead, set Nexus's `peers` list
([Configuration](configuration.md#peers)).

### Remembered peers

A node keeps the peers it has reached in `peers.json`, in its data directory:
one book per hosted chain.

- Only an address the node dialled itself and reached the peer at is kept.
  Never one merely heard about, and never the address a peer advertises for
  itself.
- A peer is in the book of each chain it said it hosts. That claim decides
  whom to dial, never what to accept: content is verified the same whoever
  sent it.
- Per chain: one address per identity, at most 256, at most 8 per network
  group, none unseen for 30 days, none that refused ten dials in a row.
- A remembered peer is dialled like any discovered peer and accepted only by
  its key.
- Configured peers and the node's own identity are not written to it. A seed
  the node reached is.
- A node configured with `"peers": []` neither reads nor writes it.
- The book of a chain the node no longer hosts is dropped at the next start.

The file is advisory. Deleting it costs only the next start's head start,
and a damaged one is ignored.

### Announcements

A node tells its peers which child chains it hosts in two ways:

- **In its session hello** (`host:<path>`), sent again on open sessions when
  it starts or stops hosting a chain.
- **As a provider record** per hosted child chain, under the chain's
  rendezvous key `lattice.chain-peers.v1:<nexus genesis>:<path>`.

The rendezvous is keyed by path, not genesis, so a joiner can search before
it holds any of the chain's blocks. A record says that a node hosts a chain,
not that it holds any particular block or state.

Each announcement lasts `announceLifetime` seconds (default 1200). The node
renews about every 10 minutes, and only the records that would otherwise
lapse within a turn and a half. Keep the lifetime at two and a half turns or
more: one near a single turn leaves gaps in which peers cannot find the node.

A node that loses every session announces everything again when the next one
opens. A chain it stops hosting, or a Volume it unpins, stops being
announced; records peers already hold lapse at their expiry.

`--provider-walk-sessions` (default 64) bounds the sessions these walks may
open. With `0` the node announces only to peers already connected, on every
turn and whenever a session opens.

### Whom a node asks for content

A child chain's blocks and Volumes are asked first of the peers that host
that chain, then of the others. A Nexus Volume goes to any peer, since every
peer hosts Nexus. A peer's claim to host a chain is only a hint for whom to
ask: a peer that has no answer costs one round trip, one that stays silent
costs a request timeout and is asked last afterwards, and no peer is refused
service for what it announced.

## Nodes behind NATs

A node that accepts no inbound connections, as one behind a home router does
not, still connects to other such nodes. Nothing is configured, and nothing
is opened on the router.

When it cannot dial a peer, it asks a connected peer that relays (every node
that listens for browsers) for a route. The two nodes tell each other where
they are and connect at the same moment, so each one's first packet opens its
own router for the other's. The session that results is direct, and the
relaying peer carries nothing more for the pair.

- This works where the router keeps a connection's port, which most home
  routers do. Otherwise the pair keeps the relayed session.
- A direct connection is tried once per relayed session, by each end.
- A node learns its public address from `externalAddress`, or from the STUN
  servers its overlay asks at start.
- A relaying node carries at most 64 routes, 8 asked by any one peer, and
  lets a route go once it is idle.

## Browser peers

A browser cannot open the overlay's TCP connection, so it reaches a node
over WebSocket at `ws://<host>:4002/ivy`. Two browsers meet through a node
both reach, which relays between them, and then connect to each other
directly. To do that each asks the node for its own public address, by STUN
on the same port over UDP. No other server is involved.

- **Open the port for both TCP and UDP.** A node that listens here relays
  between its peers: signalling only when the two then connect directly, and
  their traffic when they cannot.
- **A second node on one machine needs a port of its own.** Left unset, the
  node listens on 4002 if it can and starts without the listener if it
  cannot, saying so on standard error.
- **There is no TLS in the node**, and a page served over `https` may only
  open `wss`. Terminate TLS in a proxy in front. STUN does not pass through
  that proxy: forward UDP on the port browsers dial to the node's port.
- **Declare the URL browsers dial** with `webSocketURL`, for example
  `wss://node.example.org/ivy`. The node tells its peers, so a browser that
  finds this node under a chain's rendezvous can dial it. Without one, the
  node advertises up to four connected peers that relay and declare a URL.

## Public reads

`publicRead` opens a second listener on all interfaces that serves only the
bounded GET read routes ([HTTP API](rpc-api.md#read-routes)). It never serves
operator status, metrics or mining routes.

```json
{ "listen": 4001, "rpc": 8080, "publicRead": 8081 }
```

Select a child chain with `?chainPath=Nexus/Alpha`. An unknown or unhosted
path is 404.

- **Rate limits are listener-wide.** `publicReadMaxRate` (200 requests per
  second) covers all clients together. Per-client limits belong in a proxy in
  front; set the node's limit to `0` only behind one.
- **A proxy in front must allow no more than the listener does**: never
  `/status`, `/metrics`, `/core/snapshot` or any POST route other than public
  submit.
- **Content the node does not hold is read from peers** for the reader, at
  most `publicReadFetches` Volumes at once. Further readers wait in arrival
  order, and readers of the same Volume share one read. A reader still
  waiting after 30 seconds gets 503 with `Retry-After`.

### Listing a chain on an explorer

Anyone can make a chain they run readable on a public explorer such as
lattice.build, at any depth, without asking anyone:

1. Run a node that hosts the chain.
2. Expose that node's public reads at an `https` URL (`publicRead` behind a
   TLS terminator).
3. Declare the URL: `"publicReadURL": "https://reads.example.org"`. One URL
   per host covers every chain the host serves.

Check it from the parent's side:

```bash
curl -s 'https://<parent-reads>/api/chain/endpoints?chainPath=Nexus/Alpha' | jq
curl -s 'https://reads.example.org/api/chain/info?chainPath=Nexus/Alpha' | jq .chain
```

How it works: a node that hosts the parent of `Nexus/Alpha` answers
`GET /api/chain/endpoints?chainPath=Nexus/Alpha` by finding the hosts that
announced the chain and asking a bounded number of them for their declared
URL. The URLs come back unverified, and a reader checks what each serves. An
explorer starts from its Nexus nodes and repeats this step per level, so a
chain appears once a node hosting its parent can reach a declaring host.

### Public submit

Whether a node accepts transactions from the public is its operator's
choice, off by default. Turn it on with `"publicSubmit": true` (needs
`publicRead`). The read listener then also accepts `POST /transactions` for
every hosted chain, with the same answers as the operator route
([HTTP API](rpc-api.md#public-submit)).

- **One pool policy for every source.** A public submit is admitted under
  the same fee, replacement and eviction rules as a transaction from a peer.
  It cannot displace the operator's own transactions except by paying a
  better fee rate.
- **Its own rate budget.** `publicSubmitRate` (10 per second, all clients
  together) is separate from the read budget.
- **It is advertised.** With `publicReadURL` declared, the host is listed in
  `submitEndpoints` of `GET /api/chain/endpoints`, and
  `GET /api/chain/info` reports `acceptsSubmit`.

## Serving standing

Serving content to peers is free while a slot is free. Under contention,
waiting requests share freed slots by weight, and a peer's weight grows with
its standing:

- bytes the operator credited it, plus
- verified content it served this node, less
- Volume bytes this node served it.

Standing is never below zero, does not decay and is not capped.

The operator credits standing with `POST /serving-credit` on the operator
API ([HTTP API](rpc-api.md#serving-standing)), by hand or through a sponsor
such as lattice-sponsor.

Standings are kept in `serving.json` in the data directory. A crash loses
only the changes since the last write, never a credit. Carry the file with
the data directory when moving a node. A file there that cannot be read
stops the node from starting.
