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

- **Workers**: a pool fed by three queues served in a fixed order: what an
  RPC waits on, then each chain's next blocks to execute, then everything
  else. A chain's next blocks never queue behind proof checks, and shared
  resources have limits, not further ordering policies.
- **Store**: a verified cache of what the network holds. Writes are atomic
  and ordered. Content (a body, a mined block) is stored by the job that
  validated or built it, before anything names it; the loop then writes each
  step's state and facts, content first and facts in one transaction, before
  it publishes. Facts and state are written by the loop alone.
- **Progress**: every module reports what it is waiting on, as a typed
  reason.

Between chains exactly two facts cross, both from parent to child:

1. **Work facts**: the parent's weighed graph (carriers, their `children`
   index, runs) feeds the child's Weigh.
2. **Continuity facts**: the parent's executed set feeds the child's Execute.

At any moment each piece of work is in one of four states: running; ready,
in a queue that will run it; waiting on another module's output; or
waiting on something outside the node, with a wake registered. A stall is
work in none of the four.

## Concurrency: one loop decides, workers execute

Decisions are made in one place and work runs on a worker pool, as
established clients are built. The node has no scheduler of its own.

| What | Runs on | Why |
|---|---|---|
| Decisions: every step of the core | One serial loop | It stays deterministic and simulated. The core took 9% to 16% of wall time in the first baseline |
| What an RPC waits on | The first queue | Latency |
| Execution of a chain's blocks | The second queue, one job per chain at a time: a batch of up to `connectBatch` ready blocks, one atomic change set | A chain executes in order anyway; chains run side by side; a chain's next block never waits behind thousands of child proof checks (#64, #76) |
| Header work: proof checks and derivations, and everything else | The third queue, in arrival order | Batched per page |
| Storage writes | Validated content by its job; then, as each step ends, the step's state and facts by the loop, facts in one transaction | One boundary, one order, one place: no caller orders writes |

The loop decides, and makes each step's writes before it publishes what
they make true: that wait is deliberate, the one the loop has. It does not
wait on the network, read content, or do bookkeeping that is not a decision.
A free worker takes the head of the first non-empty queue; a recheck whose
tip has moved is dropped unrun. There is no time accounting and no
scheduler to tune. A queue per chain and kind of work ("lanes") was built
and measured slower: 10.7–10.8 s against 10.4–10.5 s for the three queues
on the child-sync benchmark. A loop per chain would parallelise only the share the core
takes and would cost the single deterministic step order the simulator
depends on. Because only two facts cross between chains, a chain's decisions
can still move to a loop of their own later.

### The loop's contract

The loop (`NodeRuntime.Loop`) keeps these, and review holds every change to
the runtime to them:

1. **The core performs no I/O.** It returns effects; the loop runs them.
2. **The loop never waits for the network or for long computation.** That
   work runs as a job on the worker pool or as a task, and its result comes
   back as an input. One exception: when a chain stops being hosted, and
   when the node stops, the loop cancels that chain's count repair and
   waits for it to end, so no repair writes after its chain's counts are
   dropped; a state sync or heal deep in a network read keeps the loop until
   its fetch notices the cancellation.
3. **The loop never waits on something only the loop can finish.** A job or
   an RPC handler that needs live state sends the loop an input
   (`LiveLevels`) and waits; the loop never waits on a job.
4. **Only the loop changes the core's state**, by stepping it with an input;
   workers and tasks only post inputs.
5. **Writes complete before what they make true is published.** Each step:
   the step's state and facts in one transaction (`persist`, with the pool's
   journal), then `publish`, then every other effect in order. This is the
   loop's one deliberate wait. Content a job stored (a body, a mined block)
   is stored before the effect that names it. After the effects the step's
   retention runs, none of it needed to be right: the body working set's
   let-go, then each chain's state (the counts' move or commit, then the
   window's let-go), the read cache's order, then the reads of the blocks
   the step executed. A crash anywhere in it is repaired by the next start
   (`RetentionCrashTests`).
6. **Every job and task has a rule for when it is superseded**, listed
   below; a new kind adds its row. A result of a level no longer hosted is
   dropped by the core.

