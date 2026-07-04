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

On mainnet, Nexus has no miner and its height is frozen. A child still advances on its **own**
proof-of-work, anchored to the frozen Nexus tip — this is by design, not a stall.

## Serving node

Run a Nexus node that hosts the child from the genesis, with a **reachable, historical**
configuration:

- `--storage-mode historical --block-retention historical` — serve all blocks + genesis content.
- `--external-address <public-ip>:<port>` — advertise a reachable address (this also enables
  `--relay`, letting NAT'd miners connect through it). Without it the node advertises loopback.
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
  --use-relay <backbone-p2p> --no-dns-seeds
```

- **`--use-relay <peer>` is required for a NAT'd miner** (home/laptop/cloud). A direct dial to a
  serving node behind a cloud proxy fails; the child reaches it through a public relay (any
  backbone node run with `--external-address`). Discovery still happens via `getChildPeers`; the
  relay only provides transport.
- No `--peer` — `getChildPeers` finds the serving node.

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
  Difficulty is Bitcoin-aligned with no recovery mechanism — the answer is enough hashrate (or a
  calibrated genesis target), not a difficulty override.
- **Stale miner state.** If a miner's reconciler is confused (a child appears in `chain/map` but
  has no process), wipe the miner's data directory and start clean.
- **macOS.** Port 8080 is taken by AirPlay Receiver — use another RPC port. Build with
  `xcrun swift build` so the compiler matches the 6.3 SDK. Detach with `( nohup … & )`.
