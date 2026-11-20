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
> document says so. Each target's reasoning is in "How the targets were
chosen" below the table.
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
| 2 Liveness | Acted-on height against best header height, per chain path, over time | node | At its best header 99% of the time after its first catch-up | Reported per chain in `/status` and `/metrics` (#158, #161, #163); not yet tracked over time |
| 2 Liveness | Stalls: a chain behind its best header whose tip has not moved for longer than a threshold | node | Zero. Stalled: behind its best header and still for 10 target block times, at least 10 minutes | Testnet's child chains stopped at 3,920: a withdrawal whose receipt proofs no node held (§4.9a); repaired |
| 2 Liveness | Time to tip from empty, and from a restart, per chain path | benchmark, node | From empty, 50 blocks a second per chain path on one CPU; from a restart, its tip within a minute, then the same | 9,086 blocks over four chains in about 74 s, one worker, 4-CPU Linux runner; per chain on macOS, a leaf reaches its tip only near the end of the whole sync (§2) |
| 3 Security | Time for a block to reach most hosts, per chain | network | 90% of its hosts within 5% of its target block time | Not measured |
| 3 Security | Share of blocks that go stale, per chain | network | At most 1% | Not measured |
| 3 Security | For each child, the share of parent hash rate whose templates commit it | network | Every template of a node hosting the child commits it | Not measured |
| 4 Promises | Acknowledged transactions or accepted blocks lost after a crash or power loss | tests | Zero | Zero in tests |
| 5 Compatibility | Partitions or refused messages between this version and the previous | two-version runs | Zero | Zero in CI |
| 6 Change | Layers a change to each concern crosses | code | One for each | Most cross one; state retention, one for a setting's policy (`StateBackend`) and three or more for its counted mechanism; identifiers are in 32 files (§5) |
| 6 Change | Rules a caller must keep that the code does not enforce | code, review | Zero beyond the write order | Zero for writes |
| 6 Change | Components with no conventional equivalent, each with its reason | this document | Each justified in writing | Two (§5) |
| 6 Change | Review rounds per change; repeated holes of one kind | review | A second round of the same kind stops the change | The write-behind layer took four rounds of ordering holes |
| 6 Change | The largest files, where unrelated changes meet | code | No file over 1,000 lines | The daemon's command file, 1,741 lines; the loop's file, 1,444 (start-up and boot included), after Phase 2 moved seven components out (§4.1) |
| 7 Cost | CPU, peak memory, disk kept, disk written, bandwidth; root alone and per extra chain | benchmark, node | The root on one CPU at 5 ms a block and 256 MiB; a chain's writes per block do not grow with the chains hosted | About 4.4 ms CPU per block, 190 MiB, 90 MB kept, 2.9 GB written per benchmark sync; on macOS each added chain of 1,498 blocks costs about 5.8–7.1 s CPU, 18–26 MiB memory, 11–13 MiB kept, 12 MiB of bandwidth, and, with a Volume store per chain (schema epoch 50), 176–192 MiB written (120–131 KiB a block), flat with the chains already hosted, against 307–483 MiB rising before, at CPU within 3% and about thirteen open files a chain (§2, §4.9b) |
| 8 Transfers | Time from deposit to withdrawal on a parent–child pair; share that complete | network, tests | Every transfer completes; in the time its two chains' confirmations take | Not measured |
| 9 Availability | Content requests served; how long a body stays unavailable; hosts per chain | node, network | Two hosts per chain keep every body; none unavailable for an hour | Not measured |
| 10 Mining | Time to answer a template request and a submission; share of work on stale templates | node | A template in 100 ms and a submission in 50 ms at the 99th percentile; at most 1% of work on stale templates | Not measured |

**How the targets were chosen.** Each serves its outcome, in the order of
§1, and reuses what the node already reports.

- *Liveness* is scaled to each chain's own target block time, so one rule
  fits a fast root and a slow child: a chain still for ten of its blocks is
  past any honest gap, and ten minutes covers short block times' noise.
  Time to tip keeps the throughput target the node already meets on one CPU
  (§2), now per chain path.
- *Security* takes Bitcoin's order of magnitude: a stale rate around 1% or
  below, and propagation a small fraction of the block time, since the stale
  rate grows with the share of the block time a block spends in flight. A
  child's security is the parent work that commits it, so every template a
  host builds must carry it.
- *Change*: a file over 1,000 lines is where unrelated changes meet; the
  loop file was twice that.
- *Cost*: the root runs today at 4.4–4.6 ms a block and 190 MiB (§2); the
  target keeps it there. A chain's writes per block must not grow with the
  number of chains hosted, or hosting is not "pay for what you opt into"
  (outcome 7). Measured, they do grow (§4.9b), so this target is missed now.
- *Transfers*, *availability* and *mining* follow from their outcomes: no
  transfer stranded; content survives one host going away; a miner waits on
  the node no longer than a round trip.

Where a target cannot be met by the node alone (propagation, stale rate),
it is still the node's: it decides how fast it relays and what it builds.

---

## 2. Where it stands today

### Measured

| Measure | Value | Where |
|---|---|---|
| Sync, one worker | about 123 blocks/s (73.6–73.9 s for 9,086 blocks) | Linux, GitHub runner, 4 CPUs; code before #137 (main is that code again since #156) |
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

From 10 seconds of samples of a one-worker sync (macOS), before the header
fix (§2, "Why each header arrived 7–13 times"); the profile after it is in
"Where the CPU goes after the header fix". Shares are of busy samples and
include what each calls, so they overlap.

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

### Measured: per chain, by chain count, writes by operation, CID and decoding

**Where and how.** macOS 26.7 on an Apple M4 Pro (14 cores, 48 GB), not the
Linux target: an fsync there does not reach the device, and nothing is
pinned, so wall times and disk timings understate Linux. Counts (blocks,
bytes, reads, pages) do not depend on the machine. Release build of
`perf/measure` (main plus instrumentation that is off unless asked for), one
worker, `BENCH_STATE=recent`, `Benchmarks/sync/native.sh`; the commands are
in the README's "Sync benchmark". Timings come from runs without the trace
(`TRACE=0`); the breakdowns from traced runs, whose wall and CPU they do not
claim. Every figure is a range over the runs named; each was repeated 2 or 3
times and moved by under 2% unless shown. The pinned Linux run is the
`Sync benchmark (Linux)` workflow: push a `bench/` branch, or dispatch it with
the commits to compare; it was not run for this section.

The baseline: 9,086 blocks over four chains in 25.6–25.8 s wall, 41.8–42.0 s
CPU (4.6 ms a block), 187–189 MiB peak memory, 81–83 MiB kept, 2.80–2.82 GiB
written through SQLite (316 KB a block), 461–471 MiB over loopback, both
directions (three runs).

#### Time to tip, per chain

When each chain's act-on tip (what `/status` reports as `height`) first
moved, reached half its recorded height, and reached the producer's tip. The
benchmark polls the follower's tips every 50 ms.

| Chain | Blocks | First moved | Half | At tip | Blocks/s while moving |
|---|---|---|---|---|---|
| Nexus | 90 | 0.1 s | 0.2 s | 0.2–0.3 s | 740–800 |
| Nexus/Alpha | 3,000 | 0.3–0.4 s | 3.4 s | 6.7–6.8 s | 464–469 |
| Nexus/Alpha/Leaf0 | 2,998 | 7.0–7.1 s | 14.3 s | 24.2–25.2 s | 165–174 |
| Nexus/Alpha/Leaf1 | 2,998 | 7.7–7.8 s | 16.0–16.1 s | 25.6–25.8 s | 166–168 |

With seven leaves (the wider tree below, eight hosted children), Alpha
reaches its tip in 3.6–3.7 s, against 3.2–3.3 s when it is the only child;
the leaves first move at 3.8–8.0 s and reach their tips at 27.1–38.3 s, each
at 49–65 blocks/s.

**What it says.** No leaf moved before its parent was at its tip: the first
leaf moves 0.2–0.4 s after Alpha reaches its own, the others over the next
seconds. The leaves then share the node at close rates, and every one of
them reaches its tip near the end of the whole sync: a leaf's time to tip is
the time to sync everything, not its own blocks. A parent is slowed only a
little by its children (Alpha 3.6–3.7 s with seven leaves, 3.2–3.3 s alone). Whether the wait for the
parent is required (a derived child needs its parent's blocks connected) or
only the order work is queued in is not established here. **For Phase 3:**
nothing in representation changes this shape; it is a scheduling property
to set a target for (Outcome 2), not a reason to change formats.

#### Cost by number of hosted chains

A tree of Nexus, Alpha (1,500 blocks) and seven leaves under Alpha (1,498
blocks each), recorded once; the follower hosts Nexus and the first k child
levels (`HOSTED=k`). Two runs each, without the trace; means. Measured with
the header fix below (a child header no longer asks for a parent whose check
is running); the figures before it follow the table.

| Hosted children | Blocks | Wall | CPU | CPU/block | Peak memory | Kept | Written (SQLite) | Written/block | Loopback |
|---|---|---|---|---|---|---|---|---|---|
| 0 (Nexus alone) | 46 | 0.2 s | 0.2 s | 3.4 ms | 41 MiB | 2 MiB | 2 MiB | 46 KB | under 1 MiB |
| 1 (Alpha) | 1,546 | 3.1 s | 5.2 s | 3.3 ms | 94 MiB | 27 MiB | 251 MiB | 166 KB | 12 MiB |
| 2 | 3,044 | 7.0 s | 10.9 s | 3.6 ms | 120 MiB | 40 MiB | 619 MiB | 208 KB | 24 MiB |
| 4 | 6,040 | 15.5 s | 23.0 s | 3.8 ms | 155 MiB | 63 MiB | 1,578 MiB | 267 KB | 50 MiB |
| 8 | 12,032 | 36.8 s | 51.6 s | 4.3 ms | 226 MiB | 109 MiB | 3,901 MiB | 332 KB | 100 MiB |

Each leaf added (1,498 blocks) costs about 5.8–7.1 s of CPU (3.8–4.8 ms a
block, rising with the leaves already hosted), 18–26 MiB of peak memory,
11–13 MiB kept, and 12 MiB of loopback traffic (8 KB a block). The bytes
written per added leaf grow with the number already hosted, as before the
fix: 368 MiB for the first leaf, 480 MiB each from two to four, 581 MiB each
from four to eight (251, 328 and 397 KiB a block). Before the fix, CPU was
5.9, 13.6, 28.4 and 60.2 s for one, two, four and eight children, peak memory
104, 129, 164 and 235 MiB, and loopback 40, 138, 339 and 735 MiB (99 MiB a
leaf); bytes written were the same.

**What it says.** Memory, disk kept and bandwidth grow about linearly with
hosted chains; CPU a little faster (3.3 ms a block with one child, 4.3 ms
with eight); disk written faster still, and the header
fix did not change it. Bandwidth per block is now about 6 times the content
each block stores (8 KB against 1.4 KB; the proofs a child header carries
are most of it). **For Phase 3:** the representation items are worth about
a tenth of CPU each (below); none of them changes the superlinear writes,
which come from how state is stored (next).

#### Disk writes by operation

Every page SQLite wrote, to its log and when copying the log into the
database (the checkpoint), attributed to the table or index the page belonged
to (`PAGES=1`: the benchmark's VFS counts bytes per page number, and every
second maps page numbers to tables and indexes through SQLite's `dbstat`).
A page freed and reused within the second can be misattributed; pages in no
table at the time were 0.3% of bytes. Two traced runs, 2.79 and 2.82 GiB in
all; the first:

| Operation | Tables and indexes | Written | Share |
|---|---|---|---|
| Volume membership | `volume_metadata`, `volume_entries`, and their four indexes | 1,514 MiB | 54% |
| Facts (`state.db`) | admission facts, accepted blocks, headers, proofs, state diffs, child indexes | 404 MiB | 15% |
| Retention | `retained_roots` and its two indexes | 371 MiB | 13% |
| Content | `cas_data` (the bytes: 63 MiB) and its CID key index (305 MiB) | 367 MiB | 13% |
| Bundles (a cache) | `volume_bundles` | 70 MiB | 3% |
| Counts | `counted_roots` and its two indexes | 38 MiB | 1% |

The largest single trees: the `(root, cid)` key of `volume_entries` 510 MiB
(18%), `idx_ve_root` 389 MiB (14%), `idx_ve_cid` 323 MiB (12%), the CID key of
`cas_data` 305 MiB (11%). Of the 2.79 GiB, 1.63 GiB went to the logs and 1.09
GiB to checkpoints; `volumes.db` took 2.25 GiB of it in 1,147 commits, about
285 pages a commit.

What the node handed the Volume store over the same sync: 55,055 entries in
36,877 Volumes, 12.3 MiB of bytes (3.1 MiB of which is their CIDs' text),
and 45,539 roots to retain. Written to disk: 227 times the bytes handed.
State Volumes hold one entry each (27,355 Volumes, 27,355 entries), so every
changed trie node costs a content row, a membership row, a metadata row and a
retention row, each with its own index entries keyed by a 59-byte text CID:
about eleven random-key B-tree changes per node. A random key lands on its
own page: about 530 such changes a commit wrote about 285 pages to the log,
roughly half a 4 KB page each, and the checkpoint wrote most of them again
(an estimate from the counts above, not a per-change measurement).

**What it says.** Content is 2% of the bytes written; the bookkeeping around
it, keyed by text CIDs, is the rest. Two findings beyond representation:
`idx_ve_root` indexes the leading column of `volume_entries`'s own primary
key, so by inspection of the schema it duplicates that key's index for any
lookup by root (14% of all writes; `VolumeBroker` is a dependency); and
giving a trie node its own Volume makes the membership tables (54%) a
per-node cost. **For Phase 3: fixed-width identifiers do not fix the
writes.** The index entries average 65.6 bytes (59 of them the text CID);
binary CIDs (36 bytes) would shrink them by about a third, but with about 48
random inserts a commit into an index of several hundred leaf pages (705 for
`idx_ve_cid` after the eight-child sync), nearly every insert dirties its own
page either way: inferred, about 2% fewer pages written. The writes are a
storage-layout question (Phase 4), not a representation one.

#### CID parsing and repeated decoding

Two measurements. A CPU profile of the follower (`PROFILE=1`, macOS
`sample`; three runs, 16,478–32,283 busy samples each), with each activity's
share of busy samples; time in disk syncs (10–13% more) is left out of
"busy". Shares include what each activity calls, so they overlap. And a count
of every read by CID the node's work made through its content sources
(`TALLY=1`): each such read is hashed and decoded by the walk that asked,
so a CID read twice is decoded twice. Reads served from a job's in-memory
produced states are not counted, so this is a lower bound.

| Activity | Share of busy CPU |
|---|---|
| Content read by CID, hashed and decoded (`fetchAndDecodeNode`) | 14.6–15.6% |
| DAG-CBOR decoding, all callers | 17.3–17.8% |
| of which the canonical check re-encoding what was decoded | 7.4–7.7% |
| Wire frames decoded (`ChainSyncWire.decode`) | 13.5–14.5% |
| of which header entries decoded (DAG-CBOR, proofs) | 9.4–10.0% |
| of which JSON parsed and checked canonical | 4.1–4.5% |
| Base64 | 0.5–0.6% |
| CID text parsed (to a CID) | 8.3–8.9% |
| CID text formatted (from a CID) | 1.8–2.0% |
| Content hashed against its CID | 9.9–10.7% |
| Hashing Swift dictionary and set keys | 4.1–4.5% |
| SQLite | 19.4–21.3% |

About three quarters of CID parsing is checking content against its CID
(content read by CID, and Volumes validated): the check parses the CID's
text to learn which digest to compare. About a tenth is the core turning
text CIDs into its own fixed-width digests (`BlockGraph.handle`).

| Reads by CID | Reads | Distinct CIDs | Reads of a CID already read | Bytes of those |
|---|---|---|---|---|
| Four chains (9,086 blocks) | 131,537–131,544 | 13,456–13,463 | 118,081 (90%) | 33.9 of 42.1 MB |
| Wide tree, Alpha only (1,546 blocks) | 20,330 | 3,254 | 17,076 (84%) | 5.5 of 7.6 MB |
| Wide tree, eight children (12,032 blocks) | 179,399 | 15,407 | 163,992 (91%) | 51.5 of 62.6 MB |

In the four-chain sync, 9,178 CIDs were read 3–4 times and 2,998 (about one
per leaf block) 5–8 times; with seven leaves, 3,010 CIDs (about one per
Alpha block) were read 9 or more times: inferred, a parent's block is read
again for each child derived from it. Reads came from the Volume store
(68%), block header records (22%) and peers (9%).

The wire. Header responses were 94% of what the follower received (428 MiB
of 458 MiB on loopback); Volumes fetched for bodies 7.8 MiB. The follower
received 92,945 header entries for 9,086 blocks: 1.0 per Nexus block, 6.8
per Alpha block, 10.9–13.2 per leaf block. Inside a response, the raw fields
are 74% of the payload (proofs 77% of those, then blocks); base64 and JSON
are the other 26%.

**Why each header arrived 7–13 times, and after the fix.** The requests the
follower sent, matched to the responses (trace): 85% of the header entries
received answered `getAncestors`, the rest `getData`; Nexus sent none. A
child header waits apart until a proof of its work verifies, and checks
answer in any order: a header whose check answered before its parent's
entered the pending queue with its parent neither pending nor weighed, so
it asked its announcer for the parent and up to a page of ancestors
(`ChainCore.evaluate`), all held here already. 319 such asks brought 84,439
entries. Now a header waits while its parent's check or derivation is in
flight, and asks only if that answers and the parent still waits. After it
(three runs, same macOS host): no `getAncestors`, 9,089 header entries for
9,086 blocks, loopback 69–70 MiB (from 461–471), CPU 34.5–36.5 s (from
41.8–42.0), wall 24.0–25.2 s (from 25.6–25.8), wire decoding 1.6–1.8% of busy
CPU (from 13.5–14.5%). With eight children: loopback 100 MiB (from 731–738),
CPU 48.5–48.7 s (from 59.6–60.8). The CPU shares above are from before it.

**What the repeated reads are** (four-chain sync after the header fix,
`TALLY=1`: each CID classed by its top-level DAG-CBOR keys).
118,084 of 131,569 reads repeat one already made:

| What is read | Reads | Repeats |
|---|---|---|
| Child indexes (`children`, `count`) | 36,799 | 36,367 |
| Block nodes | 42,349 | 33,259 |
| Chain specs (three distinct CIDs) | 27,268 | 27,264 |
| Empty maps | 12,001 | 12,000 |
| Child directories (`Alpha`, `Leaf0,Leaf1`) | 12,266 | 9,177 |
| State trie nodes, transactions | about 900 | about 20 |

The tally also labels each read with the job that made it, but reads that
cashew's `CoalescingFetcher` batches together carry the label of the job
that started the batch, so that split is not reported.

Blocks are 81% of the repeated bytes (27.5 of 33.9 MB). State trie nodes are
almost never read twice: a decode cache is a cache of per-block structure,
not of state.

**Where a decode cache can sit.** These reads are resolve walks inside
`ChainTree.connect`, `Block.validateNexus`, `ChildBlockProof.generate` and
`storeBlockContent`, through the node's fetchers; each read's bytes are
hashed and decoded inside cashew (`Header.fetchAndDecodeNode`). A cache
inside the node, at the fetcher or content-source layer, can only hand back
bytes: it saves the store read for a repeat (the Volume store's reads are
9.1% of busy CPU), but not the hash check or the decode, which are most of
the 18.5% under `fetchAndDecodeNode`. Saving those needs the decoded node
kept where cashew decodes it: a hook in cashew, consulted before the fetch
and filled after the decode, keyed by CID and node type, bounded by bytes,
with no invalidation (content-addressed). Not implemented; the design is in
the report that accompanies this section.

**What it says, item by item.**

- **Decode cache: keep, first among the three, as a hook in cashew.** 90% of
  reads by CID are of content already read, rising with hosted chains (84%
  with one child, 91% with eight), and they are blocks, child indexes and
  specs. Read, hash and decode by CID is 17.7–18.5% of busy CPU after the
  header fix, so a cache of decoded nodes would save up to about 16%
  (inferred: assuming every repeated read's hash check and decode is
  skipped, and the bounded cache holds the repeats). A byte cache inside the node would save only the repeated
  store reads (at most about 8%); the rest needs the decoded node kept where
  cashew decodes it. The distinct content read is small (8 MB in the
  four-chain sync), so a small bounded cache holds the working set.
- **Fixed-width identifiers: keep, second.** Parsing and formatting CID text
  is 10.1–10.9% of CPU, most of it the hash check, which with a fixed-width
  digest compares 32 bytes. Part of the 4.1–4.5% spent hashing dictionary keys
  is CID strings, not separated here. On disk, about 2% of writes (above).
- **Binary wire format: defer.** JSON parsing and its canonical check are
  4.1–4.5% of CPU and base64 0.5%; the header entries inside, which any format
  must decode, are 9.4–10.0%. A binary frame would save about 26% of header
  payload bytes. Receiving each header once instead of 7–13 times saved
  85% of the bytes and most of the wire decoding (above); after it, the JSON
  the format would remove is 0.6% of busy CPU. Defer it until bandwidth or
  a measured cost asks for it.
- **Not representation, but as large as one of these items:** the canonical
  check inside every DAG-CBOR decode re-encodes the value, 7.4–7.7% of CPU on
  its own; a decode cache would also spare it for every repeated read.

**How established clients compare** (from their specifications and source,
not measured here). geth and reth keep 32-byte hashes as fixed-width values
and speak RLP on devp2p, where a peer asks for headers by number with a count
and a skip ([eth protocol](https://github.com/ethereum/devp2p/blob/master/caps/eth.md));
geth keeps caches of recent headers, bodies and blocks in its chain object
and a cache of clean trie nodes. Bitcoin Core keeps 256-bit hashes as
`uint256`, speaks a binary protocol, and answers `getheaders` with up to
2,000 headers of 80 bytes
([protocol reference](https://developer.bitcoin.org/reference/p2p_networking.html#headers)).
Ethereum consensus clients send SSZ compressed with Snappy
([p2p interface](https://github.com/ethereum/consensus-specs/blob/dev/specs/phase0/p2p-interface.md)).
None of them keeps identifiers as text inside the node.

#### Without the second index by root, and where the growth comes from

VolumeBroker 10.3.1 (schema v3, node schema epoch 49) drops `idx_ve_root`.
Measured on a scratch branch (`perf/measure` with that commit), on chains
recorded again for schema v3 (the same shapes, other blocks), after the
header fix. Two runs each, without the trace.

| Hosted children | Written v2 | Written v3 | Written/block v3 | CPU v3 | Peak memory v3 |
|---|---|---|---|---|---|
| 1 | 251 MiB | 210 MiB | 139 KB | 5.4 s | 97 MiB |
| 2 | 619 MiB | 520 MiB | 175 KB | 11.6 s | 127 MiB |
| 4 | 1,578 MiB | 1,325 MiB | 225 KB | 23.9 s | 166 MiB |
| 8 | 3,901 MiB | 3,307 MiB | 281 KB | 50.2 s | 237 MiB |
| Four chains | 2,810–2,826 MiB | 2,313–2,314 MiB | 261 KB | 34.7–34.8 s | 189 MiB |

Writes fall 15–18%. Per added leaf they still grow with the leaves already
hosted: 311 MiB for the first, 402 MiB each from two to four, 496 MiB each
from four to eight (212, 275 and 339 KiB a block; v2 251, 328, 397). By
operation (four chains, v3, `PAGES=1`): Volume membership 47%, facts 16%,
retention 16%, content 16%, bundles 3%, counts 2%.

**The mechanism.** Commits do not grow with chains: `volumes.db` committed
165, 389, 829 and 1,715 times for one, two, four and eight children, about
221 commits per leaf every time. What grows is the bytes each commit and
each checkpoint write: the log wrote 0.65 MiB a commit with one child and
0.93 MiB with eight, the checkpoint 0.25 and 0.67 MiB (v2 alike: 0.79 to
1.15, 0.34 to 0.89). Every chain's rows go to the same tables, keyed by
hashes, so a block's inserts land on random pages of trees that grow with
everything hosted (kept 29 MiB with one child, 107 MiB with eight). What
follows is inferred from those counts, not measured page by page: in a
small tree many of a commit's inserts share a page, and a checkpoint copies
a page rewritten by many commits once; as the trees grow, fewer share, so
each insert costs nearer a whole page in the log and again in the
checkpoint (the checkpoint's share rose from 28% to 42% of `volumes.db`'s
writes). Key width does not change this, and no single table causes it:
membership, retention and content per added leaf all grow (149, 194, 245
MiB; 47, 65, 87 MiB; 47, 60, 77 MiB), while facts in `state.db`, keyed by
chain and height, stay nearly flat (50, 57, 61 MiB). **Decision input for
Phase 4:** per-leaf writes per block still grow with the chains hosted.
The inferred cause is the layout, random-key rows every chain shares; Phase
4 gives each hosted chain its own Volume store (§4.9b). The index drop is
worth taking on its own.

**After per-chain stores (schema epoch 50).** The same runs, one each with
the page attribution for what is written, two each without for time and
CPU at four and eight, each build syncing a tree it recorded; after the
reads were made to name their chain (§4.9b):

| Hosted children | Written before | Written after | Written per added leaf, after | CPU before | CPU after | Wall before | Wall after | Peak memory | Kept while running | Open files |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 213 MiB | 204 MiB | — | 5.4 s | 5.6 s | 3.0 s | 3.2 s | 105 → 103 MiB | 29 → 27 MiB | 74 → 91 |
| 2 | 520 MiB | 380 MiB | 176 MiB (120 KiB a block) | 11.3 s | 11.8 s | 6.8 s | 6.9 s | 135 → 138 MiB | 40 → 44 MiB | 74 → 105 |
| 4 | 1,310 MiB | 754 MiB | 187 MiB (128 KiB) | 23.3 s | 23.9 s | 15.0 s | 14.3 s | 163 → 172 MiB | 64 → 78 MiB | 74 → 126 |
| 8 | 3,240 MiB | 1,520 MiB | 192 MiB (131 KiB) | 48.3 s | 49.2 s | 33.3 s | 30.1 s | 234 → 255 MiB | 108 → 138 MiB | 74 → 178 |

Writes per added leaf are flat; each chain's own store writes the same
whatever else is hosted (§4.9b). CPU is within 2–3%, wall time 4–10%
lower; memory, disk kept while running and open files rise with the number
of stores.

#### Where the CPU goes after the header fix

Three profiles of the four-chain sync (v2 schema), shares of busy samples,
overlapping where one activity calls another; disk syncs (12–15% more) are
apart.

| Rank | Activity | Share |
|---|---|---|
| 1 | SQLite (store reads 8.9–9.2%, store writes 10.2–10.8%, facts 4.9–5.1%) | 21.9–22.4% |
| 2 | Content read, hashed and decoded by CID (`fetchAndDecodeNode`) | 17.7–18.5% |
| 3 | Allocation and reference counting | 16.8–17.3% |
| 4 | DAG-CBOR decode (and, apart, encode 12.2–12.8%) | 12.5–12.8% |
| 5 | Execution (connect jobs) | 12.4–12.6% |
| 6 | Content hashed against its CID | 11.3–12.3% |
| 7 | CID text parsed | 9.5–10.1% |
| 8 | Core decisions (`NodeCore.step`) | 7.1–7.5% |
| 9 | Derivations | 6.3–6.8% |
| 10 | Hashing Swift dictionary and set keys | 4.7–5.2% |

Text CIDs now cost 11.4–12.2% (parsed 9.5–10.1%, formatted 1.9–2.1%). Half
the parsing is one function: `Codecs.name` in swift-multicodec
(`Codecs.swift:690`, `"\(self)".replacingOccurrences(of: "_", with: "-")`,
a reflection-based enum description and a Foundation string replace) is
5.2–5.3% of busy CPU, called by swift-multihash's `decodeMultihashBuffer`
(`Multihash.swift:350`) on every CID parsed. Most parses are hash checks
(`verifyContentAddress`), 6.0–6.1% of them of content this node encoded and
hashed a moment before (`verifiedSerializedDataForStorage`, storing a
produced state).

### Not measured, and should be

Liveness per chain path in production over time (reported since #158, §4.4),
propagation and stale rate, each child's share of parent hash rate,
cross-chain transfer time, template latency, and time to tip from a restart.
Per-chain hosting cost and time to tip per chain are measured above on
macOS only; the pinned Linux run of them is still to do.

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
        │   state.db (facts, headers, journal)   volumes/      │ │
        │   synchronous=FULL          (content, a store a chain) │ │
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

The shell's loop (`RT`, `struct Loop`) takes each input, steps the core, and
hands each effect, in the contract's order (§4.1a), to the component that
runs it; a job's or task's result comes back as an input. The components
are structs the loop owns, each in its own file under `LatticeNode/Runtime/`
with only its own state: `JobPool` (workers and queues), `BodyFetches`
(body fetches, their waits, the body windows), `Retention` (the loop's side
of retention: what is let go of as tips move), `Counts` (each chain's counts
on `recent` and their repair), `ReadModel` (views and template digests,
rebuilt from the core), `Maintenance` (peer search, announcements, current
peers) and `TransactionFetches`. No component calls another or reaches into
its state: the loop reads what one needs of another (a level's body window,
a chain's current peers, its queued jobs) and passes it in, and passes
`Counts` to `Retention`'s settles, which wait on it. Most hold only what is
rebuilt from the core or the store; `Counts` holds a state sync's result,
the only copy until its commit. So a change to retention, the read views or
maintenance touches its own file, not the core or how events are processed.

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
| Every dispatched job has a rule for when it is superseded | Yes: each kind's rule is listed; a recheck whose tip moved is dropped, body fetches and count repairs are cancelled, the rest run to completion because their results are facts or are judged again where they land, at a bounded cost |

The contract is written where review keeps it: [the sync architecture's
loop contract](sync-architecture.md#the-loops-contract), the [PR
checklist](../pr-checklist.md), and the doc comment on `NodeRuntime.Loop`.
No job that runs to completion was given a supersede rule: none has a cost
that one would remove (derivations' queue growth is a bound, §4.17, not a
supersede rule).

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

**Performance.** Decoding the wire frames that carry headers was 13.5–14.5%
of CPU, more than executing blocks, because a child header whose proof
verified before its parent's asked for the parent and a page of ancestors
it held: each header arrived 7–13 times. Asked once (§2), it is 1.6–1.8%. **Ease of change.** Easy, in the core.
**Open.** The child gate opens on whichever peer's log ends first; a peer
that is behind opens it early.

### 4.3 Select: fork choice and "caught up"

**What.** Each level publishes a best header tip and an act-on tip, the
heaviest executed block; siblings are ordered by GHOST subtree weight
(`ChainSelection.swift`). The node mines, preflights and answers reads on the
act-on tip. Two one-way latches: `headersSynced` (a peer's log read to its
end with no holes) opens child levels and the relay of peer-learned
entries; `synced` (additionally the act-on tip is the best tip or the
heaviest whose bodies can be had) gates peer transactions.

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

**The latch review (Phase 1).** The latches have been patched three times
(#125, #128, #141) and answer several questions with two booleans. Read
against the outcomes (§1), none of their uses protects agreement: each saves
cost, and each, if it never opened, would break an outcome ranked above
cost.

| Use | Serves | If it never opens |
|---|---|---|
| A child level reads its peers once its parent has weighed a peer's whole log | 7, cost: no weighing headers the parent cannot vouch for yet | 2: the child never syncs |
| Peer transactions are ignored, and announced ones not fetched, until `synced` | 7 and 10: no checks against a tip about to move | 8 and 10: the chain takes no transactions |
| Peer-learned headers are pushed to subscribers | 3 and 2: new blocks reach hosts fast, and a peer reading only from this node keeps following | 3 and 2: propagation through this node stops |

Two principles follow. A gate that saves cost must fail open: if its
condition can never hold, it is a wait with no wake, which §1 calls a bug.
And each use asks its own question, of the facts that answer it.

*Relay, decided.* The relay exists for propagation (outcomes 3 and 2); its
gate (`f84c7f6b`) exists so that a node far behind does not push every
historic header it weighs to each subscriber. That is a question of weight,
not of execution: once this level has weighed a peer's whole log
(`headersSynced`), what it appends is new. Gating the relay on `synced`, an
execution fact, broke sync rule 1 (weight never waits on execution) and let
an execution stall stop propagation. The relay pushes what is new to its
peers: a block this node produced, which no peer has yet, or anything
appended once this level has weighed a peer's whole log (`headersSynced`).
One rule, two facts that establish newness; a node with no peers never
weighs a peer's log, and still relays what it mines. `headersSynced` latches
on any one peer's whole log, so a node that finished a short log while still
reading a longer one pushes what it weighs from the longer one: a page per
step to each subscriber until it catches up. A stricter fact, every peer's
log read to its end, would let one peer that never finishes its log stop
the relay and keep child levels closed: it fails closed, putting cost
(outcome 7) above propagation (outcome 3). The latch, as Bitcoin's leaves
initial download once and does not re-enter it for a lagging peer, accepts
the bounded cost. As Bitcoin's BIP152
high-bandwidth relay announces a block once its proof of work is checked,
before it is validated.

*The child gate, kept.* It came in (`cd2f4fa0`) in place of a per-header
frontier (weighed-state sets, re-asks, a timed let-go): a child header is
weighed only once its parent has weighed the block it anchors on
(`a915b276`), so a child reading its peers beside a lagging parent reads
headers it must drop and ask for again. Reading headers to the end before
anything that hangs from them is Bitcoin's headers-first download. It fails
open in the only sense that matters: it holds only while the parent has not
weighed a peer's whole log, and while that is so the child could not weigh
what it read anyway. Nothing changes.

*The transaction gate, decided.* It asks a question of execution, rightly:
a transaction is checked against the executed tip. `synced` latches when
the act-on tip is the best tip or the heaviest whose bodies can be had; a
body counts as unobtainable once its retries reach the cap (#125, #128). A
child block whose connect waits on a parent fact its parent has not executed
did not count, so a heavier branch through one held the gate shut for good,
with the parent caught up and the fact coming from nowhere (§4.9a's spec
references: "not proven here", retriable, owed by no one). Such a block now
counts as unobtainable once the parent level has caught up, latched and now
(`caughtUp`, passed into the child's step): while the parent is still
syncing the fact is likely on its way, as a body is while its retries are
below the cap. Outside a step, where an own block is weighed or a parent's
run applied, a child level does not know its parent's state and assumes it
is still syncing. The latch stays one-way, as Bitcoin's
`IsInitialBlockDownload` is, and now its condition can always come to hold.

The simulator checks both, at every level of every honest core after the
quiet point: both latches set (`synced` once the level has a tip), and no tip `stalled`
(`LevelInvariants.checkGatesOpen`).

### 4.4 Liveness reporting

**What.** `/status` reports, for each chain path, its acted-on height and
best header height, `tipAdvancedAt` (when the acted-on tip last moved, as
this process saw it) and `secondsSinceTipAdvanced` (#158); `blockedOn`, what
the tip waits on (`atTip`, `headers`, `proofs`, `parent`, `bodies`,
`bodiesUnavailable`, `execution`, or `stalled`), derived in the core
(`ChainProgress`), with the `headersSynced` and `synced` latches and the
chain's queued jobs (#161); and in `waiting`, a block whose receipt proofs
no peer served (#163). `/metrics` reports tip heights for every hosted chain
and `lattice_chain_tip_advanced_timestamp_seconds`. Behind its best header
and not moving is a stall.

**Why.** Outcome 2 is the one failing, and it was not visible as a number.

`sync` also counts pending headers, headers awaiting proof, proof checks
running, the body window, bodies requested, unavailable and parked, and
blocks awaiting parent facts.

**Not added, and why.** Phase 1 also listed the oldest wait and the parent's
status beside the child's. Neither earns a field. How long a chain has been
held is `secondsSinceTipAdvanced`: whatever it waits on, its tip has not
moved since. The parent's status is the parent path's own `/status`, and
`blockedOn: parent` says to read it; copying it into every child's answer
would put one chain's state in another's. Bitcoin Core and geth answer one
chain per call; this answers one chain path per call.

**Simulator assertions.** The same predicates drive the simulator: after
the quiet point, every level of every honest core has both latches set
(`synced` once the level has a tip) and no tip `stalled`
(`LevelInvariants.checkGatesOpen`), in every multi-level simulation
(`LevelSimulator`): the body and proof withholders, the zero-work and
schedule-lying peers, flooders, parent forks up to 0.6 and backward anchors
(`ForwardAnchorSimulationTests`). The Phase 1 cases outside it keep their
own tests and do not run this invariant: withheld bodies at one level
(`WithheldBodiesLivenessTests`), a withheld parent state
(`CrossLevelForkChoiceTests`), reorganisations within and beyond the state
window (`StateWindowTests`), and worker starvation, which is the runtime's
job order (`NodeRuntimeJobOrderTests`).

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
valid blocks' content in one write to the chain's Volume store, then reports verdicts. A
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
`persist` writes executed state Volumes in one write to each chain's Volume store, then every
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
| `volumes/<hash>.db` | one per hosted chain, named by the SHA-256 of its path: its content by hash (bodies, transactions, state trie nodes, its rules), its retention scopes and counted roots; the root's also the constants, specs, policy modules, pins and the mempool's (VolumeBroker 10.3.1) | WAL, `synchronous=FULL` |
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

**What.** Each hosted chain's Volume store (`volumes/<hash>.db`, §4.9b) keeps what a named scope retains; a release reclaims
whatever no scope or count still names, in the same transaction; a full
sweep runs at start.

| Scope | Keeps | Released | For | Concept or detail |
|---|---|---|---|---|
| chain | constants, Nexus genesis; on `state: all` every state created | never | what every node needs for good; on `all`, the archive | concept |
| body (per block) | a block's own Volume, transactions, receipt witness | with `blockBodies: none`, once another block is the tip; when the chain is no longer hosted | serving and re-executing blocks | concept (bodies, beside state) |
| rules (per chain) | spec and policy modules, when state is not `all` | when the chain is no longer hosted | what every block of a hosted chain reads | detail: with `all` they are in chain; a path scheme keeps them as chain metadata |
| reads (per block) | the state a stored block reads, until it executes | after execution or invalidity, and at start; when the chain is no longer hosted | a fetched block's inputs surviving until it runs | detail of a content-addressed store |
| window (per chain and height) | what executions stored, on `recent` and `none` | once the tip is a window above, after the counts reach the tip; when the chain is no longer hosted | recent history: reorganisations within the window without a peer | concept (geth's in-memory layers and reverse diffs); per-height scopes are the detail |
| counted (per chain) | on `recent`, every node of the current state, by count | moved with the tip; dropped when the chain is no longer hosted | the current state | the concept is current state; counting nodes is this scheme's detail |
| staging | what a state sync or heal fetched | once the counts move; when the chain is no longer hosted | a sync's progress surviving a crash before it commits | detail |
| operator | pins | on unpin | the operator's promise | concept (beside state) |
| durable / live mempool | journaled and pooled transactions | as they leave | the journal's promise; the live pool's cache | concept / detail |

**The interface.** `StateBackend` (`Runtime/StateBackend.swift`) is what the
node does with executed state: keep what a block's storing and execution
stored (`keepExecuted`, `keepStored`, `keepWithValidBlock`), let go of what
a block read once it executed or was found invalid (`releaseReads`), move
with each chain's act-on tip (`letGo` below the window, and the counts'
move, commit, heal, sync and audit, roll-back included: a move to a tip on
another branch within the window is a move like any other), bring the
current state into reach at a start (`start`: reads, earlier versions'
state, counted scopes); a chain the configuration no longer hosts has its
data let go of (`NodeStorage.letGoOfChains`). The
three settings, `all`, `recent` and `none`, are behind this one type, a
struct with a `scheme` field read from the configuration (which does not
change while the store is open): the write paths and the store's start
choose by it there, and the loop's `Retention` (`settleState`, `maintain`)
and `Counts` ask it (`keepsAll`, `counts`, `window(for:)`) rather than
reading the setting. One struct, not a protocol: the three share their
mechanism (`none` is `recent` with a window of one and no counts), and no
second mechanism is being built: Phase 4's per-chain stores keep scopes
and counts. A different mechanism (geth's path scheme) would change this
type, `Counts`, `Retention.settleState` and the scope-to-roots map
`keepExecuted` gives the write path. The mechanism stays in `NodeStorage+Retention.swift`
(scopes, pins, releases, the counts' moves, checks, heals and syncs) and
`NodeStore+StatePins.swift` (state diffs). Reads stay on the store's
fetchers. Bodies and operator pins are beside it, not inside: they are
content the node serves or promised to keep, whatever state it keeps.

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
hash-addressed encoded nodes. **Ease of change.** Medium: a change to a
setting's policy is in `StateBackend`; a change to the counted mechanism
crosses `StateBackend`, the loop's `Counts` and `Retention`, the store
(`NodeStorage+Retention.swift`, 521 lines; `NodeStore+StatePins.swift`,
181) and VolumeBroker's counted index. **Judgment.** The largest remaining
machinery and the biggest disk cost. No established client counts references
to retain trie nodes on disk; geth moved away from hash-keyed state. Phase 4
gives each hosted chain its own Volume store, which removes the measured
growth across chains (§4.9b); geth's path scheme stays the nearest shape if
one chain's own growth ever misses a target.

### 4.9a Decision: receipt proofs travel with the child block

**The failure.** Testnet nodes stopped child chains at height 3,920 (as
reported by the owner's investigation). Block 3,921 carries a withdrawal. A
withdrawal is checked against a receipt in its parent's state at the block's
anchor, `parentState.receiptState`. The block's body was stored before #119,
so it carries no receipt witness, and every host runs `state: recent`, so no
node still holds that Nexus state. No node can execute the block.

**What the protocol says.**

- A withdrawal is the only thing in a child block that reads its parent
  state's contents: a proof of the receipt in `parentState.receiptState`
  (spec §7.3, §8.1 phase 3, §8.3). A child genesis and parent continuity
  rest on what the parent executed, not on its state's contents (§5.3 step 6).
- The anchor can be any state the parent executed (§5.3 step 6, §9.5), and a
  child may be synced long after its anchors were current. A receipt being
  immutable does not let today's trie stand in for the anchor's: a receipt
  inserted after the anchor must fail against it, and one inserted only on a
  parent branch that lost exists only under the old root.
- The parent-receipt closure is "validation witness data outside
  `maxBlockSize` … each node bounds acquisition before decoding it", and
  receipt keys are hashed into 64-character hex paths "because a child may
  need that proof from a remote same-chain peer" (§3.5). The protocol
  intends a per-withdrawal witness.

**Decision.** Every child block with withdrawals has a sidecar: the
parent state trie nodes its withdrawals' receipt proofs read, from its
`parentState` down each receipt's path (`Block.parentReceiptWitnessPaths`).
The sidecar is not part of the block: the block's bytes, CID and
`maxBlockSize` are unchanged. It is indexed next to the block in the child
chain's store, kept and released with it, and sent whenever the block is
sent: a peer that asks for the block gets the block, its transactions and
its sidecar in one bundle. A block with withdrawals is complete only with
its sidecar: a node does not connect one, or take it from a peer, without
it. Whoever produces the block can always build them, since a
child block anchors at its carrier's entering state, the one its miner builds
on. Old parent state is then never needed to execute a child block, on any
retention setting, by any node, whenever it hosts the child.

**What the code already does (#119, #129).** The sidecar is retained under
the block's own scope (`body(cid)`) and listed in the block's bundle record
(`volume-bundles.db`, keyed by block CID). A block fetched from a peer
requires it, counted against the fetch's byte reservation; a block the node
executed is stored only with it; a served block's bundle includes it. A new
block is advertised by its header, in its chain's header log, and peers pull
the block and sidecar from its hosts, as Bitcoin and Ethereum announce a
block and send its body on request; pushing the sidecar with the header
would send it to peers that never execute the child. The sidecar's nodes are
content addressed and checked against the block's `parentState`, so they
may be taken from any peer; the child's hosts are the ones sure to hold
them, since they keep them with the block. Every block a node executes,
mined here or fetched, is stored through the connect job
(`storeValidBlocks`), which stores one with withdrawals only with its
sidecar; the content-first write of a block this node mines takes the
sidecar when it can, and the block still executes only with it. The rule
needs no code change.

**Size.** A receipt path is about six trie nodes at a million receipts
(16-way branching on hashed keys), each up to about 1.2 KB: roughly 6–8 KB
per withdrawal, with the upper levels shared among a block's withdrawals.
Estimated from the trie format, to be measured. It is paid only where
withdrawals happen, by the hosts of that child, for as long as they keep its
bodies.

**Alternatives.**

| Approach | Works for | Cost and shape | Verdict |
|---|---|---|---|
| `state: all` on some nodes (archive) | any node that can reach one | every version of all state; liveness rests on operators running archives | rejected: an operator role for a protocol need |
| A long state window for the parent | a node that sets it | the parent's recent state; a setting to get right per network | rejected: configuration, not design |
| Hold a parent state until hosted children execute past it | a node syncing parent and children together | couples retention to other chains' progress; a stuck child holds state unless bounded | rejected: inelegant, no help to a node that hosts a child late |
| Keep every version of each chain's receipt state | any node | about 7 KB per receipt ever made, forever, on every parent host (about 35 times the trie) | rejected: size, paid by every parent host for every receipt |
| **A sidecar indexed and sent with the child block, required** | **any node, any child, hosted whenever** | **the paths each withdrawal reads, kept with the block** | **decided; the spec's design** |

**How others do it.** Ethereum's blob sidecars (EIP-4844) travel beside a
block, outside its body, and are kept with it. Bitcoin blocks carry
everything validating them reads beyond the node's own state. Ethereum's stateless-client work carries state
witnesses with blocks, and moved toward Verkle trees because Merkle-Patricia
witnesses are large: the same tradeoff, at much higher volume. Cosmos IBC
proves packets against a counterparty's state at a past height, and its
relayers need nodes that keep that state: the shape this avoids.

**Legacy bodies.** Bodies stored before #119 lack the witness; as far as is
known, only testnet's 3,921 has a withdrawal among them. One node executes
Nexus again from genesis keeping its state (about 6,300 blocks; a wipe on a
node that let it go), executes 3,921, and stores and serves its body with
the witness. Other nodes fetch the complete body. Nothing is kept afterwards.

**How it is tested.** A follower on `recent` with a small window syncs a
parent and a child whose withdrawal is anchored below the parent's window
and executes past it, from the sidecar alone. A block with a withdrawal
whose sidecar no peer serves is not connected.

### 4.9b Storage: three requirements, one mechanism (Phase 4 analysis)

**Three requirements.** What the node stores serves three different needs:

1. *Current state*: every execution and every transaction check reads the
   act-on tip's state, and each block writes its changes.
2. *Recent history*: a reorganisation within the state window is undone
   without fetching anything (§4.19).
3. *Old content*: peers syncing from scratch need old bodies and, with
   them, their receipt proofs (§4.9a); nothing in sync needs old state.
   Old state matters only to readers of past state, on `state: all`.

Today one mechanism serves all three: content-addressed trie nodes in the
Volume store, kept by retention scopes, per-height windows and a counted
index of the current state (§4.9).

**What it costs (Phase 3, measured on macOS, §2).** About 2.8 GiB is
written to keep what the stores are handed, 12.3 MiB, 227 times over. By
operation: the Volume store's membership tables 54%, facts 15%, retention
13%, content and its CID index 13% (the content itself 2%), bundles 3%,
counts 1%. One index, `idx_ve_root` in `VolumeBroker`, repeats the index of
its table's own primary key and is 14% of all writes. Writes per added
chain grow with the chains already hosted (245, 320, 396 KB per block for
the second, third and fourth), so disk written grows faster than the
number of chains.

**Options.**

| Option | Current state | Recent history | Old content | Writes | Change |
|---|---|---|---|---|---|
| Keep; drop the redundant index | trie nodes by CID | per-height windows | bodies and sidecars | about 14% fewer | one schema change in `VolumeBroker` |
| geth's path scheme | one trie, nodes by path | reverse diffs, a window of in-memory layers | unchanged | in place: no new node per version | the retention backend (§4.9, Phase 2's interface) |
| Flat state and changesets (Erigon, Reth) | key–value state; the trie hashed separately | changesets per block | unchanged | far fewer random writes | the state layout and its hashing |
| Bitcoin's UTXO set and undo data | not this model | — | — | — | does not apply to account and trie state |

The path scheme and flat state answer requirements 1 and 2 with structures
built for them, and leave 3 to bodies and sidecars as now. Either would
replace the retention mechanism: `StateBackend`, `Counts` and the write
path's retention map (§4.9). Neither changes consensus bytes, which hash
the trie, not its storage.

**Decision.** The per-chain cost target (§1: a chain's writes per block do
not grow with the chains hosted) is missed, so Phase 4 starts. First drop
the redundant index: it is measured and changes no design, and the Volume
store's own schema v3 (VolumeBroker 10.3) already drops it, so it is a
dependency bump and one wipe (schema epoch 49).

Measured again on schema v3: total writes fall 15–18%, and a chain's writes
per block still grow with the chains hosted (212, 275, 339 KiB per block
for the second, third and fourth leaf). The cause is measured too: commits
per chain do not grow, bytes per commit do. Every chain's rows share the
same hash-keyed tables, so as they grow, fewer of a commit's inserts share
a page, and each insert costs nearer a whole page in the log and again at
the checkpoint (the checkpoint's share 28% → 42%). Facts, keyed by chain and
height, stay flat. Random keys shared across chains are the cause, not key
width and not one table.

**Options against that cause.**

| Option | What it changes | Fixes the cause | Cost and risk |
|---|---|---|---|
| One Volume store per hosted chain | a store file per chain path, beside `state.db` | yes: a chain's tables hold only its rows | a commit per touched chain per step; a file per chain |
| Rows keyed by chain within one store | the Volume store's keys and indexes | yes: each chain's rows cluster | a schema change in `VolumeBroker`, another repository |
| geth's path scheme | the state model: nodes by path, reverse diffs | yes, and in-place updates besides | the largest change; a new backend for `StateBackend`, `Counts` and the write path |
| Larger pages, WAL tuning | settings | no: it scales the same growth | cheap; no target met |

**Chosen: one Volume store per hosted chain.** It removes the cause with the
smallest change in this repository, and it matches what a chain is in
Lattice: hosted by the nodes that opt in, independent of its siblings.
Retention scopes and counts are already per chain, so they move with their
chain's store unchanged; unhosting a chain removes its file. Reads compose:
a chain's executions read its own store and its ancestors' (a child's
receipt proofs travel with its blocks, §4.9a); a read by CID from the API or
a peer asks every store. Content is written before the facts that name it,
store by store, then the facts in one `state.db` transaction, as now: a crash
between stores leaves content no fact names, which the start-up sweep
removes. The cost is one more commit per chain a step touches; a step
usually touches one or two. geth's path scheme stays the next step if one
chain's own growth over time ever misses a target.

**Result (schema epoch 50, measured on macOS).** Built as chosen:
`VolumeStores` (`Storage/VolumeStores.swift`) owns a store per hosted chain
under `volumes/`, and routes by chain path. A chain's writes go to its
store; its work reads its own store, then its ancestors' (a template's and
a mined block's, its descendants' too); only a read by CID from the API or
a peer asks every store. The root chain's store also holds what is the
node's: the protocol constants, the Nexus genesis, policy modules and child
genesis specs, the operator's pins and the mempool's journal pins. A step's persist writes the store of each level whose executions
it journals, and the root's for a child genesis's spec it weighs; a
connect step executes one level, so most write one store, and a crash
between two leaves content no fact names, which the next start sweeps.
Unhosting a chain lets its windows, rules and counts go as before and keeps
its store, bodies included, until the next start removes it: a job of the
chain still running writes to a store that is there, and a chain hosted
again in the same run finds its bodies. Files are named by the SHA-256 of
the chain's path.

The target is met: a chain's writes per block no longer grow with the
chains hosted. Each leaf's own store writes the same 118–120 MiB whether
two, four or eight children are hosted, and Alpha's 133–134 MiB whether
one or eight; per added leaf the follower wrote 176, 187 and 192 MiB in all
(120, 128 and 131 KiB a block, against 210, 270 and 330 before), the rest
being its facts in `state.db`, which grow slightly (48 to 57 MiB a leaf).
With eight children the sync writes 1,520 MiB against 3,240 (53% less).

The first build cost 17% more CPU with eight children. Profiled, it was
reads: the Volume store's reads went from 9.8% to 20.2% of busy samples
while its writes fell, because reads that named no chain asked the stores
one by one, root first, and missed in all but one (a body's fetch walked
every store for each entry before asking peers; so did the work fetchers
and the connect job's check of the block's own Volume). A chain's reads now
ask its own store, then its ancestors', and nothing else (a template and a
mined block also their descendants'); each chain keeps one fetcher, and its
reading order is worked out when the set of stores changes. With that, CPU
is within 2–3% of the single store (49.2 against 48.3 s with eight
children, 23.9 against 23.3 s with four; busy samples equal), and the sync
is 4–10% faster (30.1 against 33.3 s with eight): the stores' writes and
checkpoints no longer contend. What remains: reads that miss a leaf's store
and its ancestors' before going to peers (store reads 12.9% of busy against
9.8%, offset by writes), peak memory 6–9% higher (each store has its own
page caches), and open files 74 to 126 and 178, about thirteen a store (its
file, log and shared memory, and four read connections, which VolumeBroker
does not let a caller reduce). Disk kept reads 20–30% higher while the node
runs (138 against 108 MiB with eight): each store holds its log up to 4 MiB
(`journal_size_limit`), nine logs here. Closed, the stores are the size of
the one store (101 against 100 MiB), with under 1 MiB of free pages.

**Recovery contract, as the code stands.**

- Content (a body, its sidecar, a mined block) is stored, fsynced, before
  anything names it.
- Each step's state and facts commit in one `state.db` transaction, after
  the content they name and before anything is published (§4.7). A start
  finds every step either whole or absent.
- Releases (a window, a body, what a block read) run after the step; a
  release lost to a crash leaves content kept longer, never content missing
  that a fact names. A start sweeps what no scope names.
- The counts (on `recent`) are moved after the step under a marker; a crash
  leaves them at an earlier marker, and a start audits them and heals or
  syncs them again.
- An acknowledged transaction is journaled before it is acknowledged.

### 4.10 Workers and scheduling

**What.** `max(1, processors − 1)` workers; three queues served strictly in
order — what an RPC waits on, each chain's next blocks, the rest — first in,
first out within each; a recheck whose tip moved is dropped
(`Runtime/JobPool.swift`: `JobQueues`, and `JobPool`, which owns them and the
running jobs).

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

**Performance** (§2, after the header fix). Text CIDs cost 11.4–12.2% of
busy CPU, half of it one codec-name lookup in swift-multicodec; reading,
hashing and decoding content by CID 17.7–18.5%, 90% of it repeated reads;
the wire format's JSON 0.6% (before the fix, when each child header arrived
7–13 times, wire decoding was 13.5–14.5%). **Ease of change.** Split: the
wire format sits in one codec file and its adapter (easy); identifiers appear
in 32 files including the core (hard but mechanical). **Judgment** (decided
on these measurements). (1) The binary wire format is deferred: what it
removes is 0.6% of CPU and 26% of header bytes. (2) The decode cache is a
hook in cashew (`DecodedNodeCache`, consulted in `fetchAndDecodeNode` before
the fetch, filled after the decode, keyed by CID and node type, bounded by
bytes, no invalidation), worth up to about 16% of CPU (inferred); it waits
on a cashew release. (3) Fixed-width identifiers are deferred: first the
codec-name lookup as a table and a hash check that compares digests without
building a multihash, then measure what text CIDs still cost before
touching 32 files.

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
| Worker queues | per step, not in total: a level's proof checks of a step are one job, a page under a byte budget; its derivations at most one per worker; its connects one at a time; a mining recheck whose tip moved is dropped. On the child-sync benchmark the peak queued fell from 1,993 jobs (one per derivation) to 23, with 7–9% less CPU and the same wall time. Steps can still queue faster than workers drain them; no total bound |
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
| Write order and persistence | the loop's persist effect, two store files and `VolumeStores` (a Volume store per hosted chain, routed by chain path) | two | Bitcoin's order; a store per chain, as a chain is hosted by those that opt in | **easy** |
| State retention | `StateBackend` (the three settings, one type), the loop's `Retention` and `Counts`, the retention and state-pin store files (the mechanism), VolumeBroker's counted index | one for a setting's policy; three or more for the counted mechanism | the shape of triedb's or a `StateProvider`'s interface, over one mechanism; no established client counts references on disk | **medium** |
| The shell's loop | `NodeRuntime.swift` (1,444, start-up and boot included) | one | receives input, steps the core, dispatches effects to the components below, takes results back; Bitcoin Core's `PeerManager` and validation-interface subscribers, geth's handler and fetchers | **easy** |
| Read model | `ReadModel.swift` (167) | one | a chain-head subscriber that rebuilds views; owns no authoritative state | **easy** |
| Maintenance | `Maintenance.swift` (286) | one | peer search and provider announcement, off the loop | **easy** |
| Body and transaction fetches | `BodyFetches.swift` (214), `TransactionFetches.swift` (93) | one | geth's block and transaction fetchers | **easy** |
| Work queues | `JobPool.swift` (137) | one | one pool with queues | **easy** |
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

- ~~Land per-chain liveness reporting (§4.4), deploy it, and diagnose the node
  stopped at height 3,920.~~ Done: #158, #161, #163; the cause is in §4.9a.
- ~~Review what `synced` and `headersSynced` encode, and derive readiness
  from facts (§4.3).~~ Done: the relay waits on weight; the transaction gate
  counts a block not proven here as unobtainable; the child gate is kept.
- ~~Report the blocking phase, the oldest wait, pending jobs and the parent's
  status per chain (§4.4).~~ Done (#161); the oldest wait and the parent's
  status are answered without new fields (§4.4).
- ~~Simulator scenarios for starvation, missing bodies, delayed proofs,
  parent–child stalls, and reorganisations at several depths (§4.19).~~ The
  scenarios existed; every one now asserts liveness at its quiet point
  (§4.4).
- ~~Receipt-proof sidecars travel with child blocks, and testnet's block
  3,921 is repaired once (§4.9a).~~ Done: the decision is #162, the report
  and the operator's repair #163, and testnet was repaired.

- A pending header whose announcers are all gone, or that never had one (a
  child header submitted here), waits until a peer sends it again. Asking
  the level's peers on a tick (fail open) disconnected honest peers as
  `proofOfWorkInvalid` in the level simulator: settle how an answer to an
  ask the peer never announced is judged, then fail open.

*Exit:* no unexplained stalled chain in production; every known blocking
condition is observable and recoverable.

**Phase 2 — Reduce complexity (high).** Make the node easier to understand
and to change.

- ~~Make the runtime coordinator boring: receive input, step the core, run
  effects, take results. Move the read model (views, digests), maintenance,
  and count repair out of the loop file, each behind the effects it already
  is, none owning authoritative state.~~ Done, behaviour unchanged: the loop
  keeps the core, the sessions and RPC replies, input dispatch, stepping and
  effect order, and hands each effect to one component under
  `LatticeNode/Runtime/`, passing in what it reads of the others —
  `ReadModel.swift` (167 lines: views, digests, fee reprojections),
  `Retention.swift` (129: the body working set, reads to release, state
  tips), `Counts.swift` (238: counts and their repair), `Maintenance.swift`
  (286: peer search, passes, announcements, current peers, pins),
  `BodyFetches.swift` (214: fetches, waits, body windows and the read
  cache's order), `JobPool.swift` (137: running and queued jobs),
  `TransactionFetches.swift` (93). `NodeRuntime.swift` went from 2,232
  lines to 1,444 (the 2,223 measured earlier was before Phase 1's last
  changes), about 880 of them the loop. Sessions stay in the loop: their
  changes start maintenance and retry repairs, and every network input
  reads them.
- ~~Put state retention behind one interface (load current state, apply a
  block, roll back, read, prune), without changing its behaviour, and write
  down what each retention scope is for; some may be implementation details,
  not concepts.~~ Done, behaviour unchanged: `StateBackend` (§4.9), with
  each scope's purpose and whether it is a concept in §4.9's table.
- ~~Write the loop's contract (§4.1a) and the persistence order down, and test
  a crash at every boundary, retention releases and count repair included.~~
  Done: the contract and the order are in the [sync
  architecture](sync-architecture.md#the-loops-contract) and the PR
  checklist; `RetentionCrashTests` crashes a node at retention writes after
  a step (body let-go, reads, window, the counts' move, commit, staging,
  sync), in the start-up sweep (bodies, reads, earlier and unhosted state,
  counted scopes) and while a chain is let go (windows, rules, counts),
  restarts it over the same store, and checks it follows on and keeps only
  what it should. The persist boundary itself was covered
  (`BatchedConnectRuntimeTests`, the simulator's crash modes). Not covered:
  an invalid block's body and a heal, which a follower of an honest producer
  does not reach; and the start's reads sweep is not mutation-checked, since
  only a child genesis's empty state is ever kept as reads.
- ~~Bound the worker queues~~ (derivations batched per level and step;
  §4.17); make per-chain resource use visible (§4.17).
- ~~Correct the sync architecture's rule 4 to the queues that are built.~~ Done (#160).

*Exit:* a change to retention, API views or maintenance needs no change to
the core or to how events are processed.

**Phase 3 — Improve representation (medium).** Less CPU and allocation,
consensus unchanged.

- The Linux benchmark pinned to one CPU is in place (`Benchmarks/sync`,
  `FOLLOWER_CPUS`); add time to tip per chain as well as throughput (the
  report has it now; measured on macOS in §2).
- Each header received once (done: a child header no longer asks for a
  parent whose check is running; loopback 85% less, CPU 13–19% less).
- The binary wire format: deferred (§4.12); its JSON is 0.6% of CPU now.
- The decode cache as a cashew hook (§4.12), when cashew releases it: up to
  about 16% of CPU.
- Measure repeated CID parsing and repeated decoding before adding any cache
  (done on macOS, §2: 90% of reads by CID repeat, CID text is 10–11% of CPU).
- Fixed-width identifiers: deferred (§4.12). First the codec-name lookup in
  swift-multicodec (5.2–5.3% of CPU) and a digest-comparing hash check; then
  measure what text CIDs still cost.
- Break down the write amplification by operation (done on macOS, §2:
  content 2%, its bookkeeping keyed by text CIDs the rest).
- Measure memory, bandwidth and CPU as the number of hosted chains grows
  (done on macOS, §2; writes grow faster than linearly).

*Exit:* a measured improvement against the baseline, with no regression in
compatibility or correctness.

**Phase 4 — Simplify storage (when an objective needs it).**

- ~~Separate what current state needs, what recent history needs, and what
  serving old content needs.~~ Done: §4.9b.
- ~~Evaluate geth's path scheme and flat state with changesets against
  them.~~ Compared in §4.9b, from the measured writes; restart time not yet
  measured.
- ~~Drop `VolumeBroker`'s redundant `idx_ve_root` (about 14% of writes).~~
  Done: VolumeBroker 10.3.1 (its schema v3 already drops it), schema epoch
  49, one wipe. Measured after it, a chain's writes per block still grow
  with the chains hosted (§2), so:
- ~~Give each hosted chain its own Volume store (§4.9b).~~ Done: schema
  epoch 50, one wipe. A chain's writes per block no longer grow with the
  chains hosted (120–131 KiB a block per added leaf, flat; 53% less written
  with eight children), CPU within 2–3% once reads name their chain, wall
  time 4–10% lower; it costs 6–9% more memory, each store's log while
  running, and about thirteen open files a chain (§2, §4.9b).

*Exit:* a simpler storage model with measured benefits and a written recovery
contract.

**Phase 5 — Operational maturity.**

- Per-chain resource budgets (CPU, memory, disk growth per million blocks,
  bandwidth, outstanding work, restart time). Measured per added chain by the
  benchmark (§2); outstanding work per chain is reported
  (`lattice_chain_jobs_queued`). Disk and memory cannot be attributed per
  chain inside shared stores; the targets are §1's.
- Propagation, stale-block and child hash-share measurements on the network.
  Not done: they need observations of the live network.
- Cross-chain transfer completion; template latency. Not done.
- ~~Operator alerts~~ Done: per-chain `/metrics` (what the tip waits on, the
  latches, queued jobs) and `deploy/prometheus/lattice-alerts.yml`.
  Recovery procedures: the operator guide's common failures, with the
  receipt-proof repair (#163). Long-running and capacity soak tests: not
  done.

*Exit:* operators can understand a node's health, capacity and recovery
without a developer.

**Simplify after measuring, along the way:** the template cache (#62) and the
backlog refusal (#91), one at a time, after measuring template latency, cache
hit rate and stale submissions; #97, #92, and #108's incremental body order.

**Keep:** the deterministic core, the serial loop, synchronous writes, SQLite,
sequential execution per chain, the three work queues, the journal before
acknowledgement, the separate mining process — each until a measurement
against an agreed target says otherwise.

### Decisions taken

1. Liveness first (Phase 1).
2. State retention behind one interface, behaviour unchanged (Phase 2).
3. Representation in the order the measurements give (§2): the header
   redundancy and a decode cache before identifiers; the binary wire format
   last, if at all.
4. Receipt proofs travel with the child block, as an indexed sidecar (§4.9a).
5. The latch review (§4.3); storage per §4.9b; the targets above.

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
