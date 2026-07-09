// Child-sync fallback: DIRECT child-chain headers-first catch-up (no parent
// extraction to hide behind — cf. multichain-late-joiner, which converges via
// Nexus carriers). A mines Nexus + child "Toy" so the follower builds a TALL
// local own-target base, B joins and converges, then B goes OFFLINE while A
// mines a further Toy segment. B restarts with its parent Nexus INTENTIONALLY
// BEHIND (no Nexus peer), so it never receives the Nexus blocks that embed
// the new Toy segment — parent extraction is impossible and the Toy follower
// must catch up DIRECTLY from its persisted same-chain peer. The follower is
// frozen at height H with local own-target work EXCEEDING the segment's —
// the exact shape the old whole-chain syncer floor + admission work-compare
// refused forever ("sync refused: peer work" / insufficientWork loop). It
// must fast-forward-SYNC to A's carrier tip anyway.

import { rmSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('child-sync-fallback')
const [a, b, toyA] = await allocPorts(3, { seed: 97 })
const CHILD = 'Toy'
const BASE_HEIGHT = 6      // follower's local base H: 6 trivial own-target blocks
const SEGMENT = 3          // offline segment K: 3 blocks — K*w < H*w by construction

console.log('=== child-sync-fallback smoke test (direct child fast-forward sync) ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: b.port, rpcPort: b.rpcPort }))

console.log('\n[1] Boot A, deploy + announce child, mine both to the base height...')
A.start()
await A.waitForRPC()
await A.readIdentity()
const nexusDir = (await A.chainInfo()).nexus

const aToy = net.add(await A.spawnChild({ directory: CHILD, parentDirectory: nexusDir, ports: toyA, premine: 0 }))
const toyGenesis = aToy._deployInfo.genesisHash

let miner = net.addMiner(new LatticeMiner(A, [aToy]))
await miner.start()
// Announce AFTER the miner is up: the announce tx needs a funded coinbase
// and an on-chain confirmation, both of which require blocks.
await A.announceChild({ nexusDir, child: CHILD, genesisHash: toyGenesis })
await waitFor(async () => {
  const [nxH, toyH] = await Promise.all([A.height(nexusDir), aToy.height(CHILD)])
  process.stdout.write(`\r  A: ${nexusDir}@${nxH} ${CHILD}@${toyH}   `)
  return nxH >= BASE_HEIGHT && toyH >= BASE_HEIGHT ? true : null
}, `A heights ≥ ${BASE_HEIGHT}`, { timeoutMs: 240_000, intervalMs: 1000 })
await miner.stop()
await A.awaitQuiesced(nexusDir, { timeoutMs: 20_000, idleMs: 2_000 })
await aToy.awaitQuiesced(CHILD, { timeoutMs: 30_000, idleMs: 4_000 })

console.log('\n\n[2] B joins permissionlessly and converges on the base...')
B.start(['--peer', A.peerArg(), '--supervise-children'], { env: { LATTICE_SUPERVISE_RECONCILE_SECONDS: '3' } })
await B.waitForRPC()
const bToy = await B.followChild({ nexusDir, child: CHILD, expectGenesis: toyGenesis })

await waitFor(async () => {
  const [aToyTip, bToyTip, aNxTip, bNxTip] = await Promise.all([
    aToy.tip(CHILD), bToy.tip(), A.tip(nexusDir), B.tip(nexusDir)])
  return aToyTip && aToyTip === bToyTip && aNxTip === bNxTip ? true : null
}, 'B converged on the frozen base tips', { timeoutMs: 240_000, intervalMs: 2000 })
const baseToyH = await bToy.height()
console.log(`  B base: ${CHILD}@${baseToyH} (tips match A)`)

console.log('\n[3] Stop B; A mines a further child segment while B is offline...')
const bNxBase = await B.height(nexusDir)
await B.stop()
// The supervised follower must go down WITH B — a still-live follower would
// track the new blocks via gossip and mask the sync path under test.
await waitFor(async () => {
  try {
    await fetch(`${bToy.endpoint}/chain/info`, { signal: AbortSignal.timeout(500) })
    return null
  } catch { return true }
}, 'B and its supervised follower are down', { timeoutMs: 30_000, intervalMs: 500 })
await sleep(1000)

miner = net.addMiner(new LatticeMiner(A, [aToy]))
await miner.start()
const targetToyH = baseToyH + SEGMENT
await waitFor(async () => {
  const toyH = await aToy.height(CHILD)
  process.stdout.write(`\r  A: ${CHILD}@${toyH} (target ${targetToyH})   `)
  return toyH >= targetToyH ? true : null
}, `A ${CHILD} ≥ ${targetToyH}`, { timeoutMs: 240_000, intervalMs: 1000 })
await miner.stop()
await A.awaitQuiesced(nexusDir, { timeoutMs: 20_000, idleMs: 2_000 })
await aToy.awaitQuiesced(CHILD, { timeoutMs: 30_000, idleMs: 4_000 })

const aNxFinal = await A.height(nexusDir)
const aToyH = await aToy.height(CHILD)
const aToyTip = await aToy.tip(CHILD)
console.log(`\n  A frozen: ${nexusDir}@${aNxFinal}, ${CHILD}@${aToyH}`)
if (aToyH - baseToyH >= baseToyH) {
  console.error(`  segment (${aToyH - baseToyH}) not smaller than base (${baseToyH}) — shape invalid`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log(`\n[4] Restart B with NO Nexus peer (parent intentionally behind @${bNxBase}): the follower is frozen at ${CHILD}@${baseToyH} with local own-target work > segment's and must DIRECT-sync to ${CHILD}@${aToyH}...`)
// Wipe B's NEXUS-level peer/anchor stores so its parent chain cannot
// reconnect to A and catch up (which would re-enable parent extraction and
// mask the direct child-sync path). The follower's OWN peer store under
// B/children/Toy is untouched — that persisted same-chain peer is exactly
// how it must reach A's Toy process.
rmSync(`${ROOT}/B/peers.json`, { force: true })
rmSync(`${ROOT}/B/anchors.json`, { force: true })
B.start(['--supervise-children'], { env: { LATTICE_SUPERVISE_RECONCILE_SECONDS: '3' } })
await B.waitForRPC()

// The supervision reconciler re-spawns the followed child; re-resolve its
// endpoint from B's chain/map (the port can differ across restarts).
const childPathStr = `${nexusDir}/${CHILD}`
let bToyEndpoint = null
await waitFor(async () => {
  const m = await B.rpc('GET', '/api/chain/map').catch(() => null)
  const ep = m?.json?.[childPathStr]
  if (ep) { bToyEndpoint = ep; return true }
  return null
}, 'B re-registered the followed child after restart', { timeoutMs: 240_000, intervalMs: 3000 })
const bToyInfo = async () => {
  const i = await fetch(`${bToyEndpoint}/chain/info`).then((x) => x.json()).catch(() => null)
  return i?.chains?.find((c) => c.directory === CHILD) ?? null
}

console.log('\n[5] B must fast-forward the child DIRECTLY to the carrier tip...')
const finalH = await waitFor(async () => {
  const c = await bToyInfo()
  process.stdout.write(`\r  B: ${CHILD}@${c?.height ?? '?'} (target ${aToyH})   `)
  return c && c.tip === aToyTip && c.height === aToyH ? c.height : null
}, `B ${CHILD} direct-synced to A's carrier tip`, { timeoutMs: 240_000, intervalMs: 2000 })

// Paranoia: the catch-up cannot have come from parent extraction — B has no
// Nexus peer, so its parent chain must still be parked at the pre-offline
// height, strictly behind the Nexus blocks that embed the new toy segment.
const bNxNow = await B.height(nexusDir)
if (bNxNow >= aNxFinal) {
  console.error(`\n  B's Nexus caught up (${bNxNow} >= ${aNxFinal}) — parent-extraction masking possible, scenario invalid`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`\n  B's ${nexusDir} still behind (${bNxNow} < ${aNxFinal}) — catch-up was DIRECT child sync`)

console.log(`  ✓ B direct-synced ${CHILD} ${baseToyH} → ${finalH} (segment ${finalH - baseToyH} blocks, local base ${baseToyH} > segment — old gates refused this forever)`)
console.log('\n✓ child-sync-fallback smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
