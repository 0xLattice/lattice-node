# Bulk Sync Is a Stream

## Model

Any peer may lie, withhold, stall, serve valid-but-irrelevant data, or be
honestly pruned; there is no honest-majority assumption among peers, and
security comes from per-item verification plus objectively comparable
cumulative work — under a partially synchronous network, in which a slow
peer and a stalling peer are indistinguishable, so rotation is a local
timing policy that never implies blame. The one non-peer trust edge is
the receiver's own configured immediate parent, which alone answers
genesis and parent-state
continuity questions on the hierarchy plane.

## Problem

An ordered forward path for deep history already exists — ascending pages,
bounded pipelining, rotation on no progress. The defect is that a node far
behind almost never *runs* it, and the fallback machinery it lands in is
quadratically wrong for bulk transfer:

- The ordered path is entered only when an inbound announcement carries a
  height and claims a gap past a fixed depth. It is never entered at
  session establishment — the moment a joining node actually learns it is
  deep. Instead, session establishment immediately starts the height-blind
  sweeps (an evidence-index walk paging in content-address order — random
  height order — and an accepted-leaves descent), committing the node to
  convergence machinery before it has determined whether it is deep.
- An empty ordered-path response is conflated with "caught up". A receiver
  whose frontier sits on a losing sibling gets an empty page, concludes it
  is done, and falls back to the sweeps — indistinguishable from success.
  This is the live marooned-follower incident.
- The fallback treats every historical block as a live-edge event:
  individually discovered, individually solicited (one evidence round trip
  per block, fired only from inside a failed admission attempt),
  individually admitted through a single-slot FIFO shared with live
  traffic, and parked whenever it arrives out of order — which for
  random-order discovery is always. Each item is handled correctly; the
  whole is pathological. Measured live on a fresh child against one
  healthy, complete, low-latency peer: two connected blocks out of ~3,500
  admission attempts in two hours, with the peer answering every one of
  917 evidence requests. The node even responded to its own congestion by
  recycling the serving session, resetting every sweep to its beginning.

Candidate acquisition exists to converge under adversarial, partial,
out-of-order arrival — the live edge's properties. Bulk history along one
chain is totally ordered, contiguously available over whatever range a
given peer retained, and verifiable strictly in sequence. Convergence
apparatus applied to that is O(total DAG) work per O(1) frontier progress.

## Concept

**Below the tip, sync is a stream; live gossip is the special case reserved
for the last few blocks.** The decision to stream is made when the node
learns a peer holds a substantially heavier chain — at session
establishment or on any announcement — and the height-blind sweeps do not
start until that determination is made (or resume until the stream ends).
A streaming receiver asks the peer for the chain in ascending order and
receives items that are self-sufficient in the common case — each block
together with the portable evidence that admits it — verifying and
applying each item strictly in sequence.

- **The stream starts at a common ancestor, not at the receiver's
  frontier.** Establishing that point is part of establishing the stream. A
  proposed start point is valid only if the receiver has already accepted
  that block itself, so negotiation can never rewind a receiver past its
  own verified history. Two honest nodes with disjoint retention may find
  no common point: that ends the stream and never lowers the peer's
  standing. An empty response is always distinguishable from "you are
  caught up".
- **The unit of transfer is the unit of admission — where a peer can
  portably supply it.** In the common case (an item whose carrier did not
  advance the parent state — measured as the overwhelming majority on the
  live child) the item is admissible on arrival. Where admission
  additionally requires a fact only the receiver's own immediate parent can
  authenticate, that fact is obtained on the hierarchy plane, pipelined
  ahead of application; a child stream therefore advances no faster than
  the receiver's own parent chain has been carried, and an item blocked on
  a parent fact is a local dependency, never a served fault.
- **Three outcomes per item, not two.** An item is admissible now; or it is
  a served fault (wrong bytes, out of order, failed verification), which
  ends the stream and rotates; or a *part* of an otherwise well-formed item
  is absent — an availability gap, sourced elsewhere at item granularity
  while the stream continues. Only an unsourceable gap ends the stream, and
  it still costs the peer nothing. A peer holds a block's portable
  evidence in the common case, not by construction — a miner, or a node
  that admitted via locally recovered parent evidence, may hold the block
  and no portable artifact.
- **Rotation is judged on progress, not validity.** A stream that verifies
  perfectly but does not move the receiver toward the heaviest chain it has
  heard of — a relayed abandoned branch, correct in every byte — is
  rotated away from exactly like a stalling peer. Correctness of items is
  not evidence of relevance. Which branch the receiver chases, and how
  heavy it claims to be, is derived from announcements observed across
  peers and weighed locally; the stream only fetches, it never decides. A
  single peer can determine what bytes arrive next, never which chain the
  receiver is trying to reach.
- **Trust does not change.** Every item is verified on arrival exactly as
  the live path verifies it; the stream changes when bytes move, never what
  is believed. No assumevalid, no checkpoint, no honest-serving assumption.
- **The live machinery stands down while the stream runs — and its return
  is load-bearing.** The height-blind sweeps pause during a stream and
  resume from persisted cursors, never from the beginning. Resumption is
  driven by the receiver's own assessment of its distance to the tip, not
  gated on a further peer message arriving. The sweeps are not mere gap
  healing: a stream conveys one chain, while fork choice weighs whole
  subtrees, so a freshly streamed node is
  fork-choice-under-informed until the sweeps
  backfill sibling work. No future simplification may drop them.
- **Congestion is local.** A receiver that cannot keep up slows its own
  requests. Buffer pressure never restarts, resets, or re-sessions a
  discovery walk, and never punishes the serving session.

A stream ends when the receiver is within the live edge's reach of the
chain it is chasing — the target moves as the producer mints; there is no
fixed captured height. A receiver that cannot close the distance is not
viable on that chain, and that condition is surfaced, never retried
silently. The handover distance between stream and live gossip is operator
policy with a sane default: two nodes that choose different distances are
both fully conforming, and no peer can observe or depend on another's
choice.

The end state matches the unified-adopt principle: child sync and root sync
are the same operation — stream to the tip, then let pure heaviest-selection
gossip take over — differing in whether a given item needs a hierarchy-plane
parent fact alongside its portable evidence.

## Boundaries

- Consensus is untouched: admission validity, weight comparison, and fork
  choice are identical for streamed and gossiped blocks. The stream is a
  transport arrangement.
- Wire compatibility is additive: peers that do not speak the
  evidence-carrying stream still serve the existing pages, and receivers
  fall back to per-block solicitation — slow, never wrong.
- The stream serves the retained view, at item granularity (see the
  three-outcome rule). A child chain whose facts no parent tracks and no
  peer retained is unsyncable by the same rule that makes it unsyncable
  today — the stream changes the cost of availability, never its existence.
- Live blocks arriving during a stream are parked and admitted when the
  stream reaches them; a parked announcement released under pressure is
  never absorbed into a seen set — it stays re-announceable and
  re-solicitable — and on stream completion the receiver re-establishes the
  tip by asking rather than waiting for the next announcement.
- Blocks delivered by an active stream are treated as just-re-acquired for
  eviction ordering (operator-finality), so a stream cannot evict its own
  prefix; the operator's ceiling is unchanged, and a stream that does not
  fit under it fails visibly rather than thrashing.
