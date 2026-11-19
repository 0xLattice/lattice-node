# Sync architecture: modules, roles and rules

> **Status: agreed target design.** The code does not follow all of it yet.
> [Where the code departs](#where-the-code-departs) lists the gaps. A change to sync, storage or the wire is reviewed
> against the rules here ([PR checklist](../pr-checklist.md)).

Sync was rebuilt several times, each time after a node stopped making
progress, and each fix was a sound local decision. This document is the
global design those decisions are checked against. Nothing in it changes a
hashed byte or a consensus decision; the [protocol
specification](https://github.com/0xLattice/Lattice/blob/57.5.0/docs/spec.md)
stays normative.

## What sync produces

For each hosted chain, sync produces two things with different inputs:

- **Weight**: the heaviest header chain. A child header's weight needs its
  own headers and proofs and the parent's weighed graph (spec §9.9, §9.10).
  It is cheap and verifiable.
- **Execution**: validated state at a tip, which is what the node acts on. A
  child block's execution needs its body, its parent block's state and a
  continuity fact from the parent's executed set (spec §5.3 step 6, §9.5).
  It is expensive.

These are two dependency graphs. Cheap work never waits on expensive work.

## Modules

Every chain runs the same five modules. Each has one job, named inputs and
outputs, and things it must not know.

| Module | Job | Reads | Produces | Must not know |
|---|---|---|---|---|
| Weigh | Admit headers and verify their work | Peers' header logs and proofs; parent work facts | The weighed graph | Bodies, execution results, availability |
| Select | Choose the best header tip and the act-on tip | The weighed graph; the validated set | The two tips; the blocks that matter next | Peers, time, storage |
| Fetch | Obtain the content Select says matters | The wanted list; providers | Bodies and state, or "not yet" | Validity: it never judges |
| Execute | Validate blocks in parent order | Body, parent block's state, parent continuity fact | The validated set, exclusions, continuity facts for children | Peers, fork choice |
| Serve | Answer peers and relay | The weighed graph; held content | Log pages, bodies | Whether a peer is honest |

Three services belong to the node, not to any chain:

- **Lanes**: a queue per kind of work, and per chain for execution and
  header work. Work in one lane never
  queues behind work in another, and shared resources have limits, not
  ordering policies.
- **Store**: a verified cache of what the network holds. Writes are atomic
  and ordered. State changes are buffered in memory, read from the buffer,
  and flushed to disk in one atomic batch when the buffer reaches its limit; nothing waits for each write to reach disk
  except a promise to the operator.
- **Progress**: every module reports what it is waiting on, as a typed
  reason.

Between chains exactly two facts cross, both from parent to child:

1. **Work facts**: the parent's weighed graph (carriers, their `children`
   index, runs) feeds the child's Weigh.
2. **Continuity facts**: the parent's executed set feeds the child's Execute.

At any moment each piece of work is in one of four states: running; ready,
in a lane that will run it; waiting on another module's output; or
waiting on something outside the node, with a wake registered. A stall is
work in none of the four.

## Concurrency: one loop decides, lanes execute

Decisions are made in one place and each kind of work has its own queue, as
established clients are built. The node has no scheduler of its own.

| What | Runs on | Why |
|---|---|---|
| Decisions: every step of the core | One serial loop | It stays deterministic and simulated. The core took 9% to 16% of wall time in the first baseline |
| Execution of a chain's blocks | One lane per chain, one job at a time: a batch of up to `connectBatch` ready blocks, one atomic change set | A chain executes in order anyway; chains run side by side |
| Header work: proof checks and derivations | Its own lane per chain | It never queues behind execution. Batched per page |
| What an RPC waits on | Its own lane | Latency |
| Storage writes | State buffered in memory and flushed in batches on a size limit, as Bitcoin Core's coins cache (`-dbcache`) and geth's trie database do | The loop waits on a flush, not on every write |

The loop only decides. It does not wait on each write, read content, or do
bookkeeping that is not a decision. Each lane offers only its next job, and
free workers take those lane heads in the order they became ready, so no
lane's backlog stands in front of another lane's next job. The operating
system shares the CPU among lanes; there is no priority and no time
accounting. A loop per chain would parallelise only the share the core
takes and would cost the single deterministic step order the simulator
depends on. Because only two facts cross between chains, a chain's decisions
can still move to a loop of their own later.

## Node roles

| Role | Holds | Executes from |
|---|---|---|
| Archive | All bodies and all historical state | Its own store only |
| Full | All current state and a recent window | Its own store only |
| Light | Headers, plus what it has fetched | Witnesses fetched from full or archive nodes |

## Store layout

Content-addressing is for what is immutable and shared between nodes.
Mutable current state is stored by position. The trie remains the
commitment; storage does not mirror it.

| What | Stored as |
|---|---|
| Block bodies, transactions, chain specs, policy modules | Content-addressed, by hash, in the content store |
| Current state | One copy: values by key, trie nodes by path |
| Undo records | Per block, each changed key with its prior value, for a window |
| Headers, facts, proofs, cursors | The node's own tables |
| "State reflects block X" marker | Per chain, in the same transaction as state and facts |

Durable writes are kept for promises to the operator: an acknowledged local
transaction, pins and configuration. The node makes no durability promise
for a submitted block: the miner keeps what it mined until it sees it on
chain.

## Rules

A change satisfies all fifteen. A change that needs to break one changes the
rule here first.

1. **Weight never waits on execution**, its own chain's or its parent's.
2. **Availability never judges**, and never gates another chain's weight.
3. **Exactly two facts cross between chains**: work facts and continuity
   facts.
4. **One loop decides; lanes execute.** Work of different kinds never shares
   a queue, and neither does execution of different chains. Shared resources have limits, not
   ordering policies. There is no scheduler to tune.
5. **Every wait is typed and visible.** A timer may end a wait on something
   outside the node; it is never the reason work inside the node proceeds.
6. **Decisions live in the core.** The shell executes effects and reports
   results.
7. **Every liveness rule has a simulator scenario**, and every performance
   claim has a benchmark number.
8. **The network is the durable record.** Consistency is strict and
   durability catches up: local storage is a verified cache.
9. **Writes are atomic and ordered, always.** A restart resumes from a
   consistent earlier state and re-syncs the rest.
10. **Content is verified once, where it enters.** Modules pass verified,
    decoded values, never raw bytes.
11. **Weigh, Fetch and Execute costs are measured by the sync benchmark**
    (W, B, E, P). A change that makes one worse states why.
12. **Consensus bytes are fixed; representation is the node's.**
    Identifiers, wire format and storage layout are private to the node and
    convert only where bytes are hashed.
13. **The trie commits; a flat table serves reads.** Storage does not have
    to mirror the commitment.
14. **A full node's execution never reads from the network**: its inputs
    are in its store before the job starts. A light node's may.
15. **New and old versions stay on one network.** A wire change is an
    addition that older peers ignore, the node keeps serving what older
    peers ask for, and nothing changes what is valid. Storage may change
    freely: an upgraded node may wipe and re-sync.

## Where the code departs

The measurements are the first
[sync benchmark](../../README.md) baseline at `0ff1e87a`: 9,086 blocks over
four chains, four runs per setting, natively on a 14-core Mac
(`Benchmarks/sync/native.sh`). A plain fsync on macOS does not force the
drive to flush, so a sync costs less there than on Linux, where the nodes
run; no run of this baseline on Linux is recorded. A row is removed when the
code no longer departs.

| Rule | Today | Measured |
|---|---|---|
| 8, 9 | The runtime loop awaits an fsynced commit on every step that has facts | The loop was busy 46% of wall time with one worker and 67% with three |
| 8 | A submitted block's content is stored and retained before it is weighed (`storeMinedBlock`) | |
| 13 | State is content-addressed trie nodes in the content store, pruned by reference counts | 2.9 GB written for 82 MB kept |
| 4 | Every job shares one worker pool behind three strict queues | Derivations of 0.7 ms waited 3.5 to 3.9 s for a worker |
| 2 | A child reads its peers only once its parent has applied every header of one peer's log. A parent header that never applies (its child index not obtainable, say) holds its child's weight back, as does a parent with no peer running it. And the log is whichever peer's ended first: a peer that is behind opens the child on a parent that has weighed little, and the child then checks peers' proofs where it could have derived them | Not measured |
| 3 | A child's step receives its parent's whole tree and a `parentWeighed` flag | |
| 5 | Backoff, wake and let-go logic is separate per subsystem | |
| 12 | CID text keys throughout the core; canonical JSON on the wire | Header messages cost the loop about 0.6 s of 25.8 s |
| 14 | Any node reads missing state from peers while executing | |
| 15 | The wire is additive already; no test runs two versions together | |
