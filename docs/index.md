# Lattice Documentation

**Lattice** commits a recursive content-addressed hierarchy while each process
validates and chooses exactly one absolute chain path. The single outer root is
**Nexus**. The canonical rationale and runtime ownership live in Lattice's
[philosophy](https://github.com/adalinxx/Lattice/blob/26.0.1/docs/philosophy.md)
and [foundational architecture](https://github.com/adalinxx/Lattice/blob/26.0.1/docs/foundational-architecture.md).

> **One process, one chain.** Every process owns one absolute Nexus-inclusive
> path and a matched `state.db` + `volumes.db` durability pair. External
> `lattice-miner` workers search work issued by Nexus through the coordinator.
> Child chains provide opt-in throughput and testing networks while deciding
> validity and fork choice independently from authenticated parent evidence.
> See [Getting started](getting-started.md).

Start here, then follow the path that matches what you're doing.

## By goal

| I want to… | Read |
|---|---|
| Understand what Lattice is and why it exists | [Lattice philosophy](https://github.com/adalinxx/Lattice/blob/26.0.1/docs/philosophy.md) · [README](../README.md) |
| Run a node for the first time | [Getting started](getting-started.md) |
| Call the HTTP API | [RPC API reference](rpc-api.md) |
| Operate a node in production | [Operations runbook](operations.md) · [Deployment](../deploy/README.md) |
| Deploy or manage child chains | [Deployment runbook](../deploy/README.md) |
| Understand the protocol in depth | [Lattice specification](https://github.com/adalinxx/Lattice/blob/26.0.1/docs/spec.md) · [Node boundary](protocol.md) |
| Understand the node's internals | [Architecture](architecture.md) |
| Understand recursive commitments and process boundaries | [Node consequences](design/fractal-structure.md) |
| Understand chain paths and directories | [Chain addressing model](design/chain-addressing.md) |
| Understand candidate data acquisition | [Candidate acquisition](design/candidate-acquisition.md) |
| Review the proposed composable node architecture | [Composable node architecture](design/modular-admission-pipeline.md) |
| Understand parent authority and process boundaries | [Process trust model](design/process-trust-model.md) |
| Follow the work-proof collapse implementation | [Work-proof collapse north star](design/work-proof-collapse-north-star.md) |
| Understand mining roles and worker boundaries | [Mining role boundaries](design/mining-role-boundaries.md) |
| Build an external (GPU/remote) mining worker | [Mining workers](mining-workers.md) |
| Build, test, or reproduce CI locally | [Development](development.md) |
| Write or run tests | [Testing](testing.md) |

## Canonical references

- **[Lattice specification](https://github.com/adalinxx/Lattice/blob/26.0.1/docs/spec.md)** — the normative protocol and consensus rules.
- **[protocol.md](protocol.md)** — the node's transport, durability, and RPC boundary around Lattice.
- **[architecture.md](architecture.md)** — how the node is built: actors, the storage broker cascade, and the per-process chain topology.
- **[rpc-api.md](rpc-api.md)** — the HTTP API, endpoint by endpoint. The single source of truth for the API.
- **[operations.md](operations.md)** — monitoring, recovery, security, and environment variables for running a node.

## Design records & history

Background on *why* things are shaped the way they are — design notes, not API or operational references.

- [design/fractal-structure.md](design/fractal-structure.md) — node consequences of recursive commitments and independent processes.
- [design/chain-addressing.md](design/chain-addressing.md) — the chain path / directory mental model.
- [design/candidate-acquisition.md](design/candidate-acquisition.md) — the event-order-independent boundary between Volume availability and consensus admission.
- [design/modular-admission-pipeline.md](design/modular-admission-pipeline.md) — orthogonal node capabilities, atomic Lattice semantics, and asynchronous selected-Volume persistence.
- [design/process-trust-model.md](design/process-trust-model.md) — configured parent authority, separate hierarchy facts, and independent content verification.
- [design/mining-role-boundaries.md](design/mining-role-boundaries.md) — the E15 node/coordinator/worker mining contract.
- [design/consensus-fork-choice.md](design/consensus-fork-choice.md) — the node's operational duties around Lattice-owned consensus.
- [design/work-proof-collapse-north-star.md](design/work-proof-collapse-north-star.md) — the implemented proof-derived work and parent-continuity north star.
