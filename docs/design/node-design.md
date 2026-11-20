# Lattice node: what it is for, how it is built, and where it goes next

> **Status: proposed.** What the node is for, how it is built, how that
> compares with other clients, and what to do next, in one document. It
> describes `main` after the write-behind persistence layer (#135–#147) was
> reverted (#156, #157), verified against the code by four independent
> reads with the load-bearing claims checked by hand, and revised after an
> external architecture review. Where the code and this document disagree,
> the code is right. The rules a change is reviewed against stay in
> [sync architecture](sync-architecture.md) and the
> [PR checklist](../pr-checklist.md).
>
> Every external figure is cited. A project's own benchmark, or a third
> party's, is marked as a claim. Where nothing comparable is published, this
> document says so. Targets marked **Owner to set** need a number.
>
> Paths are under `Sources/`. `RT` is `LatticeNode/Runtime/NodeRuntime.swift`,
> `API` is `NodeRuntime+API.swift`, `NSE` is `NodeStorage+RuntimeEffects.swift`.

## Contents

1. What the node is for
2. Where it stands today
3. The architecture at a glance
4. The parts, one by one
5. How easy it is to change
6. What to do next
7. How a change is judged
8. Sources

---

## 1. What the node is for

A Lattice node follows every chain it hosts to the network's heaviest chain,
executes it, and serves what it holds to peers, miners, operators and
readers. The network's chain is the truth; a node holds a checked view of it.

Lattice is a hierarchy of chains, not one chain
([specification §1](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/spec.md)):
each child is secured by work it inherits from its parent, keeps its own
fork choice, and is hosted only by the nodes that opt into it
([philosophy](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/philosophy.md)).
So most outcomes are measured **per chain path**: a node can be at the tip of
Nexus while a child three levels down has stopped.

### Outcomes, in order

When two conflict, the earlier one wins.

1. **Agreement.** The node reaches the same verdicts and tips as the
   protocol's rules, and keeps the transfer protocol's guarantees: no value
   created, no double withdrawal, no forged parent state (spec §8.3).
2. **Liveness at every depth.** Every hosted chain stays at the network's
   heaviest tip, and a node that falls behind catches up. Unavailable is never
   invalid; every wait has a reason and a wake. A stall is a bug.
3. **Security of each chain.** Blocks reach the network fast enough that few
   go stale, and each child keeps the share of parent work its security rests
   on ([merged-mining security](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/economics/merged-mining-security.md)).
4. **Promises kept.** What the node tells an operator or a miner it has kept
   outlives a crash and a power loss: an acknowledged transaction, a pin, the
   configuration, a block it said it accepted.
5. **Compatibility.** This version and the previous one stay on one network:
   wire changes are additions, and older peers are still served. Storage may
   change; a node the team runs may be wiped and synced again.
6. **Easy to understand and to change.** Each concern lives in one place,
   behind one interface, in a shape an established client would recognise; a
   change to one concern does not cross others, and its correctness does not
   rest on rules every caller must remember. The node will keep changing; what
   each change costs decides how fast every other outcome improves.
7. **Cost to verify.** Running a node, and hosting one more chain, stays cheap
   enough that many can: CPU, memory, disk, bandwidth. Deeper paths cost more
   by design; whoever opts in pays.
8. **Cross-chain transfers complete.** A deposit, its receipt and its
   withdrawal go through, in a time a user can plan around.
9. **Content stays available.** What a hosted chain needs can be had from its
   hosts.
10. **Mining is served promptly.** Templates and submitted work are answered
    fast, and little work is spent on stale templates.

Sync throughput is not an outcome. It matters only through time to tip
(outcome 2) and is capped per chain by the protocol.

### Measures and targets

Measured on Linux, as the nodes run. "Network" rows need observations of the
live network; "node" rows come from a node's own `/status` and `/metrics`, or
from the sync benchmark (`Benchmarks/sync`).

| Outcome | Measure | Where from | Target | Today |
|---|---|---|---|---|
| 1 Agreement | Divergences when replaying a real chain, in mixed-version runs, in the simulator | tests | Zero | Zero in CI; no replay of a real chain |
| 2 Liveness | Acted-on height against best header height, per chain path, over time | node | **Owner to set** (for example, at the best header 99% of the time) | Reported once `node/liveness-status` lands (see §4.4) |
| 2 Liveness | Stalls: a chain behind its best header whose tip has not moved for longer than a threshold | node | Zero | A production node stopped at height 3,920, unexplained |
| 2 Liveness | Time to tip from empty, and from a restart, per chain path | benchmark, node | **Owner to set** | 9,086 blocks over four chains in about 74 s, one worker, 4-CPU Linux runner |
| 3 Security | Time for a block to reach most hosts, per chain | network | **Owner to set** | Not measured |
| 3 Security | Share of blocks that go stale, per chain | network | **Owner to set** | Not measured |
| 3 Security | For each child, the share of parent hash rate whose templates commit it | network | **Owner to set** | Not measured |
| 4 Promises | Acknowledged transactions or accepted blocks lost after a crash or power loss | tests | Zero | Zero in tests |
| 5 Compatibility | Partitions or refused messages between this version and the previous | two-version runs | Zero | Zero in CI |
| 6 Change | Layers a change to each concern crosses | code | One for each | Most cross one; state retention crosses three; identifiers are in 32 files (§5) |
| 6 Change | Rules a caller must keep that the code does not enforce | code, review | Zero beyond the write order | Zero for writes |
| 6 Change | Components with no conventional equivalent, each with its reason | this document | Each justified in writing | Two (§5) |
| 6 Change | Review rounds per change; repeated holes of one kind | review | A second round of the same kind stops the change | The write-behind layer took four rounds of ordering holes |
| 6 Change | The largest files, where unrelated changes meet | code | **Owner to set** | The loop, 2,223 lines; the daemon's command file, 1,741 |
| 7 Cost | CPU, peak memory, disk kept, disk written, bandwidth; root alone and per extra chain | benchmark, node | **Owner to set** (the root on one CPU) | About 4.4 ms CPU per block, 190 MiB, 90 MB kept, 2.9 GB written per benchmark sync; per-chain cost not measured |
| 8 Transfers | Time from deposit to withdrawal on a parent–child pair; share that complete | network, tests | **Owner to set** | Not measured |
| 9 Availability | Content requests served; how long a body stays unavailable; hosts per chain | node, network | **Owner to set** | Not measured |
| 10 Mining | Time to answer a template request and a submission; share of work on stale templates | node | **Owner to set** | Not measured |

---

## 2. Where it stands today

### Measured

| Measure | Value | Where |
|---|---|---|
| Sync, one worker | about 123 blocks/s (73.6–73.9 s for 9,086 blocks) | Linux, GitHub runner, 4 CPUs; code before #137, which this branch restores |
| Sync, three workers | about 155 blocks/s | same |
| Sync, one CPU | about 84–87 blocks/s (104.1–108.2 s) | Linux, follower pinned to one CPU, server on the other three; code before #137 |
| Sync, one worker, this branch | 25–26 s for 9,086 blocks | macOS, 14 cores (an fsync there does not reach the device) |
| CPU per block | about 4.4 ms | macOS, one worker |
| Written per sync | about 2.9 GB to keep about 90 MB | Linux |
| Peak memory | about 190 MiB | both |

**Is the old throughput target met?** Yes, pinned to one CPU: about 84–87
blocks/s against a target of 50–100 — inside the range, not far above it.
Unpinned runs used more than one core (104 s of CPU in 74 s), which is why
they read higher. Pinned to one CPU, the removed write-behind layer was
about 2% faster (103.2–105.1 s against 104.1–108.2 s); its 16–30% gains in
unpinned runs came from overlapping writes on spare cores.

The macOS and Linux numbers are not comparable with each other: different
machines, and an fsync on macOS does not reach the device.

### Where the disk writes go

From the per-file counters of a one-worker sync on this branch (macOS), about
2.9 GB in all:

| File | Written | Of which |
|---|---|---|
| `volumes.db` | about 2.44 GB (84%) | 1.42 GB to its write-ahead log, then 1.02 GB copied into the database file |
| `state.db` | about 0.41 GB | 0.26 GB log, 0.15 GB database file |
| `volume-bundles.db` (a cache) | about 0.07 GB | |

That is about 270 KB written to `volumes.db` per block, for state changes
that are small. Every changed trie node is its own content row with index and
retention rows beside it, and the log writes each byte twice. So the
amplification comes from how state is stored, not mainly from the engine. Not
yet broken down: bytes per operation (store, retain, count, release) and
repeated writes of the same content.

### Where the CPU goes

From 10 seconds of samples of a one-worker sync on this branch (macOS).
Shares are of busy samples and include what each calls, so they overlap.

| Activity | Share |
|---|---|
| Decoding content (DAG-CBOR) | about 17% |
| Encoding content (DAG-CBOR) | about 13% |
| Decoding wire frames (JSON with text CIDs) | about 13.5% |
| SQLite writes (syncs about 8%) | about 14% |
| Checking content against its hash | about 10% |
| Parsing CIDs and multihashes | about 8% |
| SQLite reads | about 8% |
| Executing blocks | about 8% |
| Core decisions (`NodeCore.step`) | about 7% |
| Fetching bodies | about 7% |
| Proof checks and derivations | about 6% |
| Retention (counts, windows, releases) | about 1.5% |

**What this says.** The node spends far more CPU representing data —
encoding, decoding, parsing text identifiers, hashing to check — than
deciding, executing, or retaining it. Scheduling and persistence are small
next to it. Caveats: the benchmark's blocks are small, so execution's share
is lower than on a chain with heavy transactions; macOS understates disk
costs; one sample window, one machine.

### Not measured, and should be

Liveness per chain path in production (instrumented by #158, §4.4), propagation and stale rate, each child's share of parent hash rate,
per-chain hosting cost, cross-chain transfer time, template latency, and
time to tip per chain as a latency, not only as total throughput.

**Scale is not measured at all.** The benchmark is 9,086 blocks over four
chains. How the node behaves with a hundred hosted chains, large state, many
peers, or sustained contention is unknown. The question to answer: if the
number of hosted chains doubled tomorrow, would every chain still make
predictable progress, or would the node need another round of special-case
machinery?

Node metrics and network metrics are different things. A node can report its
own liveness and cost; stale rate, propagation and each child's share of
parent hash rate need observations of the network.

---

## 3. The architecture at a glance

```
            peers (Ivy overlay)        operators, readers, miners (HTTP)
                    │                                │
        ┌───────────▼────────────────────────────────▼───────────┐
        │  Shell (LatticeNode)                                   │
        │   one serial loop ──► NodeCore.step ──► effects        │
        │        ▲                                   │           │
        │        │ events          ┌─────────────────┼─────────┐ │
        │        └─── worker pool ◄┘  jobs           ▼         │ │
        │             (connect, proofs, derive,   write, then  │ │
        │              preflight, templates)      publish      │ │
        │                                                      │ │
        │   state.db (facts, headers, journal)   volumes.db    │ │
        │   synchronous=FULL                     (content)     │ │
        └────────────────────────────────────────────────────────┘
        Core (LatticeNodeCore): deterministic; one ChainCore per hosted chain
```

The core decides; the shell executes. One serial loop takes every input,
steps the core once, and carries out the effects in a fixed order: write,
then publish, then everything else. Work that takes time runs on a pool of
workers and comes back to the loop as events. Each step's facts are written
by the loop in one synchronous transaction before anything it decided is
published.

| Module | Lines | Role |
|---|---|---|
| `LatticeNodeCore` | 5,770 | deterministic decisions per chain |
| `LatticeNodeSim` | 5,496 | the simulator that drives the core and checks invariants every step |
| `LatticeNode` | 15,013 | the shell: loop, stores, networking, jobs, reads |
| `LatticeNodeAPI` | 1,441 | request and response models |
| `LatticeNodeDaemon` | 3,361 | HTTP servers and process entry |
| `LatticeCtl`, `LatticeCtlCore` | 2,947 | the `lattice` CLI |
| `LatticeMiner*`, `LatticeMiningCoordinator*` | 1,624 | mining, as separate processes |

---

## 4. The parts, one by one

Each part: **what** it is (with the code), **why** it is that way, **how
others do it** (with performance), **ease of change**, and what is **open**.

### 4.1 The core: how decisions are made

**What.** `NodeCore` holds one `ChainCore` per hosted chain path
(`LatticeNodeCore/Host/NodeCore.swift`), steps levels parent before child,
and passes each child its parent's tree and `headersSynced`. A `ChainCore`
holds the weighed tree (`ChainTree`, from Lattice), header sync, the body
pipeline, mining and mempool state, and the latches `synced` and
`headersSynced` (`Chain/ChainCore.swift`). Inputs are `NodeEvent`s; outputs
are `NodeEffect`s. The simulator (`LatticeNodeSim`) checks after every step
that published tips and served headers are durable, no honest peer is
disconnected, the weighed graph equals the stored headers, GHOST weights
match a reference, and no gate is left shut.

**Why.** Sync was rebuilt several times after nodes stopped making progress;
a deterministic core the simulator steps exactly as the node does makes
liveness rules testable.

**How others do it.**

| Approach | Who | Cost | Buys |
|---|---|---|---|
| One lock around validation and chain state | Bitcoin Core (`cs_main`) | liveness hard to test in isolation | simplicity, decades of hardening |
| Staged pipeline: each stage over all available blocks, outputs persisted | Erigon, Reth ([Erigon](https://erigon.substack.com/p/staged-sync-and-short-history-of)) | worse for following the tip than catching up | Erigon reports full sync cut "from couple of weeks to couple of days" (own claim) |
| Order agreed without executing; execution a few blocks behind | Monad ([asynchronous execution](https://docs.monad.xyz/monad-arch/consensus/asynchronous-execution)) | a node behind in execution drops out of consensus until it catches up (own docs) | execution gets the whole block time |
| Deterministic core, effects run by a shell | this node | a layer between decision and I/O | every liveness rule testable by simulation |

**Performance.** Core decisions are about 7% of CPU.
**Ease of change.** Easy: a rule change is tested by the simulator before the
shell sees it. **Judgment.** Keep. Its closest relative is Monad's
separation: this node also weighs headers before executing them, and acts
only on the heaviest executed tip.

### 4.1a The loop's contract

The serial loop is the one place state transitions become visible. Its rules,
checked against the code by reading:

| Rule | Holds today? |
|---|---|
| The core performs no I/O | Yes: it emits effects |
| The loop never waits for the network or for long computation | Yes: those run as jobs or tasks and return as events |
| The loop never waits on something only the loop can finish | Yes: jobs and RPC handlers read live state by sending the loop an input (`LiveLevels`) and waiting; the loop never waits on a job |
| Workers never change the core's state | Yes: results return as events the loop steps |
| Writes complete before what they make true is published | Yes (§4.7); this is the one deliberate wait |
| Every dispatched job has a rule for when it is superseded | Partly: a recheck whose tip moved is dropped; body fetches are cancelled when they leave the window; other jobs run to completion |

These rules should be written as the loop's contract and kept by review; a
problem that seems to need another actor, scheduler or background state
manager is first solved through the loop's existing events and effects.

### 4.2 Weigh: headers and work

**What.** Each node keeps a weigh log per chain; peers read it in pages
(`getStream`), fetch missing entries one `getData` at a time, and are pushed
new entries once they have read to the end. A root-chain header's own work is
checked on arrival, and a failure disconnects its sender. A child-chain
header waits for a proof of the parent work securing it: **derived** from
parent carriers this node holds, or **checked** in batches when a peer sends
one; a derivation takes precedence, and only a failing peer proof blames
(`ChildProofs.swift`).

**Why.** Lattice's child chains are secured by the parent's work, so a
child header's weight is a fact about the parent's graph. #121 made sync
top-down at every depth and decided derive-or-check per block; #141 opens a
child once its parent has read a peer's whole log and holds a weighed block,
instead of waiting for the parent to execute (the grandchildren had sat idle
for a quarter of the benchmark).

**How others do it.**

| Approach | Who | Buys | Cost |
|---|---|---|---|
| Headers first | Bitcoin Core since 0.10 ([release notes](https://bitcoin.org/en/release/v0.10.0)) | parallel body download against a known best chain | — |
| Merged mining, proof carried in the block | Namecoin (AuxPoW) | child secured by parent work | proof bytes in every child block |
| Work facts derived from the parent graph; peer proofs checked otherwise | this node | weighs a child without trusting peers' proofs | the gate's timing (open) |

**Performance.** Decoding the wire frames that carry headers is about 13.5%
of CPU — more than executing blocks. The cost is the representation (§4.12),
not the weighing. **Ease of change.** Easy, in the core.
**Open.** The child gate opens on whichever peer's log ends first; a peer
that is behind opens it early.

### 4.3 Select: fork choice and "caught up"

**What.** Each level publishes a best header tip and an act-on tip, the
heaviest executed block; siblings are ordered by GHOST subtree weight
(`ChainSelection.swift`). The node mines, preflights and answers reads on the
act-on tip. Two one-way latches: `headersSynced` (a peer's log read to its
end with no holes) opens child levels; `synced` (additionally the act-on tip
is the best tip or the heaviest whose bodies can be had) gates peer
transactions and relaying of peer-learned entries.

**Why.** Acting only on executed state keeps the node from building on
blocks it has not validated. The latch keeps a syncing node from admitting
peer transactions or relaying a stream it is still reading (#76, #85); #125
and #128 stopped it waiting forever on bodies no peer has.

**How others do it.** Bitcoin Core takes the chain with the most work;
this node uses GHOST, the heaviest subtree
([Sompolinsky and Zohar](https://eprint.iacr.org/2013/881)). Bitcoin's
`IsInitialBlockDownload` is a one-way latch that stays false once false, and
[`getblocktemplate` refuses while it is true](https://github.com/bitcoin/bitcoin/blob/master/src/rpc/mining.cpp).

**Performance.** Inside core decisions. **Ease of change.** Easy, in the core.

**Open, and a design question.** The latches have been patched three times
(#125, #128, #141), and they encode several different questions in two
booleans: has this peer's log been read to its end; has the node caught up
with the network; can a child chain start reading its peers; may peer
transactions be admitted and peer-learned entries relayed. Reading one
peer's log to its end does not establish that the peer has the network's
best chain, yet it opens child chains. The better shape is to keep facts as
facts — what is weighed, what is executed, which bodies cannot be had — and
derive each readiness question from them where it is asked, instead of
storing latched answers. This is the first suspect for the production stall:
a correctness and liveness investigation, not a speed one.

### 4.4 Liveness reporting (#158, in review)

**What.** `/status` reports, for each chain path, its acted-on height and
best header height (already there) and now `tipAdvancedAt` (when the
acted-on tip last moved, as this process saw it) and
`secondsSinceTipAdvanced`. `/metrics` reports tip heights for every hosted
chain, not only the root, and `lattice_chain_tip_advanced_timestamp_seconds`.
Behind its best header and not moving is a stall.

**Why.** Outcome 2 is the one failing, and it was not visible as a number.

**What it does not yet say: why.** A stalled chain may be waiting for its
parent, for a header proof, for a body, on a body nobody has, on a queued
job, on parent state, on a latch, or be on a heavier branch of lower height.
Some of this is already reported: `waiting` names why the next block cannot
execute (body not fetched, or connect without a verdict), and `sync` counts
pending headers, headers awaiting proof, proof checks running, the body
window, bodies requested, unavailable and parked, and blocks awaiting parent
facts. Missing, and worth adding as values derived from the core's state
(not new state): the phase the chain is blocked in (headers, proofs, bodies,
execution, at tip), the oldest wait and its age, jobs pending for the chain,
and the parent chain's own status. With those, most stalls can be diagnosed
from `/status` alone, and the same predicates can drive simulator
assertions. Height alone also misses a heavier but shorter branch; comparing
the acted-on tip with the best executable tip is the precise measure.

**How others do it.** Bitcoin Core's `getblockchaininfo` returns blocks and
headers; geth's `eth_syncing` returns current and highest block; both leave
the subtraction to the reader, as this does. A heavier but shorter branch
reads as "not behind" in all three.

### 4.5 Fetch: bodies

**What.** A body window of up to 64 blocks is requested; blocks that leave it
are cancelled (`BodyPipeline.swift`). A body no host or announcing peer
serves is parked with backoff from 1 s doubling to 300 s, woken early by a
new provider or its parent. Unavailable is never invalid. Bodies are asked of
the chain's hosts first, never the DHT for a child. A fetched body is held in
memory and stored only once execution finds the block valid.

**Why.** #114: a one-CPU testnet node spent 44% of its CPU retrying fork
bodies no peer had.

**How others do it.**

| Who | Window | Per peer | A peer that stalls | Missing content |
|---|---|---|---|---|
| Bitcoin Core ([`net_processing.cpp`](https://raw.githubusercontent.com/bitcoin/bitcoin/master/src/net_processing.cpp)) | 1,024 blocks | 16 in flight | disconnected after 2 s, rising to 64 s | retried from another peer; only invalid is failed |
| Bitcoin Core, new blocks ([BIP152](https://raw.githubusercontent.com/bitcoin/bips/master/bip-0152.mediawiki)) | — | — | — | short transaction ids; a 1 MB block in about 15 KB when mempools agree (third-party figure) |
| this node | 64 blocks | — | backoff, never blames | waits; a provider or the parent wakes it |

**Performance.** About 7% of CPU. Whether 64 limits this node has not been
measured on this branch. **Ease of change.** Easy. **Judgment.** Keep;
consider compact relay once blocks carry many transactions.

### 4.6 Execute

**What.** A connect job takes up to 32 ready blocks of one chain, each the
previous one's child, whose parent state and continuity fact are present.
One job per chain runs at a time. It executes them in order, stores the
valid blocks' content in one `volumes.db` write, then reports verdicts. A
valid block whose body could not be stored is reported not stored. Invalid
becomes an exclusion; a missing input parks the block.

**Why.** #118 batched execution to one commit per batch; #126 made a block
connect only once its body is stored.

**How others do it.**

| Approach | Who | Speed-up claimed | Cost |
|---|---|---|---|
| Sequential, 32 blocks per pass | Bitcoin Core (`ActivateBestChainStep`, [`validation.cpp`](https://github.com/bitcoin/bitcoin/blob/master/src/validation.cpp)); this node | — | one core per chain |
| Parallel signature checks | Bitcoin Core (`CCheckQueue`, `-par`) | no sourced figure for this alone | — |
| Skip old signature checks | Bitcoin Core (`-assumevalid`) | 0.14's sync went from about 36 h to about 6 h with this and other changes ([release](https://bitcoincore.org/en/2017/03/08/release-0.14.0/)) | a trust assumption |
| Optimistic parallel transactions | Aptos Block-STM ([paper](https://arxiv.org/abs/2203.06871)) | about 17–20× sequential on 32 threads (paper) | conflicts re-execute; complexity |

**Performance.** Executing blocks is about 8% of CPU, and chains already run
side by side. **Ease of change.** Easy. **Judgment.** Keep sequential
execution. **Open.** Execution reads state it lacks from peers; a full node
should not need to.

### 4.7 The write model

**What.** Effects run in one order: `persist` and the mempool's pool change
first, then `publish`, then everything else (`RT`, `rank`), each awaited.
`persist` writes executed state Volumes in one `volumes.db` write, then every
level's headers, proofs, facts, cursors and state diffs in one `state.db`
transaction (`NSE`, `persistNodeBatch`). Bodies were stored before, by the
job that validated them. A store write that throws stops the node
(`failStop`, `fatalError`). So everything a fact names is on disk before the
fact, and every fact before anything it decided is published.

Outside the loop, only content is written, before anything names it:
validated bodies by connect jobs, a mined block's content before its event is
posted, state fetched by count-repair tasks, and a detached task that drops
proofs that failed. Retention releases run on the loop after publish; their
failures are logged, not fatal.

**Why.** One order in one place is what this branch restores. The removed
layer wrote behind the loop to save fsync waits; every write then needed an
ordering rule between two stores, and review after review found a new hole.

**How others do it.**

| Approach | Who | When state reaches disk | Order | A crash costs |
|---|---|---|---|---|
| Memory cache flushed when large or periodically | Bitcoin Core ([`FlushStateToDisk`](https://github.com/bitcoin/bitcoin/blob/master/src/validation.cpp), `-dbcache`) | at flush | block files, then block index, then coins with the best-block marker; a head-blocks marker detects an interrupted flush ([`txdb.cpp`](https://github.com/bitcoin/bitcoin/blob/master/src/txdb.cpp)) | replay from the marker |
| In-memory diff layers | geth path scheme ([1.13](https://blog.ethereum.org/2023/09/12/geth-v1-13-0)) | the last 128 blocks stay in memory | one database batch | an unclean-shutdown marker; recent state rebuilt |
| Stage outputs committed in batches | Erigon, Reth | per stage | one database | resume the stage |
| Persistent trie, async I/O | Monad ([MonadDb](https://docs.monad.xyz/monad-arch/execution/monaddb)) | new node versions per update, io_uring | one writer, many readers | not documented in what was read |
| Write-behind across two stores | this node, #137–#147 (reverted) | state buffered, records behind the loop | ordered by each caller | re-execute above a marker; holes found in review |
| Synchronous per step | this node | each step | content, then facts in one transaction, then publish | nothing to replay |

**Performance.** One community test of Bitcoin Core measured initial sync
about 24% faster with a 28 GB cache than the default and about 10% faster at
4 GB ([bitcointalk](https://bitcointalk.org/index.php?topic=5501324.0);
single machine, a claim). Here, syncs are about 8% of CPU on macOS.
**Ease of change.** Easy now: two layers, one order. **Judgment.** Synchronous
writes meet the targets with the least machinery. If a target is missed, the
conventional next step is Bitcoin's: one flush routine, content first, then
state and its marker together.

### 4.8 Stores and storage engines

**What.**

| File | Holds | Settings |
|---|---|---|
| `state.db` (schema epoch 48) | facts (kept forever), accepted blocks, headers, child indexes, proofs, stream cursors, the local mempool journal, state diffs for the window, the weigh log id | WAL, `synchronous=FULL`; one writer, one reader; the store's actor on its own serial queue |
| `volumes.db` | content by hash: bodies, transactions, specs, policy modules, state trie nodes; retention scopes and counted roots (VolumeBroker 10.1.3) | WAL, `synchronous=FULL` |
| `volume-bundles.db` | a cache of which Volumes a block's bundle holds | WAL, `synchronous=NORMAL`; may be deleted |

A different schema epoch, genesis or set of tables means "wipe required".

**Why.** #81 settled the record layout; #108 gave the store its own read
connection (fixing a stale-snapshot bug) and its own queue (keeping fsync off
Swift's shared thread pool).

**How others do it.**

| Engine | Who | Structure | Note |
|---|---|---|---|
| SQLite | this node | B-tree, WAL | simple to operate |
| LevelDB | Bitcoin Core | LSM tree, compaction | two stores (block files with an index, and the chainstate), ordered by one routine |
| Pebble | geth | LSM tree | BNB Chain measured more disk throughput with path scheme plus Pebble than hash scheme plus LevelDB ([blog](https://www.bnbchain.org/en/blog/optimizing-blockchain-storage-bscs-path-based-storage-system)); engine and scheme changed together |
| MDBX, plus static files and RocksDB | Erigon, Reth ([Reth storage](https://reth.rs/run/storage)) | copy-on-write B-tree | — |
| Trie stored natively | MonadDb, Firewood ([repo](https://github.com/ava-labs/firewood)) | trie nodes addressed by disk offset | Firewood is alpha by its own README |
| SSD-page-packed trie | NOMT ([repo](https://github.com/thrumdev/nomt)) | binary trie in 4 KB pages | authors' benchmark only |
| Append-only log | QMDB ([paper](https://arxiv.org/abs/2501.05262)) | state and Merkle tree in one log | claims about 6× RocksDB (own paper) |

**Performance.** SQLite reads and writes are about 22% of CPU; a sync writes
about 2.9 GB to keep 90 MB — mostly from how state is stored (§4.9), not the
engine. The newer engines target states of hundreds of gigabytes on fast
SSDs; this node's whole state is under 100 MB. **Ease of change.** Easy for
the stores themselves. **Judgment.** Keep SQLite.

### 4.9 State and its retention

**What.** `volumes.db` keeps what a named scope retains; a release reclaims
whatever no scope or count still names, in the same transaction; a full
sweep runs at start.

| Scope | Keeps | Released |
|---|---|---|
| chain | constants, Nexus genesis; on `state: all` every state created | never |
| body (per block) | a block's own Volume, transactions, receipt witness | with `blockBodies: none`, once another block is the tip |
| rules (per chain) | spec and policy modules, when state is not `all` | when the chain is no longer hosted |
| reads (per block) | the state a stored block reads, until it executes | after execution or invalidity, and at start |
| window (per chain and height) | what executions stored, on `recent` | once the tip is a window above, after the counts reach the tip |
| counted (per chain) | on `recent`, every node of the current state, by count | moved with the tip |
| staging | what a state sync or heal fetched | once the counts move |
| operator | pins | on unpin |
| durable / live mempool | journaled and pooled transactions | as they leave |

On `recent` the counts move with the tip once per window, are checked at
start and maintenance, healed when roots are missing, and replaced by a state
sync when they cannot follow. (`state: none` is still on this branch; #152
removes it.)

**Why.** #94 batched the counts to once per window: they had been four synced
commits per block, a quarter of each step.

**How others do it.**

| Approach | Who | State on disk | History and reorgs | Pruning |
|---|---|---|---|---|
| Unspent outputs, flat | Bitcoin Core | the UTXO set | per-block undo data | old block files deleted |
| Hash-keyed trie | geth (old) | every version's nodes by hash | old roots kept until pruned | counted in memory; offline prune |
| Path-keyed trie | geth path scheme ([ethresear.ch](https://ethresear.ch/t/ethereum-path-based-storage-model-and-newly-inline-state-prune/14932), [1.13](https://blog.ethereum.org/2023/09/12/geth-v1-13-0)) | one trie, nodes by path | 90,000 reverse diffs on disk; 128 blocks in memory | inline, "100%" (own claim) |
| Flat state plus changesets | Erigon, Reth | flat state; trie computed separately | changesets per block | Reth v2 reports 23–50% less disk than v1 (own figures) |
| Versioned tree | Aptos (Jellyfish Merkle tree on RocksDB) | nodes keyed by version | old versions queryable | stale nodes pruned later; criticised for write amplification (third-party) |
| Content-addressed, counted | this node | every version's nodes by hash | windows; per-block diffs | counts moved per window, audited, healed, resynced |

**Performance.** This is where the disk goes: about 2.9 GB written to keep
90 MB. Retention's CPU is small (about 1.5%), but every content read is
decoded and hash-checked, a large share of CPU, because state is stored as
hash-addressed encoded nodes. **Ease of change.** Hard: retention crosses
three layers — the loop (a count-repair state machine in `RT`), the store
(`NodeStorage+Retention.swift`, 631 lines; `NodeStore+StatePins.swift`, 181),
and VolumeBroker's counted index. **Judgment.** The largest remaining
machinery and the biggest disk cost. No established client counts references
to retain trie nodes on disk; geth moved away from hash-keyed state. Replace
when an objective needs it, with geth's path scheme the nearest shape — but
first make it replaceable (§6).

### 4.10 Workers and scheduling

**What.** `max(1, processors − 1)` workers; three queues served strictly in
order — what an RPC waits on, each chain's next blocks, the rest — first in,
first out within each; a recheck whose tip moved is dropped (`API`,
`JobQueues`).

**Why.** #64: a testnet root chain executed one block every five minutes, its
next block queued behind thousands of child proof checks; #76 made three
queues.

**How others do it.** Bitcoin Core: one validation thread plus a script-check
pool fed from one queue (`CCheckQueue`). Block-STM: a collaborative
scheduler. Erigon, Reth: stages in sequence, parallel within a stage. The
sync architecture's rule 4 asks for a queue per chain and kind ("lanes"):
built and measured, 10.7–10.8 s against 10.4–10.5 s for the queues.

**Ease of change.** Easy: one struct. **Judgment.** Keep the queues; rule 4
now says so.

### 4.11 Mempool and the operator's promises

**What.** Transactions arrive with an origin (local, submitted, peer,
returned, restored) and are admitted by a preflight against the act-on tip's
state. An operator's transaction is stored, retained and journaled in
`state.db` before it is acknowledged; at start the journal is replayed. A
miner's submitted block is answered from the step that executes it, after
that step's write.

**How others do it.**

| Who | When | Promise |
|---|---|---|
| Bitcoin Core (`mempool.dat`) | at a clean stop | a crash loses the pool |
| geth (`txpool.journal`, rewritten every `txpool.rejournal`) | appended and rewritten periodically | survives restarts |
| this node | before the reply | survives a crash or power loss |

**Judgment.** Keep; the strongest of the three, one small write per
submission.

### 4.12 Representation: identifiers and wire format

**What.** Text CIDs (multibase, multihash) throughout, the core included;
canonical JSON on the wire (`Networking/ChainSyncWire.swift`); content stored
as DAG-CBOR, decoded on read and checked against its hash.

**How others do it.** Bitcoin Core: fixed 32-byte hashes inside, binary
messages. geth: fixed 32-byte hashes, RLP on devp2p.

**Performance.** The largest share of CPU: decoding wire frames about 13.5%,
parsing CIDs and multihashes about 8%, and much of the DAG-CBOR decoding
comes from content re-read by text identifier. **Ease of change.** Split: the
wire format sits in one codec file and its adapter (easy); identifiers appear
in 32 files including the core (hard but mechanical). **Judgment.** The
biggest single lever, already decided in the design (rule 12), and
consensus-neutral. Wire format first.

### 4.13 Mining

**What.** Mining runs outside the node: `lattice-miner` searches a nonce
range; a coordinator fetches templates, watches a template digest, and
submits work. The digest hashes the tip, the pool and each hosted level's
inputs. Child templates are cached per level for up to 30 s; a template
request while a level holds a backlog is refused with a 503.

**Why.** #67 moved mining out of the node. #93 found template churn came from
the digest naming the best header and keyed it on inputs; #62 and #91 had
addressed the same churn earlier.

**How others do it.** Bitcoin Core's `getblocktemplate` with a long-poll id
that changes with the template's inputs, refused during initial sync.

**Ease of change.** Easy: a separate process behind HTTP. **Judgment.** After
#93 the cache (#62) and the refusal (#91) are likely redundant; measure
template latency, then simplify to one template per tip and pool.

### 4.14 Networking and serving

**What.** Ivy overlay; a versioned handshake with capabilities; sync messages
for stream pages, data, ancestors and headers; transactions announced to the
chain's hosts; headers and proofs served from the store; Volumes served
checked against their hash; a per-peer serving ledger.

**How others do it.** Bitcoin's `inv`/`getdata` and headers messages; peers
scored by behaviour. Content served by hash is IPFS's model.

**Open.** The wire format (§4.12).

### 4.15 Start-up and bootstrap

**What.** Lock the directory; open both stores; pin constants; rebuild the
mempool's retention from the journal; seed the Nexus genesis if missing;
sweep; restore each level from its facts; release leftover retention, move
legacy scopes, settle counts; replay the journal; start the network. No
replay or forget step for facts: every fact on disk was written after what
it names.

**How others do it.**

| Approach | Who |
|---|---|
| Verify recent blocks; replay an interrupted flush (`DB_HEAD_BLOCKS`) | Bitcoin Core |
| Unclean-shutdown marker | geth ([`PushUncleanShutdownMarker`](https://github.com/ethereum/go-ethereum/blob/master/core/rawdb/accessors_metadata.go)) |
| Start from a state snapshot, verify history behind | Bitcoin Core assumeUTXO (mainnet since 28.0, [Optech](https://bitcoinops.org/en/topics/assumeutxo/)) |
| Hints that skip storing intermediate state | SwiftSync ([proposal](https://gist.github.com/RubenSomsen/a61a37d14182ccd78760e477c78133cd), Bitcoin Core #34004, open) |
| Download state from peers at a recent block | geth snap sync |
| Sync from genesis; nothing to replay | this node |

**Judgment.** Nothing to change now. If chains grow long, a snapshot start is
the conventional answer.

### 4.16 Processes and the operator surface

**What.** `lattice` runs `lattice-node --root`; exit codes 0, 75 and 78 tell a
process manager to stop, restart, or not restart; systemd and launchd units
are generated. Configuration is `lattice.json` then `config.d/*.json`,
reloaded on SIGHUP. The operator API is on loopback with a cookie rotated at
each start, or remote with tokens; a separate public app serves reads.

**Why.** #63 put supervision and configuration writing into the node; #67,
#71 and #72 moved most of it back out.

**How others do it.** Drop-in configuration and exit-code contracts with
systemd; the cookie is bitcoind's `.cookie`.

**Ease of change.** Easy; the daemon's command file is 1,741 lines.

### 4.17 Bounds and backpressure

A node needs bounded memory and bounded outstanding work, and one chain must
not be able to take what others need. What is bounded today, by reading:

| Resource | Bound |
|---|---|
| Content fetched from peers | a node-wide byte budget (`AcquisitionBudget`), deeper first |
| Bodies asked for | the body window, 64 per chain |
| Header data asked of a peer | one `getData` at a time; the next page only once holes fit in half a page |
| Messages queued to a peer | per-session message and byte limits (`SessionOutbox`) |
| Content served to peers | concurrent and in-flight byte limits (`servingMaxConcurrent`, `servingMaxInFlightVolumeBytes`) |
| Mempool | per-chain limits |
| Worker queues | **not bounded**: proof checks can queue in the thousands while a tree of chains syncs |
| Bodies fetched but not yet executed | bounded by the window and the byte budget; not reported |

Not yet measured: how these behave with many hosted chains, and whether one
pathological child can starve the root. Bounding each queue, and making
per-chain consumption visible, belongs with the scale tests.

### 4.18 Failure isolation

| Failure | Response today |
|---|---|
| A store write fails, or the store is damaged | the node stops (`failStop`) |
| A peer disconnects | recovered: other peers serve |
| Content is missing | retried with backoff; never judged invalid |
| A peer sends a proof that does not verify | the peer is disconnected |
| One chain's body is missing | that chain waits; its children wait with it by design (top-down); its siblings and the root do not |
| A retention release fails | logged; the node goes on |
| The mining process fails | restarted by its own process manager; the node is unaffected |

A child chain cannot stop the root or its siblings by being stuck. A storage
failure stops everything, which is right for the store the node's facts live
in.

### 4.19 Reorganisations

A move of the acted-on tip to another branch: the executed set changes,
transactions of the blocks left return to the pool, templates follow the new
tip, and on `recent` state the window holds what is needed to move back;
deeper than the window, state is synced. Covered by tests at one level
(within and deeper than the window, onto an earlier executed branch). Not
confirmed: simulator scenarios that reorganise several levels of the
hierarchy at once, and a parent reorganisation that changes what a child's
blocks may anchor to. Those deserve dedicated adversarial scenarios.

---

## 5. How easy it is to change

| Concern | Lives in | Layers a change crosses | Conventional shape? | Ease of change |
|---|---|---|---|---|
| Consensus decisions and sync rules | `LatticeNodeCore`, checked by `LatticeNodeSim` | one | the separation is this node's own, and it pays | **easy** |
| Sync wire format | `ChainSyncWire.swift`, its adapter, one call site | one | one codec at the edge, as others; text JSON where others use binary | **easy** |
| Identifiers | text CIDs in 32 files, the core included | all | others use fixed 32-byte hashes and convert at the edge | **hard but mechanical** |
| Write order and persistence | the loop's persist effect and two store files | two | Bitcoin's order | **easy** |
| State retention | retention and state-pin store files, a state machine in the loop, VolumeBroker's counted index | three | no established client counts references on disk | **hard** |
| The shell's loop | `NodeRuntime.swift` (2,223) and `NodeRuntime+API.swift` (1,419) | — | decides effects, builds views and digests, runs count repair and maintenance | **a hotspot** |
| Work queues | `JobQueues` | one | one pool with queues | **easy** |
| Mining | separate processes behind HTTP | one | `getblocktemplate` | **easy** |
| Operator surface | `LatticeCtl`, `LatticeNodeDaemon` | one | systemd, drop-in configuration | **easy** |

Components with no conventional equivalent, and why they stay or go:

1. **The deterministic core with a simulator.** Stays: it makes liveness
   testable, at about 7% of CPU.
2. **Content-addressed state retained by counts on disk.** Goes when an
   objective needs it; first made replaceable.

---

## 6. What to do next

Each phase has an exit criterion; a later phase starts when its measurement
says it is needed, not before.

**Phase 1 — Prove liveness (highest priority).** Every hosted chain makes
progress or reports exactly why it cannot.

- Land per-chain liveness reporting (§4.4), deploy it, and diagnose the node
  stopped at height 3,920.
- Review what `synced` and `headersSynced` encode, and derive readiness from
  facts (§4.3).
- Report the blocking phase, the oldest wait, pending jobs and the parent's
  status per chain (§4.4).
- Simulator scenarios for starvation, missing bodies, delayed proofs,
  parent–child stalls, and reorganisations at several depths (§4.19).

*Exit:* no unexplained stalled chain in production; every known blocking
condition is observable and recoverable.

**Phase 2 — Reduce complexity (high).** Make the node easier to understand
and to change.

- Make the runtime coordinator boring: receive input, step the core, run
  effects, take results. Move the read model (views, digests), maintenance,
  and count repair out of the loop file, each behind the effects it already
  is, none owning authoritative state.
- Put state retention behind one interface (load current state, apply a
  block, roll back, read, prune), without changing its behaviour, and write
  down what each retention scope is for; some may be implementation details,
  not concepts.
- Write the loop's contract (§4.1a) and the persistence order down, and test
  a crash at every boundary, retention releases and count repair included.
- Bound the worker queues; make per-chain resource use visible (§4.17).
- Correct the sync architecture's rule 4 to the queues that are built.

*Exit:* a change to retention, API views or maintenance needs no change to
the core or to how events are processed.

**Phase 3 — Improve representation (medium).** Less CPU and allocation,
consensus unchanged.

- The Linux benchmark pinned to one CPU is in place (`Benchmarks/sync`,
  `FOLLOWER_CPUS`); add time to tip per chain as well as throughput.
- The binary wire format, measured on its own, behind a compatibility gate:
  canonical and unambiguous, older peers still served, no hashed byte
  changed.
- Measure repeated CID parsing and repeated decoding before adding any cache.
- Then fixed-width identifiers inside the node, converted at the edges; text
  kept for logs and APIs.
- Break down the write amplification by operation (§2).
- Measure memory, bandwidth and CPU as the number of hosted chains grows.

*Exit:* a measured improvement against the baseline, with no regression in
compatibility or correctness.

**Phase 4 — Simplify storage (when an objective needs it).**

- Separate what current state needs, what recent history (reorganisations)
  needs, and what serving old content needs: three requirements, not one
  storage problem.
- Evaluate geth's path scheme and flat state with changesets against them;
  benchmark disk writes and restart time.
- Replace the retention implementation only if a defined target warrants it.

*Exit:* a simpler storage model with measured benefits and a written recovery
contract.

**Phase 5 — Operational maturity.**

- Per-chain resource budgets (CPU, memory, disk growth per million blocks,
  bandwidth, outstanding work, restart time).
- Propagation, stale-block and child hash-share measurements on the network.
- Cross-chain transfer completion; template latency.
- Long-running and capacity soak tests; documented recovery procedures and
  operator alerts.

*Exit:* operators can understand a node's health, capacity and recovery
without a developer.

**Simplify after measuring, along the way:** the template cache (#62) and the
backlog refusal (#91), one at a time, after measuring template latency, cache
hit rate and stale submissions; #97, #92, and #108's incremental body order.

**Keep:** the deterministic core, the serial loop, synchronous writes, SQLite,
sequential execution per chain, the three work queues, the journal before
acknowledgement, the separate mining process — each until a measurement
against an agreed target says otherwise.

### Decisions for the owner now

1. Liveness investigation as the top engineering priority.
2. State retention extracted behind one interface, behaviour unchanged.
3. The binary wire format as the next performance experiment, with a
   benchmark and a compatibility gate.

Everything else stays conditional on measurements.

---

## 7. How a change is judged

**Principles.**

1. **One authority for decisions.** The core owns protocol decisions;
   workers run tasks and never change authoritative state.
2. **Progress is explainable.** Every chain progresses or says what it is
   waiting for. No silent waiting.
3. **Durability precedes promises.** Anything acknowledged or published has
   its facts and content on disk first.
4. **Conventional, replaceable components.** No bespoke state management,
   scheduling or persistence without a demonstrated reason.
5. **Optimise measured bottlenecks.** No concurrency, buffering or new
   storage engine because other clients have one.

The north star: a small deterministic engine, a boring shell, conventional
storage, and chains that progress independently.

**Rules.**

- It names the outcome it serves and its effect on that row, measured, or
  says why it cannot be measured yet.
- It does not make an earlier outcome worse to improve a later one.
- If its target is met, it does not land unless the owner raised the target.
- It reports what it adds: lines, new components, every rule a caller must
  keep, and which concerns it touches. One that crosses more layers than the
  concern it serves first asks whether the boundary is in the wrong place.
- A new buffer, background writer, lock, second write path, or ordering
  between stores waits for the owner's yes, with its conventional equivalent
  by shape, its measured gain, and its cost (the design gate, #155).
- A second review round that finds a new hole of the same kind stops the
  change for a design question.

**Durability.** Writes are atomic and ordered; a restart resumes from a
consistent earlier state. Chain data can be had again from the network, so
the node promises nothing about it beyond outcome 4.

**Non-goals.** Changing consensus or anything hashed. Light nodes, for now. A
scheduler of the node's own. Extra caution for a chain only this node hosts,
beyond outcome 4. Speed past the targets. Resource limits on WASM policy
modules.

---

## 8. Sources

Lattice: [specification](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/spec.md),
[philosophy](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/philosophy.md),
[foundational architecture](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/foundational-architecture.md),
[merged-mining security](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/economics/merged-mining-security.md).

Bitcoin Core: [`validation.cpp`](https://github.com/bitcoin/bitcoin/blob/master/src/validation.cpp),
[`txdb.cpp`](https://github.com/bitcoin/bitcoin/blob/master/src/txdb.cpp),
[`net_processing.cpp`](https://raw.githubusercontent.com/bitcoin/bitcoin/master/src/net_processing.cpp),
[`rpc/mining.cpp`](https://github.com/bitcoin/bitcoin/blob/master/src/rpc/mining.cpp),
[0.10.0 release notes](https://bitcoin.org/en/release/v0.10.0),
[0.14.0 release](https://bitcoincore.org/en/2017/03/08/release-0.14.0/),
[BIP152](https://raw.githubusercontent.com/bitcoin/bips/master/bip-0152.mediawiki),
[assumeUTXO](https://bitcoinops.org/en/topics/assumeutxo/),
[SwiftSync](https://gist.github.com/RubenSomsen/a61a37d14182ccd78760e477c78133cd),
[dbcache test](https://bitcointalk.org/index.php?topic=5501324.0) (third party).

geth: [databases](https://geth.ethereum.org/docs/fundamentals/databases),
[1.13 and the path scheme](https://blog.ethereum.org/2023/09/12/geth-v1-13-0),
[path-based storage](https://ethresear.ch/t/ethereum-path-based-storage-model-and-newly-inline-state-prune/14932),
[unclean-shutdown marker](https://github.com/ethereum/go-ethereum/blob/master/core/rawdb/accessors_metadata.go).

Newer designs: [Erigon staged sync](https://erigon.substack.com/p/staged-sync-and-short-history-of),
[Reth storage](https://reth.rs/run/storage),
[Monad asynchronous execution](https://docs.monad.xyz/monad-arch/consensus/asynchronous-execution),
[MonadDb](https://docs.monad.xyz/monad-arch/execution/monaddb),
[Firewood](https://github.com/ava-labs/firewood),
[NOMT](https://github.com/thrumdev/nomt),
[QMDB](https://arxiv.org/abs/2501.05262),
[Block-STM](https://arxiv.org/abs/2203.06871),
[BNB Chain on the path scheme](https://www.bnbchain.org/en/blog/optimizing-blockchain-storage-bscs-path-based-storage-system).

Fork choice: [Sompolinsky and Zohar, GHOST](https://eprint.iacr.org/2013/881).
