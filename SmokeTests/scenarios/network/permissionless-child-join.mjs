// Permissionless child-chain discovery + follow: a node that only synced Nexus (never
// deployed Toy, never handed Toy's genesis or a peer address) DISCOVERS Toy from on-chain
// GenesisState and FOLLOWS it — the supervised reconciler resolves Toy's genesis from the
// synced parent state, fetches it from CAS by CID, and boots it as a supervised child.
//
// What's proven (vs multichain-late-joiner, which hands the joiner deploy.genesisHex):
//   1. discovery  — B lists Nexus's children from GenesisState (chain/children) and sees Toy.
//   2. follow     — B `chain follow Nexus/Toy` with NO genesis-hex / subscribe-p2p / peer.
//   3. resolution — B's reconciler self-resolves Toy's genesis (GenesisState CID + CAS fetch)
//                   and boots a supervised Toy whose genesis CID is A's EXACT Toy genesis.
//   4. sync       — B's Toy finds A's Toy via getChildPeers over the parent link (no peer was
//                   ever supplied), connects, and headers-first CONVERGES to A's Toy height.
//                   B runs no Toy miner and A mined past genesis before B joined, so reaching
//                   that height proves a real same-chain backfill — extraction gives only
//                   go-forward blocks it cannot apply without the pre-join history.
//
// A deployed child is only DISCOVERABLE once its genesisAction is mined into GenesisState
// (deploy = availability, not announcement), so A explicitly announces Toy first.

import { rmSync, mkdirSync } from 'node:fs'
import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, waitForProgress } from 'lattice-node-sdk'

const ROOT = smokeRoot('permissionless-child-join')
rmSync(ROOT, { recursive: true, force: true })
mkdirSync(ROOT, { recursive: true })
const [a, b, toyA] = await allocPorts(3, { seed: 71 })
const CHILD = 'Toy'
let failed = false
const fail = (m) => { console.error(`✗ ${m}`); failed = true }

console.log('=== permissionless child discovery + follow smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const funder = (await import('lattice-node-sdk')).genKeypair()
const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort, coinbaseAddress: funder.address }))

console.log('\n[1] A: boot Nexus, deploy + run Toy, announce it on-chain, mine both')
A.start()
await A.waitForRPC()
await A.readIdentity()
const infoA = await A.chainInfo()
const nexusDir = infoA.nexus
const childPathStr = `${nexusDir}/${CHILD}`
// Premine > 0 so the genesis carries a transaction: the follow path must fold the genesis
// TX bodies into the resolved genesis-hex, else B rebuilds a DIFFERENT genesis (mismatched
// CID) and the genesis-equality check below fails. (A premine-0 child hides that class of bug.)
const aToy = net.add(await A.spawnChild({ directory: CHILD, parentDirectory: nexusDir, ports: toyA, premine: 1_000_000_000, premineRecipient: funder.address }))
const toyGenesisHash = aToy._deployInfo.genesisHash
// THROTTLED from the start to ~3s/block — slower than B applies a block, so the live tip
// moves perpetually but a joiner can ride it (the production case). One continuous miner,
// never stopped (a restart stops mining the child).
const miner = net.addMiner(new LatticeMiner(A, [aToy], { minBlockIntervalMs: 2500 }))
await miner.start()

// Fund the funder (coinbase), then submit the genesisAction that ANNOUNCES Toy on Nexus —
// deploy pins/serves the genesis but does not write it to GenesisState; this does.
await waitFor(async () => (await A.balance(funder.address, nexusDir)) >= 5000 ? true : null,
  'funder coinbase', { timeoutMs: 400_000, intervalMs: 1000 })
await waitFor(async () => {
  const base = await A.nonce(funder.address, nexusDir)
  const r = await A.submitTx({
    nonce: base, signers: [funder.address], fee: 1000,
    accountActions: [{ owner: funder.address, delta: -1000 }],
    genesisActions: [{ directory: CHILD, blockCID: toyGenesisHash }],
  }, nexusDir, funder)
  return r.ok ? true : null
}, 'submit Toy genesisAction (announce)', { timeoutMs: 60_000, intervalMs: 1000 })

// Announce is mined into GenesisState once A can enumerate Toy as its child.
await waitFor(async () => {
  const r = await A.rpc('GET', `/api/chain/children?chainPath=${encodeURIComponent(nexusDir)}`).catch(() => null)
  const dirs = (r?.json?.children ?? []).map((c) => c.directory)
  return dirs.includes(CHILD) ? true : null
}, 'Toy announced in A Nexus GenesisState', { timeoutMs: 300_000, intervalMs: 2000 })

// Build a LIVE backlog: A keeps mining (throttled ~3s/block, never stopped). The followed
// child finds A's Toy via getChildPeers and headers-first backfills the pre-join history,
// then must keep RIDING the perpetually-moving tip — converging to a bounded lag, which is
// the production property a debug-FAST source can't satisfy (it makes B fall unboundedly
// behind). The throttle makes blocks arrive slower than B applies them, so B keeps up.
const TARGET = 6
await waitForProgress(async () => aToy.height(CHILD), (h) => h >= TARGET,
  `A Toy ≥ ${TARGET} (live backlog)`, { stallMs: 300_000, intervalMs: 1000 })
