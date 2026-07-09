# Running a live child chain

How to bring a child chain (e.g. `Nexus/toy`) to **live, rewarding, and browsable** state: a
public node that serves it and a miner node that advances it.

## The one requirement that matters most

**A chain needs at least one reachable node serving ALL of its historical data — every block
*and* the genesis content (not just the anchored genesis CID).**

Everything below assumes this. Follow, source-agnostic sync, and peer discovery all depend on
being able to *fetch* the data from somewhere. If no reachable node serves the genesis content,
a fresh follower resolves the genesis to `notFound` and can never spawn the child. So before
touching a miner, verify a cacheless node can fetch the genesis CID and every block from your
serving node. Run the serving node with `--storage-mode historical --block-retention historical`
and confirm it is reachable.

## Topology

Every participant is a **Nexus node plus a child process** — never a standalone child-only node
(a single identity doing both the parent-subscription link and chain-gossip flaps under
duplicate-identity eviction). Two roles:

- **Serving node** — public, browsable, historical. Runs the child from its anchored genesis.
- **Miner node** — supplies the hashrate (GPU/Metal), syncs the child from the serving node, and
  mines it forward.

On mainnet, Nexus's own (hard) PoW target is rarely cleared, so its canonical height advances
slowly or not at all for long stretches — Nexus is a **fixed PoW root, not permanently frozen**,
and it advances the moment any hash clears its hard target. A child still advances on its **own**
(easy) target: each grind that clears the child's target but *not* Nexus's produces a **child-only
carrier** — a root-shaped block that never becomes a canonical Nexus block but still commits the
child block via a self-contained `ChildBlockProof`. A follower accepts these carriers by the
child-proof predicate (`childTarget >= carrierHash` + proof + parent-state anchor), *independent*
of whether the carrier ever became canonical Nexus, and a child-only carrier contributes **zero**
inherited Nexus-level weight (it secures the child; it does not add root work). So the child keeps
advancing while Nexus's height stands still — this is by design, not a stall, and a follower must
**not** gate a direct child's carrier on standalone Nexus PoW.

## Serving node

Run a Nexus node that hosts the child from the genesis, with a **reachable, historical**
configuration:

- `--storage-mode historical --block-retention historical` — serve all blocks + genesis content.
- `--external-address <public-ip>:<port>` — advertise a reachable address (this also makes the
  node serve as a resource-capped circuit relay, like every public node). Without it the node
  advertises loopback.
- The child process must advertise its **own** reachable chain-gossip address and expose its p2p
  port, or remote miners can only reach it over a relay.
- Set `--coinbase-address` on both the Nexus node and the child so mined blocks pay out.

## Miner node

Run a Nexus node, then start the child process. Prefer booting the child **from its
genesis-hex** rather than a network `follow`, because follow *fetches* the genesis and will fail
if the availability requirement above isn't met:

```
lattice-node node \
  --genesis-hex "$(cat <chain>-genesis.hex)" \
  --chain-directory <dir> --chain-path Nexus/<dir> \
  --subscribe-p2p <local-nexus-p2p> \
  --port <p2p> --rpc-port <rpc> --data-dir <dir> \
  --min-peer-key-bits 16 --coinbase-address <addr> \
  --no-dns-seeds
```

- No `--peer` — `getChildPeers` finds the serving node.
- No `--use-relay` — see below: a NAT'd miner talking to a *public* serving node needs no relay.

### NAT: outbound-first, relays as an automatic assist

- **A NAT'd miner participates fully with no relay.** Everything it needs flows over the
  connections it dials OUT — to the serving node and to peers discovered via `getChildPeers`:
  newly mined blocks are push-gossiped over those outbound connections, and sync/fetch runs
  over them too. The common producer → public-follower topology requires no `--use-relay`
  (regression-proven by `SmokeTests/scenarios/network/outbound-push-no-relay.mjs`, which mines
  on a producer whose every advertised address is undialable and asserts a public follower
  still tracks its tip).
- **Relays cover relay-only reachability (NAT-to-NAT).** Only when *neither* side can accept an
  inbound dial does traffic bridge through a circuit relay. Every public node
  (`--external-address`) serves as a resource-capped relay automatically, and relay carriers
  are drawn from the peer set — the p2p layer prefers carriers in distinct network groups and
  fails over between them; a relay is never a designated backbone. `--use-relay <peer>` is
  only an OPTIONAL bootstrap hint (a seed carrier for a node booting with an empty peer set) —
  it is not required, and any connected public peer serves the same role.
- **Trust model: relays are availability-only.** Relayed frames are integrity- and
  identity-protected end to end: blocks and content are content-addressed (a relay cannot
  alter bytes without changing the CID), peer identity is bound by the signed identify
  handshake + key proof-of-work, and block validity is PoW-verified by the receiver. Relay
  traffic is **not encrypted**, though — a relay sees plaintext frames. Trust a relay for
  availability only (it can drop or delay), never for confidentiality or correctness.
- **Hole-punching tripwire.** Direct-upgrade of relayed connections (DCUtR-style hole
  punching) is deliberately deferred: today's NAT-to-NAT population doesn't justify it.
  Revisit when NAT-to-NAT relayed traffic approaches a meaningful fraction of a public
  relay's aggregate byte-rate cap — relays cap total relayed egress per window, so sustained
  growth toward that cap is the signal that long-lived circuits need a direct upgrade path.

Then mine both chains with one coordinator:

```
lattice-mining-coordinator \
  --node <nexus-rpc> --rpc-cookie-file <nexus>/.cookie \
  --child-node <child-rpc> --child-rpc-cookie-file <child>/.cookie \
  --worker-executable <pow-worker> --workers 1 --batch-size 2000000000
```

## Verify

- **Live:** `GET /api/block/latest?chainPath=Nexus/<dir>` — height climbing, tip age under a few
  minutes.
- **Rewarding:** a block with `prevStateCID != postStateCID` (the coinbase credit changed state)
  — even an otherwise-empty block should differ once a coinbase is claimed.
- **Browsable:** the serving node answers `?chainPath=Nexus/<dir>` for block/genesis routes, and
  the explorer resolves + genesis-verifies its endpoint.

## Gotchas

- **Divergent / stale data.** A serving node that hosts blocks produced by an *older* build makes
  a newer follower reject every header (`allCandidatesServedInvalid`, sync stops). Keep the
  serving node on the current build; if its chain is stale, re-establish it fresh.
- **A weak miner can't hold the difficulty.** A max-target genesis mints the first blocks freely,
  then difficulty retargets up. If the miner's hashrate can't sustain it, the chain goes stale.
  Difficulty is Bitcoin-aligned: the windowed retarget is the only adjustment (it does climb back
  down as blocks slow — see protocol.md §2.3), and there is deliberately **no emergency/wall-clock
  override**. So the answer to a stalled chain is enough hashrate (or a calibrated genesis target),
  not a difficulty override.
- **Stale miner state.** If a miner's reconciler is confused (a child appears in `chain/map` but
  has no process), wipe the miner's data directory and start clean.
- **macOS.** Port 8080 is taken by AirPlay Receiver — use another RPC port. Build with
  `xcrun swift build` so the compiler matches the 6.3 SDK. Detach with `( nohup … & )`.