| Work | Runs on | Superseded |
|---|---|---|
| Connect (a level's next blocks) | the connect queue, one per level at a time | never: a verdict is a fact about a block and counts on any branch; a run is at most `connectBatch` blocks |
| Proof checks | the rest queue, one job per level per step, a page under a byte budget | never: a verdict is a fact about a header |
| Derivations | the rest queue, a level's of one step in at most one job per worker | never: a derived proof is a fact |
| Transaction reads (`readTransactions`) | the rest queue | never: local reads, cheap |
| Mining preflight (an RPC's, or a recheck) | the answered queue (awaited) or the rest | a recheck whose mining tip moved is dropped before it runs; an admission always runs, its submit is waiting |
| Template build | the answered queue | never: it is answered on any tip, and the miner asks again on a new digest |
| Returned transactions after a reorganisation | the rest queue | never: they go back to the pool, which judges them on its tip |
| Body fetches | a task per body | cancelled when the body leaves its level's window (`cancelBody`), and when the level is no longer hosted |
| Count repairs (check, heal, state sync) | a task, one per chain at a time | cancelled when the chain is no longer hosted; a result whose id is not the one running is dropped |
| Maintenance passes | a task, one at a time | never: one asked for meanwhile runs next, once |
| Transaction fetches | a task per announcement, at most 64 | never: bounded by the cap and the fetch's timeout; a fetched one already pooled is refused by the pool |
| Header pages served, child indexes fetched, mined blocks stored | a task each | never: bounded by the serving budget, the request's deadline, the RPC |

Work that runs to completion needs no rule beyond these: its result is a
fact, or is judged again where it lands, and its cost is bounded. A problem
that seems to need another actor, scheduler or background state manager is
first solved through the loop's existing inputs and effects.

## Node roles

| Role | Holds | Executes from |
|---|---|---|
| Archive | All bodies and all historical state, to answer reads of old state | Its own store only |
| Full | All current state and a recent window | Its own store, the witnesses child bodies carry, and peers for what it let go |
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

Every write is made before the step that decided it is published, so what
the node promises is on disk when it says so: an acknowledged local
transaction, pins, configuration, and a block a miner or an author was told
is accepted.

## Rules

A change satisfies all fifteen. A change that needs to break one changes the
rule here first.

1. **Weight never waits on execution**, its own chain's or its parent's.
2. **Availability never judges**, and never gates another chain's weight.
3. **Exactly two facts cross between chains**: work facts and continuity
   facts.
4. **One loop decides; workers execute** from three queues served in order:
   what an RPC waits on, each chain's next blocks, everything else. A new
   kind of work goes in one of them, not in a new queue or priority, unless
   a benchmark shows the three cannot serve it. There is no scheduler to
   tune.
5. **Every wait is typed and visible.** A timer may end a wait on something
   outside the node; it is never the reason work inside the node proceeds.
6. **Decisions live in the core.** The shell executes effects and reports
   results.
7. **Every liveness rule has a simulator scenario**, and every performance
   claim has a benchmark number.
8. **The network is the durable record.** Local storage is a verified cache:
   what peers can give back again needs no care beyond atomic, ordered writes.
9. **Writes are atomic and ordered, always, from one place.** Each step's
   content, then its facts in one transaction, as the step ends. A restart
   resumes from a consistent earlier state and re-syncs the rest.
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
| 13 | State is content-addressed trie nodes in the content store, pruned by reference counts | 2.9 GB written for 82 MB kept |
| 4 | Every job shares one worker pool behind three strict queues | Derivations of 0.7 ms waited 3.5 to 3.9 s for a worker |
| 2 | A child reads its peers only once its parent has applied every header of one peer's log. A parent header that never applies (its child index not obtainable, say) holds its child's weight back, as does a parent with no peer running it. And the log is whichever peer's ended first: a peer that is behind opens the child on a parent that has weighed little, and the child then checks peers' proofs where it could have derived them | Not measured |
| 3 | A child's step receives its parent's whole tree and a `parentWeighed` flag | |
| 5 | Backoff, wake and let-go logic is separate per subsystem | |
| 12 | CID text keys throughout the core; canonical JSON on the wire | Header messages cost the loop about 0.6 s of 25.8 s |
| 14 | Any node reads missing state from peers while executing | |
| 15 | The wire is additive already; no test runs two versions together | |
