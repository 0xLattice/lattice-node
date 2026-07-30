# Authority elimination north star

This is the final design implemented by Lattice PR #5 and lattice-node PR #36.
It replaces the earlier certificate, header-replay, recursive-validator, and
validated-delta proposals.

## One rule, applied twice

Share availability; never share a verdict.

- Any peer may advertise and serve complete content-addressed Volumes.
- The receiving process verifies every CID, sparse directory proof, and grind.
- Each chain process validates and persists only its own chain's candidates.
  Disconnected valid orphans may retain and route independently verified work,
  but only connected accepted blocks can answer hierarchy queries.
- A child accepts a hierarchy verdict only as an unsigned response from its
  currently authenticated immediate-parent session to one exact pending query.
- No signature, certificate, portable parent verdict, ancestor bundle, or
  child-side parent validator exists.

## Durable facts

A connected accepted block gives its process the only durable continuity fact
it needs:

```text
ChainBlockFact(prevStateCID, postStateCID, parentBlockHash)
```

Recovery replays the same accepted block facts into `ChainState`. Transitive
state continuity is then a graph query over connected validated blocks:

```text
fromStateCID == toStateCID
    OR
there is a forward same-branch path whose state edges connect from -> to
```

Canonicity is irrelevant. Sideways movement between forks is not continuity.
No second transition store is needed.

An accepted parent block containing
`GenesisAction(directory, childGenesisCID)` also creates the exact durable
deployment fact:

```text
(directory, childGenesisCID, deploymentBlock.prevStateCID)
```

An invalid, unavailable, or merely content-present carrier cannot create this
fact.

## Child admission

For child genesis:

1. Acquire and verify the sparse root-to-child proof from any provider.
2. Ask the authenticated immediate parent whether it has the exact deployment
   tuple above.
3. Require the child genesis `parentState` to equal that tuple's state CID.
4. Admit and persist the child block normally.

For every later child block:

1. Acquire and verify the block and sparse work proof from any provider.
2. Read `previousChild.parentState` and `candidate.parentState`.
3. If equal, no hierarchy request is needed.
4. Otherwise ask the authenticated immediate parent whether the latter is
   transitively reachable from the former in its connected validated graph.
5. A positive exact response lets the child construct the local Lattice
   continuity input and retry admission.

Responses are non-portable and are not durable child authority. The durable
result is the child's own accepted block fact.

## Recursion

The rule recurses by process ownership, not by shipping ancestor history.

Before a parent block becomes connected and validated, that parent process has
already applied the same rule against its own immediate parent. Therefore a
grandchild asks only its parent. No process sends a descendant tree, root path,
ancestor proof, or inherited verdict.

Running every parent process locally to Nexus removes remote trust. Configuring
a remote parent deliberately trusts that process's local verdicts;
authentication proves which process answered, not that the operator is honest.

## Work is orthogonal

A grind is a physical, content-verifiable fact. It may contribute descendant
work when:

- the grind is real and beats the relevant target;
- its sparse directory proof commits uniquely to the descendant block; and
- the descendant block is connected on the chain whose fork choice uses it.

The carrier itself need not be valid, accepted, connected, or canonical.
Relaying such work never creates a chain, genesis, or continuity fact. Each
physical grind is deduplicated by its contribution identity, so it is counted
once.

A node may durably retain the structural carrier link and sparse proof so the
relay survives restart. That retention is not issuer authority: an orphan's
`GenesisAction` becomes queryable only after the orphan connects, while its
ordinary descendant proof routes may remain available throughout.

## Runtime protocol

The hierarchy wire protocol needs only exact bounded messages:

```text
genesis(childGenesisCID, parentStateCID)
continuity(fromStateCID, toStateCID)
```

Each message has a request ID. The child accepts a response only when the peer
key, live session ID, request ID, and payload all match the pending request.
Silence, disconnect, timeout, or failed enqueue requeues the candidate.
Concurrent and per-child query limits bound parent work.

The overlay and hierarchy planes share transport machinery but remain separate
Ivy namespaces, so a noisy child network cannot pollute its parent.

## Storage boundary

- `state.db` stores admission batches, accepted graph metadata, exact genesis
  facts, and retention references.
- VolumeBroker is the sole durable local content-addressed byte store.
- Temporary Volumes may be resolved in bounded memory and discarded.
- Consensus and fork choice are recomputed from durable facts after restart;
  the chosen tip is never durable authority.

## Required proof

The release gate must demonstrate:

- exact child deployment succeeds only after an accepted parent action;
- equal-state succession performs no parent query;
- transitive multi-block parent continuity succeeds;
- sideways fork continuity fails;
- noncanonical connected parent history remains usable;
- invalid/disconnected carriers relay real descendant work but no validity fact;
- malformed Volume suppliers are penalized and alternate advertisers retried;
- timeout, disconnect, parent restart, child restart, and late join recover;
- a three-level Nexus/child/grandchild topology advances using only
  immediate-parent queries;
- replay recomputes the same accepted graph, work, and fork choice.
