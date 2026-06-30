// Heterogeneous per-chain difficulty under ONE merged miner: two sibling children with
// very different targetBlockTimes, merge-mined by a single miner, must retarget
// INDEPENDENTLY — a hash is graded per-chain, so one child's difficulty must not leak into
// the other's. child-epoch-difficulty proves ONE child retargets; MergedMiningTemplateTargetTests
// proves the template's target math; this proves the end-to-end property no smoke does: a
// single merged miner sustaining two children at genuinely DIFFERENT live difficulties. If
// per-chain target derivation were shared/leaky, the two would NOT diverge (the harder one
// would be graded at the easier target and stay easy, or both would track one difficulty).
//
// DETERMINISM: the retarget direction is a function of (actual block interval) vs
// (targetBlockTime), so it's only robust if each child's direction can't flip under load.
// We pick targetBlockTimes so far outside any achievable smoke block rate that the direction
// is unambiguous regardless of how fast/slow the box mines:
//   EasyChild  tbt=50ms        → no miner produces blocks <50ms apart (minBlockIntervalMs floors
//                                 it higher anyway) → blocks are ALWAYS "too slow" → ALWAYS eases to max.
//   HardChild  tbt=3_600_000ms → no smoke produces blocks >1h apart → blocks are ALWAYS "too fast"
//                                 → ALWAYS hardens below max.
// So the two diverge deterministically-in-practice. (The earlier tbt=5000ms for the hard child
// was the flake: under CI load the merged miner's interval drifted ABOVE 5s, so it eased like the
// easy child and both collapsed to max — a false "leak".) We then assert each child moved in ITS
// OWN direction — which is precisely what per-chain independence means.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitForProgress } from 'lattice-node-sdk'

const ROOT = smokeRoot('heterogeneous-child-targets')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })
const [ports, easyPorts, hardPorts] = await allocPorts(3, { seed: 271 })
const WINDOW = 4

console.log('=== heterogeneous-child-targets smoke test ===')
const net = new LatticeNetwork(); net.installSignalHandlers()
function fail(msg) { console.error(`  ✗ ${msg}`); net.teardown(); process.exit(1) }
const node = net.add(new LatticeNode({ name: 'node', dir: `${ROOT}/node`, port: ports.port, rpcPort: ports.rpcPort }))
node.start()
await node.waitForRPC()
const nexusDir = (await node.chainInfo()).nexus

// [1] Deploy two children with very different targetBlockTimes (→ divergent difficulty).
console.log('\n[1] Deploy EasyChild (tbt=50ms) + HardChild (tbt=1h) under one Nexus...')
const easy = net.add(await node.spawnChild({ directory: 'EasyChild', parentDirectory: nexusDir, ports: easyPorts, retargetWindow: WINDOW, targetBlockTime: 50, premine: 0 }))
const hard = net.add(await node.spawnChild({ directory: 'HardChild', parentDirectory: nexusDir, ports: hardPorts, retargetWindow: WINDOW, targetBlockTime: 3_600_000, premine: 0 }))

async function blockTarget(n, dir) {
  const r = await n.rpc('GET', `/api/block/latest?chainPath=${dir}`).catch(() => null)
  return r?.ok ? (r.json?.target ?? null) : null
}

// Genesis target (before any mining) — the per-child baseline each retarget moves FROM.
// Fixed-width 64-char unprefixed hex (UInt256.toHexString), so string < equals numeric <.
const [easyGen, hardGen] = await Promise.all([blockTarget(easy, 'EasyChild'), blockTarget(hard, 'HardChild')])

// [2] ONE merged miner advances both children past their retarget windows.
console.log('\n[2] Merge-mine both with a single miner past the retarget window...')
// Pin the miner cadence so the per-child block interval is deterministically WELL ABOVE
// EasyChild's tiny targetBlockTime (→ "too slow" → eases to trivial max) and far below
// HardChild's large one (→ "too fast" → hardens). Without this, a very fast idle box could
// drive EasyChild blocks <50ms apart and harden it too, narrowing the divergence.
const miner = net.addMiner(new LatticeMiner(node, [easy, hard], { workers: 2, minBlockIntervalMs: 200 }))
await miner.start()
await waitForProgress(async () => Math.min(await easy.height('EasyChild'), await hard.height('HardChild')),
  (h) => h >= WINDOW + 3, 'both children past retarget window', { stallMs: 120_000, intervalMs: 300 })
// Let difficulty settle a few more blocks past the window so the retarget has taken effect.
await waitForProgress(async () => await easy.height('EasyChild'), (h) => h >= WINDOW + 6,
  'EasyChild settles past window', { stallMs: 90_000, intervalMs: 300 })
await miner.stop()
await node.awaitQuiesced(nexusDir)

const [easyH, hardH] = await Promise.all([easy.height('EasyChild'), hard.height('HardChild')])
const [easyT, hardT] = await Promise.all([blockTarget(easy, 'EasyChild'), blockTarget(hard, 'HardChild')])
console.log(`  EasyChild: height=${easyH} target=${easyT?.slice(0, 24)}…`)
console.log(`  HardChild: height=${hardH} target=${hardT?.slice(0, 24)}…`)

// [3] THE TEST: each child retargeted in ITS OWN direction under the single merged miner.
// That is precisely per-chain independence — EasyChild's blocks are graded against
// EasyChild's tbt and HardChild's against HardChild's, with no cross-contamination. Harder
// target = numerically smaller hex (more leading zeros). Targets are fixed-width 64-char hex,
// so string < equals numeric <.
if (easyH < WINDOW || hardH < WINDOW) fail(`a child did not pass its retarget window (easy=${easyH} hard=${hardH})`)
if (!easyT || !hardT || !easyGen || !hardGen) fail('could not read a child block target')

// EasyChild (tbt=50ms): every real block is far slower than 50ms, so it must EASE — its target
// must not get harder than genesis. If it hardened, EasyChild's retarget was graded too fast
// (e.g. against HardChild's tbt) — a leak.
if (easyT < easyGen) fail(`EasyChild HARDENED (target ${easyT.slice(0, 16)}… < genesis ${easyGen.slice(0, 16)}…) — its blocks were graded too fast; per-chain difficulty leaked`)

// HardChild (tbt=1h): every real block is far faster than 1h, so it must HARDEN — its target
// must be strictly smaller than genesis. If it didn't, HardChild's retarget was graded too slow
// (e.g. against EasyChild's tbt) or shared — a leak. The 2× per-window clamp keeps this from
// overshooting, so it stays mineable.
if (!(hardT < hardGen)) fail(`HardChild did NOT harden (target ${hardT.slice(0, 16)}… ≥ genesis ${hardGen.slice(0, 16)}…) — its blocks were graded too slow; per-chain difficulty leaked/shared`)

// And the end state: HardChild strictly harder than EasyChild — two live, divergent difficulties
// under one miner. (Block COUNT is not asserted: under one merged miner per-child count is
// governed by template-fetch scheduling, not difficulty.)
if (!(hardT < easyT)) fail(`HardChild target (${hardT.slice(0, 16)}…) is not harder than EasyChild's (${easyT.slice(0, 16)}…) — children did not diverge`)
console.log('  ✓ each child retargeted in its own direction (Easy eased, Hard hardened) — per-chain independent difficulty under one merged miner')

console.log('\n✓ heterogeneous-child-targets smoke test passed.')
await net.teardown(); await sleep(500); process.exit(0)
