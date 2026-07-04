// Verify the child-coinbase fix on the --supervise-children (reconciler) path.
//
// A deploys+mines+announces a child, then freezes. B boots with --supervise-children,
// followChild()s it (the reconciler spawns B's child instance via ChildSpec), then B MINES
// that followed child. Before the fix, the reconciler-spawned child had no --coinbase-address,
// so B's blocks forfeited the reward → B's coinbase balance stays 0. With the fix, B's child
// inherits B's --coinbase-address and B earns height*reward.

import { rmSync, mkdirSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('supervise-coinbase-verify')
rmSync(ROOT, { recursive: true, force: true }); mkdirSync(ROOT, { recursive: true })
const [a, b, childA] = await allocPorts(3)
const CHILD = 'ToyVerify'
const REWARD = 1024
const net = new LatticeNetwork()
net.installSignalHandlers()
function fail(m) { console.error(`  ✗ ${m}`); net.teardown(); process.exit(1) }

console.log('=== supervise-coinbase-verify (reconciler-spawned followed child must earn its coinbase) ===')
const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: b.port, rpcPort: b.rpcPort }))

console.log('\n[1] A: deploy + mine + announce child, then freeze...')
A.start(); const aBoot = await A.waitForRPC(); const nexusDir = aBoot.nexus; await A.readIdentity()
const aChild = net.add(await A.spawnChild({ directory: CHILD, parentDirectory: nexusDir, ports: childA, initialReward: REWARD, premine: 0 }))
await aChild.waitForRPC()
const childGenesis = aChild._deployInfo.genesisHash
const aMiner = net.addMiner(new LatticeMiner(A, [aChild], { workers: 2 }))
await aMiner.start()
await A.announceChild({ nexusDir, child: CHILD, genesisHash: childGenesis })
await waitFor(async () => (await A.height(nexusDir)) >= 5 && (await aChild.height(CHILD)) >= 5 ? true : null,
  'A reaches height 5', { timeoutMs: 300_000, intervalMs: 1000 })
await aMiner.stop()
await A.awaitQuiesced(nexusDir, { timeoutMs: 20_000, idleMs: 2000 })
await aChild.awaitQuiesced(CHILD, { timeoutMs: 30_000, idleMs: 4000 })
console.log(`  A frozen: ${CHILD}@${await aChild.height(CHILD)}`)

console.log('\n[2] B: --supervise-children, follow the child (reconciler spawns via ChildSpec)...')
B.start(['--peer', A.peerArg(), '--supervise-children'], { env: { LATTICE_SUPERVISE_RECONCILE_SECONDS: '3' } })
await B.waitForRPC(); await B.readIdentity()
const bCoinbase = B._keypair.address
await waitFor(async () => (await B.tip(nexusDir)) === (await A.tip(nexusDir)) ? true : null,
  'B syncs Nexus', { timeoutMs: 120_000, intervalMs: 1000 })
const bChild = await B.followChild({ nexusDir, child: CHILD, expectGenesis: childGenesis })
await sleep(6000) // let the reconciler-spawned child settle (it may or may not sync A's frozen tip)
console.log(`  B/${CHILD} followed (reconciler-spawned), height ${await bChild.height()}`)

console.log('\n[3] ASSERT the reconciler-spawned child process carries --coinbase-address...')
const ps = execSync(`pgrep -af "chain-directory ${CHILD}" 2>/dev/null || true`).toString()
const bLine = ps.split('\n').find(l => l.includes(`${ROOT}/B`))
if (!bLine) fail('could not find B\'s followed-child process')
if (bLine.includes(`--coinbase-address ${bCoinbase}`)) console.log(`  ✓ B's followed child launched WITH --coinbase-address ${bCoinbase.slice(0,14)}…`)
else fail(`B's followed child has NO --coinbase-address (fix not applied). args: ${bLine.slice(-160)}`)

console.log('\n[4] B mines the followed child; assert B EARNS the coinbase (0 before the fix)...')
const bBefore = await bChild.balance(bCoinbase, CHILD)
const startH = await bChild.height()
const bMiner = net.addMiner(new LatticeMiner(B, [bChild], { workers: 2 }))
await bMiner.start()
await waitFor(async () => (await bChild.height()) >= startH + 4 ? true : null, 'B mines 4 child blocks', { timeoutMs: 300_000, intervalMs: 1000 })
await bMiner.stop()
await bChild.awaitQuiesced(CHILD, { timeoutMs: 30_000, idleMs: 4000 })
const bAfter = await bChild.balance(bCoinbase, CHILD)
const mined = (await bChild.height()) - startH
console.log(`  B mined ${mined} child blocks; B coinbase balance ${bBefore} → ${bAfter}`)
if (bAfter > bBefore && bAfter >= mined * REWARD - REWARD) {
  console.log(`  ✅✅✅ reconciler-spawned followed child EARNS its coinbase (≈${mined}*${REWARD}) — FIX VERIFIED`)
} else {
  fail(`B earned ${bAfter - bBefore} over ${mined} blocks (expected ≈${mined * REWARD}) — coinbase NOT credited`)
}
net.teardown()
console.log('\n=== PASS ===')
process.exit(0)
