# Development

How to build, test, and reproduce CI locally.

## Build

```bash
swift build              # debug
swift build -c release   # release — what CI builds
```

Requires Swift 6.1+. CI builds with Swift 6.1; recent Xcode toolchains also work
for local macOS builds.

## Run

```bash
swift run lattice-node --help
swift run lattice-node --rpc-port 8080

# External proof-of-work pipeline:
swift run lattice-mining-coordinator \
  --node http://127.0.0.1:8080 \
  --rpc-cookie-file ~/.lattice/chains/Nexus/.cookie \
  --worker-executable .build/debug/lattice-miner \
  --workers 2
```

See [getting-started.md](getting-started.md) for first-run details and
[../deploy/README.md](../deploy/README.md) for multi-node and per-process child chains.
Mining code should follow the E15 [Mining role boundaries](design/mining-role-boundaries.md):
`LatticeNode` owns chain state, sealing, validation, persistence, and gossip;
`MiningCoordinator` owns work lifecycle and range fan-out; `LatticeMiner`
workers only search assigned nonces.

## Test

```bash
swift test               # unit + integration tests
```

- Current unit and integration suites: [testing.md](testing.md).

## Reproduce the Linux CI build locally (from macOS)

CI builds on Linux (`swift:6.1-jammy`), where several things differ from macOS —
`URLSession`/`URLRequest` live in `FoundationNetworking`, `SHA256` is non-`Sendable`,
and `stdout` is a flagged global. **A macOS build can be green while Linux is red**,
so verify on Linux before pushing.

A static Swift SDK can't build this repo (it needs system **libsqlite3**), so use
Docker with the same image CI uses.

### Quick one-off

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.1-jammy bash -lc '
  apt-get update -qq &&
  apt-get install -y --no-install-recommends libsqlite3-dev &&
  swift build -c release --build-path .build-linux'
```

- `--build-path .build-linux` keeps Linux artifacts out of your macOS `.build`.
- On Apple Silicon this builds native arm64-linux, which catches the same
  portability errors. Add `--platform linux/amd64` to match CI's exact x86_64
  target (slower, emulated).

### Faster, repeatable (cached image + build volume)

This repo ships [`Dockerfile.linux`](../Dockerfile.linux) (the thin CI-parity image)
and [`scripts/linux-build.sh`](../scripts/linux-build.sh) (a wrapper that caches the
Linux build in a named volume):

```bash
scripts/linux-build.sh         # swift build -c release  (the CI Build step)
scripts/linux-build.sh test    # build + swift test
scripts/linux-build.sh shell   # poke around inside the Linux image
```

No Docker Desktop? `brew install colima docker && colima start` provides a
Docker-compatible runtime without the GUI.

## Code layout

| Path | What |
|---|---|
| `Sources/LatticeNodeCore/Chain` | `ChainCore`, chain selection, body execution, and child-proof admission for one chain level. |
| `Sources/LatticeNodeCore/Host` | `NodeCore`, the deterministic state machine spanning every hosted chain level. |
| `Sources/LatticeNodeCore/Sync` | Header-graph synchronization state and its decoded protocol values. |
| `Sources/LatticeNodeCore/Mempool` | Transaction-pool policy and mutations. |
| `Sources/LatticeNodeCore/Mining` | Mining state, template jobs, and issued-work tracking. |
| `Sources/LatticeNode/Runtime` | `NodeRuntime`, the production shell that drives `NodeCore` and executes effects. |
| `Sources/LatticeNode/API` | Public service models, read operations, and route-input validation. |
| `Sources/LatticeNode/Networking` | Overlay handshake, wire codecs, transport adapter, and wire validation. |
| `Sources/LatticeNode/Content` | Content-addressed block decoding and Ivy/VolumeBroker adapters. |
| `Sources/LatticeNode/Storage` | Durable fact journals, header content, SQLite rows, boot recovery, and locking. |
| `Sources/LatticeNode/Configuration` | Node configuration, genesis, bootstrap peers, and public URL policy. |
| `Sources/LatticeNode/Mining` | Mining-template assembly and multi-level mining plans. |
| `Sources/LatticeNode/Observability` | Metrics and opt-in synchronization tracing. |
| `Sources/LatticeNodeDaemon` | CLI and loopback HTTP adapter. |
| `Sources/LatticeMiner` | External proof-of-work worker target; nonce search only. |
| `Sources/LatticeMiningCoordinatorTool` | Node-facing coordinator CLI; fetches work, allocates local ranges, and submits nonce results. |
| `Sources/CSQLite` | SQLite C shim. |

Consensus protocol types (Block, Transaction, ChainState, consensus) live in the
upstream `Lattice`, `cashew`, `Ivy`, `VolumeBroker`, and `Tally` packages. The
`Lattice` product is an umbrella that re-exports its six modules
(`LatticePrimitives`, `LatticePoW`, `LatticeValidation`, `LatticeProofs`,
`LatticeBlockTree`, `LatticeImport`), so node code imports `Lattice`. See
[architecture.md](architecture.md).
