// Smoke-test orchestrator.
//
// Runs scenarios with isolated tmp dirs, prints per-test pass/fail with
// wall-clock time, and exits non-zero on any failure.
//
// Usage:
//   node run.mjs                           # run all tests, 4 parallel workers
//   SMOKE_WORKERS=1 node run.mjs           # sequential (easier to read output)
//   SMOKE_FILTER=swap node run.mjs         # run tests whose name matches /swap/
//   SMOKE_TAGS=safety-a node run.mjs       # run tests tagged safety-a
//   SMOKE_FAIL_FAST=1 node run.mjs         # stop on first failure
//   SMOKE_STREAM=1 node run.mjs            # stream test output live (best with FILTER)
//   SMOKE_PORT_BASE_START=40000 node run.mjs # force a specific port range

import { spawn, execSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir, cpus } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const FILTER = process.env.SMOKE_FILTER ? new RegExp(process.env.SMOKE_FILTER) : null
const TAG_FILTER = process.env.SMOKE_TAGS
  ? new Set(process.env.SMOKE_TAGS.split(/[,\s]+/).filter(Boolean))
  : null
const FAIL_FAST = process.env.SMOKE_FAIL_FAST === '1'
// Each scenario spawns several full-node processes + a miner, so parallel scenarios
// multiply process count. Cap workers at the core count: never schedule more concurrent
// multi-process scenarios than cores, so CPU contention can't starve block production
// (the verified flake cause) on a small/loaded box. CI runners with enough cores keep
// their configured SMOKE_WORKERS unchanged; set SMOKE_WORKERS to override downward.
const CORES = Math.max(1, cpus().length)
const WORKERS = Math.max(1, Math.min(parseInt(process.env.SMOKE_WORKERS ?? '4', 10), CORES))
const STREAM = process.env.SMOKE_STREAM === '1'
const DETACHED_CHILDREN = process.env.SMOKE_DETACHED_CHILDREN !== '0'
// Load-aware timeout scale: under N concurrent workers each scenario gets ~1/N of
// the CPU, so fixed wall-clock deadlines (convergence/mining waits AND the
// per-test hard kill) must stretch with contention or they false-fail. Default to
// the worker count (1 when sequential ⇒ no change), capped so a genuine hang
// still surfaces in bounded time. Overridable via SMOKE_TIMEOUT_SCALE.
const TIMEOUT_SCALE = Math.max(1, Number(process.env.SMOKE_TIMEOUT_SCALE) || Math.min(WORKERS, 4))

// Heavy tests = those observed to run ≥~45s of sustained multi-node / continuous
// mining. Running several at once is the peak-contention condition that
// intermittently starves a long-runner's node/miner (e.g. retention-pruning's
// step-6 mining restart) under the full suite. Cap how many run concurrently so
// the other workers keep draining the ~65 light tests while peak load drops.
// Overridable via SMOKE_HEAVY_CONCURRENCY (set to WORKERS to disable the cap).
const HEAVY_TESTS = new Set([
  'reorg-restart-durability', 'sigkill-mid-reorg',
  'reorg-mempool-readmit', 'reorg-mempool-nonce-evict', 'child-genesis-orphaned', 'heterogeneous-child-targets',
  'multichain-late-joiner', 'multidepth-swap', 'depth4-merged-mining', 'stateless-follower',
  'sync-during-reorg',
  'restart-resilience', 'swap-violations', 'late-joiner', 'deep-sync',
  'sync-finality-refusal', 'per-process-deep-reorg', 'cross-chain-reorg',
  'swap', 'swap-cli', 'retention-pruning', 'grandchild-swap', 'toytoy-compound-swap', 'sync-under-load',
  'mempool-propagation', 'partition', 'pin-lifecycle', 'reorg-state-rollback',
  'orphaned-withdrawal-pending', 'deep-reorg', 'concurrent-mining',
    'parent-dependency', 'supply-conservation', 'tx-throughput',
])
const HEAVY_CONCURRENCY = Math.max(1, parseInt(process.env.SMOKE_HEAVY_CONCURRENCY ?? '2', 10))

const PRIORITY_REGRESSION_TESTS = [
  'block-cap-enforcement',
  'stability-multichain',
  'mempool-propagation',
  'deep-reorg',
  'per-process-deep-reorg',
]
const PRIORITY_INDEX = new Map(PRIORITY_REGRESSION_TESTS.map((name, index) => [name, index]))

