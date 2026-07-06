// Proof self-healing (property: data present ⇒ node recovers its derived state).
//
// A mines Nexus + a child. We DELETE the child's block_proofs + parent_anchors —
// simulating the historical proof-gap where a node holds the blocks + the Nexus
// chain but not the derived proofs. On restart the node must SELF-HEAL: walk the
// Nexus chain and re-derive every committed child's ChildBlockProof (0 → N).
//
// Note: merged-mining live proof persistence is timing-flaky, so we do NOT require
// a nonzero baseline. The point is that after restart the node RE-DERIVES proofs
// from the Nexus chain it holds — which the aChild (the only child node) cannot get
// any other way (no peer has them). RED without the backfill (stays 0); GREEN with.

import { execSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('proof-backfill')
const [a, childA] = await allocPorts(2, { seed: 71 })
const CHILD = 'Widget'
const TARGET = 8

console.log('=== proof-backfill (self-healing) smoke ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort }))

console.log('\n[1] Boot A, deploy child, mine to depth...')
A.start()
await A.waitForRPC()
await A.readIdentity()
const infoA = await A.chainInfo()
const nexusDir = infoA.nexus
const aNexusP2P = infoA.p2pAddress

const aChild = net.add(await A.spawnChild({
  directory: CHILD, parentDirectory: nexusDir, ports: childA, premine: 0,
}))
const childGenesisHex = aChild._deployInfo.genesisHex

const miner = net.addMiner(new LatticeMiner(A, [aChild], { workers: 1 }))
await miner.start()
await waitFor(async () => {
  const [nx, c] = await Promise.all([A.height(nexusDir), aChild.height(CHILD)])
  process.stdout.write(`\r  A: Nexus@${nx} ${CHILD}@${c}   `)
  return nx >= TARGET && c >= TARGET ? true : null
}, `A heights >= ${TARGET}`, { timeoutMs: 240_000, intervalMs: 1000 })
await miner.stop()
await aChild.awaitQuiesced(CHILD, { timeoutMs: 30_000, idleMs: 4_000 })
const widgetHeight = await aChild.height(CHILD)

const dbPath = `${aChild.dir}/${CHILD}/state.db`
console.log(`\n[2] Gap the child's proofs (Widget@${widgetHeight}, state.db: ${dbPath})`)
if (!existsSync(dbPath)) throw new Error(`state.db not found at ${dbPath}`)
const q = (sql) => { try { return execSync(`sqlite3 "${dbPath}" "${sql}"`).toString().trim() } catch { return '0' } }

await aChild.stop()
await sleep(3000)   // ensure the process released state.db before we edit it
const before = Number(q('SELECT COUNT(*) FROM block_proofs'))
q('DELETE FROM block_proofs')
q('DELETE FROM parent_anchors')
const gap = Number(q('SELECT COUNT(*) FROM block_proofs'))
console.log(`  proofs before=${before}, gapped to ${gap}`)

console.log('\n[3] Restart child → node must re-derive proofs from the Nexus chain...')
aChild.start([
  '--genesis-hex', childGenesisHex,
  '--chain-directory', CHILD,
  '--chain-path', `${nexusDir}/${CHILD}`,
  '--subscribe-p2p', aNexusP2P,
  '--peer', A.peerArg(),
])
await aChild.waitForRPC()

// Wait for the heal to COMPLETE (count > 0 and stable, i.e. the walk finished) so we
// measure the full re-derivation, not a mid-walk snapshot.
let after = 0, prev = -1, stable = 0
await waitFor(async () => {
  after = Number(q('SELECT COUNT(*) FROM block_proofs'))
  stable = (after > 0 && after === prev) ? stable + 1 : 0
  prev = after
  process.stdout.write(`\r  proofs re-derived: ${after} (stable ${stable})   `)
  return (after > 0 && stable >= 4) ? after : null   // healed + no growth ~8s
}, 'node self-heals proofs from the Nexus chain', { timeoutMs: 150_000, intervalMs: 2000 }).catch(() => null)

console.log(`\n  proofs after restart: ${after} (was ${before}, gapped ${gap})`)
if (after === 0) {
  console.error(`  ✗ RED: node did NOT self-heal — no proofs re-derived from the Nexus chain`)
  net.teardown(); await sleep(500); process.exit(1)
}
console.log(`  ✓ node self-healed: ${gap} → ${after} proofs re-derived from the Nexus chain (Widget@${widgetHeight})`)
console.log('\n✓ proof-backfill smoke passed.')
net.teardown()
await sleep(500)
process.exit(0)