console.log(`  A live (throttled ~3s/block): ${nexusDir}@${await A.height(nexusDir)} ${CHILD}@${await aToy.height(CHILD)}`)

console.log('\n[3] B: fresh node, peer A for Nexus, supervise children')
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: b.port, rpcPort: b.rpcPort }))
B.start(['--peer', A.peerArg(), '--supervise-children'])
await B.waitForRPC()

console.log('\n[4] B discovers Toy from its OWN synced GenesisState (chain/children)')
// Discovery requires B to have synced past the announce block — poll until Toy appears.
const discovered = await waitFor(async () => {
  const r = await B.rpc('GET', `/api/chain/children?chainPath=${encodeURIComponent(nexusDir)}`).catch(() => null)
  const dirs = (r?.json?.children ?? []).map((c) => c.directory)
  return dirs.includes(CHILD) ? dirs : null
}, 'B discovered Toy from synced GenesisState', { timeoutMs: 240_000, intervalMs: 2000 })
console.log(`  ✓ B discovered children: ${JSON.stringify(discovered)}`)

console.log('\n[5] B follows Nexus/Toy — no genesis-hex / subscribe-p2p / peer supplied')
const fol = await B.rpc('POST', '/api/chain/follow', { chainPath: [nexusDir, CHILD] })
if (!fol.ok) fail(`chain/follow failed: ${JSON.stringify(fol.json)}`)

// B's reconciler self-resolved Toy's genesis and spawned a supervised Toy; it registers the
// child's RPC endpoint in chain/map once up.
console.log('\n[6] B\'s reconciler-spawned Toy boots A\'s genesis, then finds A\'s Toy + headers-first syncs')
let childEndpoint = null
await waitFor(async () => {
  const m = await B.rpc('GET', '/api/chain/map').catch(() => null)
  const ep = m?.json?.[childPathStr]
  if (ep) { childEndpoint = ep; return true }
  return null
}, 'B spawned + registered the followed Toy', { timeoutMs: 240_000, intervalMs: 3000 }).catch(() => null)
if (!childEndpoint) { fail('B never spawned/registered the followed Toy (genesis resolution or spawn failed)'); net.teardown(); await sleep(500); process.exit(1) }
console.log(`  B Toy endpoint: ${childEndpoint}`)

// B's Toy booted A's EXACT Toy genesis (resolved from GenesisState — verified identical CID).
const childHeight = async () => {
  const info = await fetch(`${childEndpoint}/chain/info`).then((x) => x.json()).catch(() => null)
  return { genesis: info?.genesisHash, height: info?.chains?.find((c) => c.directory === CHILD)?.height ?? 0 }
}
const first = await childHeight()
if (!first.genesis) fail('B Toy child RPC did not report a genesis (spawn/boot failed)')
else if (first.genesis !== toyGenesisHash) fail(`B Toy booted genesis ${first.genesis} != A's Toy genesis ${toyGenesisHash} (resolution produced wrong genesis)`)

// B's Toy backfills the pre-join history AND rides the live, perpetually-moving tip. B runs
// NO Toy miner, so it reaches these heights only by syncing from A's Toy — found via
// getChildPeers (no --peer ever supplied). Because A keeps mining (throttled, never frozen),
// this proves BOTH backfill AND bounded-lag tracking of a moving tip.
if (!failed) {
  const aToyH = async () => await aToy.height(CHILD)
  const K = 5  // allowable lag (blocks) behind the moving tip
  const caught = await waitFor(async () => {
    const [a, b] = await Promise.all([aToyH(), childHeight().then((x) => x.height)])
    return a >= TARGET && b >= a - K ? { a, b } : null
  }, `B Toy caught up to within ${K} of the live tip`, { timeoutMs: 300_000, intervalMs: 2000 }).catch(() => null)
  if (!caught) {
    fail(`B Toy did not catch the live moving tip (B@${(await childHeight()).height}, A@${await aToyH()})`)
  } else {
    // Require B to ADVANCE past its catch-up height AND stay within K while A mines ADVANCE
    // more blocks — proving it rides the moving tip (bounded lag), not stuck or falling behind.
    const ADVANCE = 8
    const targetA = caught.a + ADVANCE
    const tracked = await waitFor(async () => {
      const [a, b] = await Promise.all([aToyH(), childHeight().then((x) => x.height)])
      return a >= targetA && b >= a - K && b > caught.b ? { a, b } : null
    }, `B Toy advanced + stayed within ${K} as A mined +${ADVANCE}`, { timeoutMs: 300_000, intervalMs: 2000 }).catch(() => null)
    if (!tracked) fail(`B Toy did not track the live tip (B@${(await childHeight()).height}, A@${await aToyH()}, caught@${caught.b})`)
    else console.log(`  ✓ B Toy backfilled + rode the live moving tip: A@${tracked.a} B@${tracked.b} (lag ${tracked.a - tracked.b}) — getChildPeers bootstrap + bounded-lag tracking`)
  }
}

if (failed) { console.error('\n=== permissionless discovery+follow+sync: FAILED ==='); net.teardown(); await sleep(500); process.exit(1) }
console.log('\n✓ permissionless join: B discovered Toy from GenesisState, followed it (no genesis/peer flags), self-resolved + booted A\'s exact genesis, found A\'s Toy via getChildPeers, and headers-first synced to A\'s height')
net.teardown()
await sleep(500)
process.exit(0)