if (!DETACHED_CHILDREN && WORKERS > 1) {
  throw new Error('SMOKE_DETACHED_CHILDREN=0 requires SMOKE_WORKERS=1 so cleanup cannot kill sibling tests')
}

function group(tags, tests) {
  const list = Array.isArray(tags) ? tags : [tags]
  return tests.map((test) => ({ ...test, tags: [...new Set([...(test.tags ?? []), ...list])] }))
}

const TESTS = [
  ...group('network-heavy', [
    { name: 'multidepth-swap',       file: 'scenarios/swap/multidepth-swap.mjs',          timeoutMs: 15 * 60_000 },
    { name: 'deep-sync',             file: 'scenarios/network/deep-sync.mjs',             timeoutMs: 600_000 },
    { name: 'sync-under-load',       file: 'scenarios/network/sync-under-load.mjs',       timeoutMs: 360_000 },
    { name: 'multi-child-miner-revenue', file: 'scenarios/network/multi-child-miner-revenue.mjs', timeoutMs: 600_000 },
    { name: 'multichain-late-joiner', file: 'scenarios/network/multichain-late-joiner.mjs', timeoutMs: 8 * 60_000 },
    { name: 'proof-backfill',        file: 'scenarios/network/proof-backfill.mjs',        timeoutMs: 8 * 60_000 },
    { name: 'permissionless-child-join', file: 'scenarios/network/permissionless-child-join.mjs', timeoutMs: 8 * 60_000 },
  ]),
  ...group('network-core', [
    { name: 'multinode-convergence', file: 'scenarios/network/multinode-convergence.mjs', timeoutMs: 90_000 },
    { name: 'sync',                  file: 'scenarios/network/sync.mjs',                  timeoutMs: 300_000 },
    { name: 'late-joiner',           file: 'scenarios/network/late-joiner.mjs',           timeoutMs: 8 * 60_000 },
    { name: 'partition',             file: 'scenarios/network/partition.mjs',             timeoutMs: 360_000 },
    { name: 'sync-during-reorg',     file: 'scenarios/network/sync-during-reorg.mjs',     timeoutMs: 360_000 },
    { name: 'concurrent-mining',     file: 'scenarios/network/concurrent-mining.mjs',     timeoutMs: 420_000 },
    { name: 'mesh-convergence',      file: 'scenarios/network/mesh-convergence.mjs',      timeoutMs: 300_000 },
    { name: 'peer-churn',            file: 'scenarios/network/peer-churn.mjs',            timeoutMs: 300_000 },
    { name: 'merged-mining',         file: 'scenarios/network/merged-mining.mjs',         timeoutMs: 90_000 },
    { name: 'auto-include-children', file: 'scenarios/network/auto-include-children.mjs', timeoutMs: 120_000 },
    { name: 'external-miner-quickstart', file: 'scenarios/network/external-miner-quickstart.mjs', timeoutMs: 180_000 },
  ]),
  ...group('follower', [
    { name: 'parent-dependency',          file: 'scenarios/follower/parent-dependency.mjs',          timeoutMs: 12 * 60_000 },
    { name: 'stateless-cli',              file: 'scenarios/follower/stateless-cli.mjs',              timeoutMs: 60_000 },
    { name: 'stateless-follower',         file: 'scenarios/follower/stateless-follower.mjs',         timeoutMs: 12 * 60_000 },
    { name: 'chain-path-required',        file: 'scenarios/follower/chain-path-required.mjs',        timeoutMs: 10 * 60_000 },
    { name: 'chain-path-replay-isolation', file: 'scenarios/safety/chain-path-replay-isolation.mjs', timeoutMs: 240_000 },
    { name: 'nexus-only-child-isolation', file: 'scenarios/follower/nexus-only-child-isolation.mjs', timeoutMs: 240_000 },
    { name: 'duplicate-edge-label-isolation', file: 'scenarios/follower/duplicate-edge-label-isolation.mjs', timeoutMs: 420_000 },
    { name: 'parent-restart-reconnect',   file: 'scenarios/follower/parent-restart-reconnect.mjs',   timeoutMs: 8 * 60_000 },
    { name: 'relay-discovery',            file: 'scenarios/follower/relay-discovery.mjs',            timeoutMs: 12 * 60_000 },
    { name: 'per-process-parent-reorg',   file: 'scenarios/follower/per-process-parent-reorg.mjs',   timeoutMs: 240_000 },
    { name: 'per-process-deep-reorg',     file: 'scenarios/follower/per-process-deep-reorg.mjs',     timeoutMs: 300_000 },
  ]),
  ...group('persistence', [
    { name: 'restart-resilience',    file: 'scenarios/persistence/restart-resilience.mjs', timeoutMs: 12 * 60_000 },
    { name: 'graceful-shutdown',     file: 'scenarios/persistence/graceful-shutdown.mjs',  timeoutMs: 360_000 },
    { name: 'sigterm-under-load',    file: 'scenarios/persistence/sigterm-under-load.mjs', timeoutMs: 360_000 },
    { name: 'restart-with-children', file: 'scenarios/persistence/restart-with-children.mjs', timeoutMs: 360_000 },
    { name: 'retention-pruning',     file: 'scenarios/persistence/retention-pruning.mjs', timeoutMs: 300_000 },
    { name: 'crash-mid-prune',       file: 'scenarios/persistence/crash-mid-prune.mjs',   timeoutMs: 300_000 },
  ]),
  ...group('swap', [
    { name: 'swap',                  file: 'scenarios/swap/swap.mjs',                     timeoutMs: 10 * 60_000 },
    { name: 'swap-cli',              file: 'scenarios/swap/swap-cli.mjs',                 timeoutMs: 10 * 60_000 },
    { name: 'variable-rate-swap',    file: 'scenarios/swap/variable-rate-swap.mjs',       timeoutMs: 480_000 },
    { name: 'receipt-derived-transfer', file: 'scenarios/swap/receipt-derived-transfer.mjs', timeoutMs: 10 * 60_000 },
    { name: 'grandchild-swap',       file: 'scenarios/swap/grandchild-swap.mjs',          timeoutMs: 480_000 },
    { name: 'depth4-merged-mining',  file: 'scenarios/swap/depth4-merged-mining.mjs',     timeoutMs: 480_000 },
    { name: 'toytoy-compound-swap',  file: 'scenarios/swap/toytoy-compound-swap.mjs',     timeoutMs: 12 * 60_000 },
  ]),
  ...group('cli', [
    { name: 'operator-journey',      file: 'scenarios/cli/operator-journey.mjs',          timeoutMs: 10 * 60_000 },
  ]),
  ...group('safety-a', [
    { name: 'tx-throughput',         file: 'scenarios/safety/tx-throughput.mjs',          timeoutMs: 360_000 },
    { name: 'wallet-under-attack',   file: 'scenarios/safety/wallet-under-attack.mjs',    timeoutMs: 240_000 },
    { name: 'invalid-rpc-transaction-resilience', file: 'scenarios/safety/invalid-rpc-transaction-resilience.mjs', timeoutMs: 180_000 },
    { name: 'relay-rejection-no-penalty', file: 'scenarios/safety/relay-rejection-no-penalty.mjs', timeoutMs: 180_000 },
    { name: 'finality-enforcement',  file: 'scenarios/safety/finality-enforcement.mjs',   timeoutMs: 120_000 },
    { name: 'swap-violations',       file: 'scenarios/safety/swap-violations.mjs',        timeoutMs: 15 * 60_000 },
    { name: 'fee-bounds',            file: 'scenarios/safety/fee-bounds.mjs',             timeoutMs: 180_000 },
    { name: 'balance-overdraft',     file: 'scenarios/safety/balance-overdraft.mjs',      timeoutMs: 180_000 },
    { name: 'supply-conservation',   file: 'scenarios/safety/supply-conservation.mjs',    timeoutMs: 600_000 },
    { name: 'mempool-propagation',   file: 'scenarios/safety/mempool-propagation.mjs',    timeoutMs: 300_000 },
    { name: 'cross-chain-conservation', file: 'scenarios/safety/cross-chain-conservation.mjs', timeoutMs: 10 * 60_000 },
    { name: 'reorg-restart-durability', file: 'scenarios/safety/reorg-restart-durability.mjs', timeoutMs: 360_000 },
    { name: 'sigkill-mid-reorg',     file: 'scenarios/safety/sigkill-mid-reorg.mjs',      timeoutMs: 360_000 },
    { name: 'reorg-mempool-readmit', file: 'scenarios/safety/reorg-mempool-readmit.mjs',  timeoutMs: 360_000 },
    { name: 'reorg-mempool-nonce-evict', file: 'scenarios/safety/reorg-mempool-nonce-evict.mjs', timeoutMs: 360_000 },
  ]),
  ...group('safety-b', [
    { name: 'mempool-eviction',      file: 'scenarios/safety/mempool-eviction.mjs',       timeoutMs: 180_000 },
    { name: 'concurrent-senders',    file: 'scenarios/safety/concurrent-senders.mjs',     timeoutMs: 180_000 },
    { name: 'premine-correctness',   file: 'scenarios/safety/premine-correctness.mjs',    timeoutMs: 300_000 },
    { name: 'large-block',           file: 'scenarios/safety/large-block.mjs',            timeoutMs: 10 * 60_000 },
    { name: 'block-cap-enforcement', file: 'scenarios/safety/block-cap-enforcement.mjs',  timeoutMs: 300_000 },
    { name: 'deploy-under-load',     file: 'scenarios/safety/deploy-under-load.mjs',      timeoutMs: 300_000 },
    { name: 'reorg-state-rollback',  file: 'scenarios/safety/reorg-state-rollback.mjs',   timeoutMs: 360_000 },
    { name: 'timestamp-rejection',   file: 'scenarios/safety/timestamp-rejection.mjs',    timeoutMs: 180_000 },
    { name: 'cross-chain-reorg',     file: 'scenarios/safety/cross-chain-reorg.mjs',      timeoutMs: 360_000 },
    { name: 'deep-reorg',            file: 'scenarios/safety/deep-reorg.mjs',             timeoutMs: 360_000 },
    { name: 'tiebreaker-convergence', file: 'scenarios/safety/tiebreaker-convergence.mjs', timeoutMs: 240_000 },
    { name: 'sync-finality-refusal', file: 'scenarios/safety/sync-finality-refusal.mjs',  timeoutMs: 240_000 },
    { name: 'child-epoch-difficulty', file: 'scenarios/safety/child-epoch-difficulty.mjs', timeoutMs: 180_000 },
    { name: 'parent-state-root-continuity', file: 'scenarios/safety/parent-state-root-continuity.mjs', timeoutMs: 120_000 },
    { name: 'rbf-gossip-dedup',      file: 'scenarios/safety/rbf-gossip-dedup.mjs',       timeoutMs: 180_000 },
    { name: 'orphaned-withdrawal-pending', file: 'scenarios/safety/orphaned-withdrawal-pending.mjs', timeoutMs: 360_000 },
    { name: 'websocket-disconnect',  file: 'scenarios/safety/websocket-disconnect.mjs',   timeoutMs: 120_000 },
    { name: 'redeploy-from-genesis', file: 'scenarios/safety/redeploy-from-genesis.mjs',  timeoutMs: 180_000 },
    { name: 'child-genesis-orphaned', file: 'scenarios/safety/child-genesis-orphaned.mjs', timeoutMs: 360_000 },
    { name: 'heterogeneous-child-targets', file: 'scenarios/safety/heterogeneous-child-targets.mjs', timeoutMs: 360_000 },
  ]),
  ...group('rpc', [
    { name: 'finality',              file: 'scenarios/rpc/finality.mjs',                  timeoutMs: 180_000 },
    { name: 'health-and-metrics',    file: 'scenarios/rpc/health-and-metrics.mjs',        timeoutMs: 180_000 },
    { name: 'block-explorer',        file: 'scenarios/rpc/block-explorer.mjs',            timeoutMs: 180_000 },
    { name: 'transaction-history',   file: 'scenarios/rpc/transaction-history.mjs',       timeoutMs: 180_000 },
    { name: 'chain-spec',            file: 'scenarios/rpc/chain-spec.mjs',                timeoutMs: 180_000 },
    { name: 'balance-proof',         file: 'scenarios/rpc/balance-proof.mjs',             timeoutMs: 180_000 },
    { name: 'investor-issuance',     file: 'scenarios/rpc/investor-issuance.mjs',         timeoutMs: 180_000 },
    { name: 'developer-child-journey', file: 'scenarios/rpc/developer-child-journey.mjs', timeoutMs: 360_000 },
    { name: 'mining-work-api',       file: 'scenarios/rpc/mining-work-api.mjs',           timeoutMs: 120_000 },
    { name: 'difficulty-adjustment', file: 'scenarios/rpc/difficulty-adjustment.mjs',     timeoutMs: 360_000 },
    { name: 'websocket-events',      file: 'scenarios/rpc/websocket-events.mjs',          timeoutMs: 180_000 },
    { name: 'historical-balance',    file: 'scenarios/rpc/historical-balance.mjs',        timeoutMs: 180_000 },
    { name: 'operational-endpoints', file: 'scenarios/rpc/operational-endpoints.mjs',     timeoutMs: 120_000 },
    { name: 'cookie-query-token',    file: 'scenarios/rpc/cookie-query-token.mjs',        timeoutMs: 60_000 },
    { name: 'privileged-control-plane', file: 'scenarios/rpc/privileged-control-plane.mjs', timeoutMs: 60_000 },
    { name: 'mining-key-boundary',   file: 'scenarios/rpc/mining-key-boundary.mjs',       timeoutMs: 60_000 },
  ]),
  ...group('liveness', [
    { name: 'pin-lifecycle',         file: 'scenarios/liveness/pin-lifecycle.mjs',        timeoutMs: 300_000 },
    { name: 'stability-multichain',  file: 'scenarios/liveness/stability-multichain.mjs', timeoutMs: 35 * 60_000 },
  ]),
  ...group('adversarial', [
    { name: 'low-work-identity-rejected', file: 'scenarios/adversarial/low-work-identity-rejected.mjs', timeoutMs: 120_000 },
    { name: 'stale-tip-recovery',    file: 'scenarios/adversarial/stale-tip-recovery.mjs',    timeoutMs: 120_000 },
    { name: 'restart-persistence',   file: 'scenarios/adversarial/restart-persistence.mjs',   timeoutMs: 120_000 },
  ]),
]

const SUITE_STARTED_AT = Date.now()
const RUN_ID = `${Date.now()}-${process.pid}`
const RUN_ROOT = `/tmp/smoke-all-${RUN_ID}`
const REQUESTED_PORT_BASE_START = Number.parseInt(process.env.SMOKE_PORT_BASE_START ?? '', 10)
let PORT_BASE_START = REQUESTED_PORT_BASE_START
const PORT_SLICE_SIZE = parseInt(process.env.SMOKE_PORT_SLICE_SIZE ?? '200', 10)
const PORT_PROBE_WIDTH = parseInt(process.env.SMOKE_PORT_PROBE_WIDTH ?? '64', 10)
const TEST_INDEX = new Map(TESTS.map((test, index) => [test.name, index]))
const SUITE_LOCK = join(tmpdir(), 'lattice-node-smoke-suite.lock')
const ACTIVE_PROCESS_GROUPS = new Set()

function fmtMs(ms) {
  if (ms < 1000) return `${ms}ms`
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`
  return `${(ms / 60_000).toFixed(1)}m`
}

function killStaleLatticeNodes() {
  try {
    execSync('pkill -9 -f "LatticeNode|LatticeMiner|LatticeMiningCoordinatorTool" 2>/dev/null', { stdio: 'ignore' })
  } catch {}
  execSync('sleep 1', { stdio: 'ignore' })
}

function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function killProcessGroup(pid, signal = 'SIGKILL') {
  if (!Number.isInteger(pid) || pid <= 0) return
  try {
    process.kill(-pid, signal)
  } catch {
    try { process.kill(pid, signal) } catch {}
  }
}

function killTrackedChild(pid, signal = 'SIGKILL') {
  if (DETACHED_CHILDREN) {
    killProcessGroup(pid, signal)
    return
  }
  if (!Number.isInteger(pid) || pid <= 0) return
  try { process.kill(pid, signal) } catch {}
}

function killActiveProcessGroups(signal = 'SIGKILL') {
  for (const pid of [...ACTIVE_PROCESS_GROUPS]) killTrackedChild(pid, signal)
}

function acquireSuiteLock() {
  if (process.env.SMOKE_DISABLE_PORT_LOCK === '1') return () => {}

  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      mkdirSync(SUITE_LOCK)
      writeFileSync(join(SUITE_LOCK, 'owner'), `${process.pid}\n${new Date().toISOString()}\n`)
      let released = false
      return () => {
        if (released) return
        released = true
        rmSync(SUITE_LOCK, { recursive: true, force: true })
      }
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error
      let owner = 'unknown'
      try { owner = readFileSync(join(SUITE_LOCK, 'owner'), 'utf8').trim() } catch {}
      const pid = Number.parseInt(owner.split(/\s+/)[0] ?? '', 10)
      if (!processIsAlive(pid)) {
        rmSync(SUITE_LOCK, { recursive: true, force: true })
        continue
      }
      throw new Error(`another smoke suite is already running (lock=${SUITE_LOCK}, owner=${owner})`)
    }
  }

  throw new Error(`could not acquire smoke suite lock at ${SUITE_LOCK}`)
}

function canBindPort(port) {
  return new Promise((resolve) => {
    const srv = createServer()
    srv.once('error', () => resolve(false))
    srv.listen({ port, host: '127.0.0.1', exclusive: true }, () => {
      srv.close(() => resolve(true))
    })
  })
}

async function portRangeIsAvailable(base, tests) {
  if (!Number.isInteger(base) || base <= 0) return false
  const probeWidth = Math.max(2, Math.min(PORT_SLICE_SIZE, PORT_PROBE_WIDTH))
  const maxPort = Math.max(
    ...tests.map((test) => base + (TEST_INDEX.get(test.name) ?? 0) * PORT_SLICE_SIZE + probeWidth - 1),
  )
  if (maxPort > 65535) return false

  for (const test of tests) {
    const sliceBase = base + (TEST_INDEX.get(test.name) ?? 0) * PORT_SLICE_SIZE
    for (let offset = 0; offset < probeWidth; offset++) {
      if (!(await canBindPort(sliceBase + offset))) return false
    }
  }
  return true
}

function candidatePortBases(requiredSpan) {
  if (Number.isInteger(REQUESTED_PORT_BASE_START) && REQUESTED_PORT_BASE_START > 0) {
    return [REQUESTED_PORT_BASE_START]
  }

  const minBase = Number.parseInt(process.env.SMOKE_PORT_BASE_MIN ?? '20000', 10)
  const maxBase = Math.min(
    Number.parseInt(process.env.SMOKE_PORT_BASE_MAX ?? '48000', 10),
    65535 - requiredSpan,
  )
  const candidates = []
  const add = (base) => {
    if (!Number.isInteger(base) || base < minBase || base > maxBase) return
    const aligned = base - (base % PORT_SLICE_SIZE)
    if (!candidates.includes(aligned)) candidates.push(aligned)
  }

  for (let i = 0; i < 12; i++) {
    const span = Math.max(1, maxBase - minBase)
    add(minBase + Math.floor(Math.random() * span))
  }
  add(40000)
  add(30000)
  add(20000)
  return candidates
}

async function choosePortBase(tests) {
  const requiredSpan = TESTS.length * PORT_SLICE_SIZE + Math.max(2, Math.min(PORT_SLICE_SIZE, PORT_PROBE_WIDTH))
  const candidates = candidatePortBases(requiredSpan)
  for (const candidate of candidates) {
    if (await portRangeIsAvailable(candidate, tests)) return candidate
  }

  const requested = Number.isInteger(REQUESTED_PORT_BASE_START) && REQUESTED_PORT_BASE_START > 0
    ? ` requested base ${REQUESTED_PORT_BASE_START}`
    : ''
  throw new Error(`no available smoke port range found${requested}; try SMOKE_PORT_BASE_START=<free base>`)
}

async function runOne(test, { stream = false } = {}) {
  const filePath = join(HERE, test.file)
  if (!existsSync(filePath)) return { skipped: true, reason: 'missing' }

  const root = `${RUN_ROOT}/${test.name}`
  rmSync(root, { recursive: true, force: true })
  const start = Date.now()
  const portBase = PORT_BASE_START + (TEST_INDEX.get(test.name) ?? 0) * PORT_SLICE_SIZE
  const env = {
    ...process.env,
    SMOKE_ROOT: root,
    SMOKE_PORT_BASE: String(portBase),
    SMOKE_PORT_SLICE: String(PORT_SLICE_SIZE),
    SMOKE_TIMEOUT_SCALE: String(TIMEOUT_SCALE),
  }
  const child = spawn(process.execPath, [filePath], {
    stdio: ['ignore', 'pipe', 'pipe'], env,
    detached: DETACHED_CHILDREN,
  })
  ACTIVE_PROCESS_GROUPS.add(child.pid)

  let stdout = '', stderr = ''
  if (stream) {
    child.stdout.on('data', (d) => { process.stdout.write(d) })
    child.stderr.on('data', (d) => { process.stderr.write(d) })
  } else {
    child.stdout.on('data', (d) => { stdout += d })
    child.stderr.on('data', (d) => { stderr += d })
  }

  // Scale the hard-kill ceiling by the same factor as the in-scenario waits, so a
  // test whose (now load-stretched) internal deadlines are legitimately in flight
  // isn't SIGKILLed out from under them under contention.
  let timedOut = false
  const timer = setTimeout(() => {
    timedOut = true
    killTrackedChild(child.pid, 'SIGKILL')
  }, test.timeoutMs * TIMEOUT_SCALE)
  const code = await new Promise((resolve) => child.on('exit', resolve))
  // A scenario can exit while node/miner descendants are still alive. In the
  // default detached mode this cleans the scenario process group; attached
  // sequential runs kill the scenario process here and rely on the surrounding
  // per-test stale-node cleanup for descendants.
  killTrackedChild(child.pid, 'SIGKILL')
  ACTIVE_PROCESS_GROUPS.delete(child.pid)
  clearTimeout(timer)
  const ms = Date.now() - start

  // Self-skip convention: a scenario exits 77 to declare itself non-applicable
  // here (e.g. it needs a cadence knob or a non-loopback topology this harness
  // can't provide). Reported as SKIP — never an inflated PASS or a FAIL.
  if (code === 77 && !timedOut) {
    const line = (stdout + stderr).split('\n').reverse().find((l) => l.includes('SKIP:'))
    const reason = line ? line.replace(/^.*SKIP:\s*/, '').trim() : 'self-skip'
    return { ok: true, skipped: true, reason, code, timedOut, ms, stdout, stderr, root }
  }

  return { ok: code === 0 && !timedOut, code, timedOut, ms, stdout, stderr, root }
}

function printResult(test, r) {
  if (r.skipped) {
    console.log(`- ${test.name.padEnd(28)}  SKIP  (${r.reason})`)
    return
  }
  if (r.ok) {
    console.log(`✓ ${test.name.padEnd(28)}  PASS  ${fmtMs(r.ms)}`)
  } else {
    console.log(`✗ ${test.name.padEnd(28)}  FAIL  ${fmtMs(r.ms)}  exit=${r.code}${r.timedOut ? ' timeout' : ''}`)
    const tail = (r.stdout + r.stderr).split('\n').filter(Boolean).slice(-25).join('\n')
    if (tail) console.log(tail.split('\n').map((l) => `    ${l}`).join('\n'))
    console.log(`    logs: ${r.root}`)
  }
}

// Filter tests down to what should run.
const toRun = TESTS.filter((t) => {
  if (TAG_FILTER && !t.tags?.some((tag) => TAG_FILTER.has(tag))) return false
  if (FILTER && !FILTER.test(t.name)) return false
  return true
})
const activeTests = [...toRun].sort((a, b) => {
  const aPriority = PRIORITY_INDEX.get(a.name)
  const bPriority = PRIORITY_INDEX.get(b.name)
  if (aPriority !== undefined || bPriority !== undefined) {
    return (aPriority ?? Number.POSITIVE_INFINITY) - (bPriority ?? Number.POSITIVE_INFINITY)
  }
  return (TEST_INDEX.get(a.name) ?? 0) - (TEST_INDEX.get(b.name) ?? 0)
})

const releaseSuiteLock = acquireSuiteLock()
process.once('exit', releaseSuiteLock)
process.once('SIGINT', () => { killActiveProcessGroups(); killStaleLatticeNodes(); releaseSuiteLock(); process.exit(130) })
process.once('SIGTERM', () => { killActiveProcessGroups(); killStaleLatticeNodes(); releaseSuiteLock(); process.exit(143) })

// Kill any leftover nodes from a previous run before starting.
killStaleLatticeNodes()

PORT_BASE_START = await choosePortBase(activeTests)
const portRangeEnd = PORT_BASE_START + TESTS.length * PORT_SLICE_SIZE + Math.max(2, Math.min(PORT_SLICE_SIZE, PORT_PROBE_WIDTH)) - 1

const tagNote = TAG_FILTER ? `  tags=${[...TAG_FILTER].join(',')}` : ''
console.log(`=== smoke-all ===  run=${RUN_ID}  workers=${WORKERS}  timeout-scale=${TIMEOUT_SCALE}×  tests=${activeTests.length}${tagNote}`)
console.log(`ports=${PORT_BASE_START}-${portRangeEnd}  slice=${PORT_SLICE_SIZE}  probed=${Math.max(2, Math.min(PORT_SLICE_SIZE, PORT_PROBE_WIDTH))}`)
console.log('')

const results = []
let failFastTriggered = false

if (WORKERS <= 1) {
  // Sequential mode: kill stale nodes before/after each test, optionally stream output.
  for (const test of activeTests) {
    if (failFastTriggered) break
    killStaleLatticeNodes()
    process.stdout.write(`▶ ${test.name.padEnd(28)}  `)
    if (STREAM) process.stdout.write('\n')
    const r = await runOne(test, { stream: STREAM })
    killStaleLatticeNodes()
    if (r.skipped) {
      console.log(`SKIP (${r.reason})`)
    } else {
      if (STREAM) {
        printResult(test, r)
      } else {
        if (r.ok) console.log(`PASS  ${fmtMs(r.ms)}`)
        else {
          console.log(`FAIL  ${fmtMs(r.ms)}  exit=${r.code}${r.timedOut ? ' timeout' : ''}`)
          const tail = (r.stdout + r.stderr).split('\n').filter(Boolean).slice(-25).join('\n')
          if (tail) console.log(tail.split('\n').map((l) => `    ${l}`).join('\n'))
          console.log(`    logs: ${r.root}`)
        }
      }
    }
    results.push({ test, ...r })
    if (FAIL_FAST && !r.ok && !r.skipped) failFastTriggered = true
  }
} else {
  // Parallel mode: run up to WORKERS tests concurrently.
  // No per-test killStaleLatticeNodes (would kill sibling test processes).
  // Tests manage their own process lifecycles via net.teardown().
  const queue = [...activeTests]

  let active = 0
  let activeHeavy = 0
  const pending = [...queue]

  await new Promise((resolveAll) => {
    function dispatch() {
      while (active < WORKERS && !failFastTriggered) {
        // Pick the first pending test that's eligible right now: any light test,
        // or a heavy one only while the heavy cap has room. This keeps light
        // tests flowing on the remaining workers when heavies are capped.
        let pickIdx = -1
        for (let i = 0; i < pending.length; i++) {
          if (HEAVY_TESTS.has(pending[i].name) && activeHeavy >= HEAVY_CONCURRENCY) continue
          pickIdx = i
          break
        }
        if (pickIdx === -1) break // only capped-heavy tests remain; wait for one to finish
        const test = pending.splice(pickIdx, 1)[0]
        const isHeavy = HEAVY_TESTS.has(test.name)
        active++
        if (isHeavy) activeHeavy++
        console.log(`▶ starting  ${test.name}`)
        runOne(test).then((r) => {
          active--
          if (isHeavy) activeHeavy--
          printResult(test, r)
          results.push({ test, ...r })
          if (FAIL_FAST && !r.ok) failFastTriggered = true
          if (active === 0 && (pending.length === 0 || failFastTriggered)) {
            resolveAll()
          } else {
            dispatch()
          }
        })
      }
      if (active === 0 && (pending.length === 0 || failFastTriggered)) resolveAll()
    }
    dispatch()
  })
}

// Final cleanup.
killStaleLatticeNodes()

const ran = results.filter((r) => !r.skipped)
const passed = ran.filter((r) => r.ok)
const failed = ran.filter((r) => !r.ok)
const skippedResults = results.filter((r) => r.skipped)
const totalMs = ran.reduce((a, r) => a + (r.ms || 0), 0)
const wallMs = Date.now() - SUITE_STARTED_AT
const slowest = [...ran]
  .sort((a, b) => (b.ms || 0) - (a.ms || 0))
  .slice(0, 5)
  .map((r) => `${r.test.name}:${fmtMs(r.ms || 0)}`)

console.log(`\n=== summary ===`)
console.log(`  ${ran.length} ran, ${passed.length} passed, ${failed.length} failed, ${skippedResults.length} skipped`)
console.log(`  wall-clock: ${fmtMs(wallMs)} (test time ${fmtMs(totalMs)})`)
if (slowest.length) console.log(`  slowest: ${slowest.join(', ')}`)
if (failed.length) {
  console.log(`  failed: ${failed.map((f) => f.test.name).join(', ')}`)
  console.log(`  artifacts: ${RUN_ROOT}`)
}

process.exit(failed.length ? 1 : 0)
