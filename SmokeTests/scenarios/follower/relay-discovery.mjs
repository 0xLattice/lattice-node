// Relay-masked same-chain discovery (regression for the getChildPeers rendezvous).
//
// A NAT'd follower reaches its same-chain peers over a `--use-relay` circuit relay. The
// relay is a Nexus backbone node that NEVER serves the followed child chain, yet it is a
// genuine direct Ivy connection (it lives in `connections`). The bug: `chainGossipPeerCount`
// returned Ivy's `directPeerCount`, which counts that relay, so once the followed child was
// PAST GENESIS `needsSameChainPeer` returned false and the getChildPeers discovery never ran
// again — a relay-only follower could never (re)find a same-chain source. Localhost smokes
// miss it because with no relay `directPeerCount` starts at 0.
//
// Making discovery load-bearing (not the merged-mining parent-extraction shortcut):
// bChild subscribes to a CONTENT-LESS Nexus follower B, not to the deploying node A. B
// syncs Nexus (so it can answer the getChildPeers rendezvous) but does NOT hold the child
// block bodies, so bChild can only advance by fetching bodies from a same-chain source it
// discovers over the rendezvous.
//
// SCOPE — this is realistic integration coverage, not the buggy/fixed discriminator.
// The exact NAT masking (a follower whose ONLY connection is the relay) cannot be
// reproduced on a single loopback host: a real NAT node can't receive inbound, but on
// loopback a source always dials back into bChild (via its observed socket address, even
// with an unroutable advertised address), handing it a same-chain link for free — so
// `needsSameChainPeer` is legitimately false regardless of the relay-count bug. The
// deterministic buggy/fixed discriminator lives in Tests/LatticeNodeTests/
// RelayPeerCountTests.swift (relay excluded from the count + `ed01` normalization). This
// smoke exercises the end-to-end realistic path — a NAT'd follower configured with a
// backbone relay reboots past genesis and recovers the child chain via the rendezvous —
// so a regression that breaks that path (hang/crash) is still caught here.
//
// Topology (all loopback processes):
//   A(Nexus) ── deploys + mines ──▶ aChild            (the SOURCE: serves the child bodies)
//   R(Nexus)                                            (standalone backbone relay)
//   B(Nexus, follows the child) ── content-less parent + rendezvous for bChild
//   bChild ── --subscribe-p2p B, no --peer to a source ─▶ the FOLLOWER
//
//   [1-3] bChild boots WITHOUT a relay, discovers the source via getChildPeers over B, and
//         syncs to N (its initial, direct sync).
//   [4]   Reboot bChild as a NAT node past genesis behind ONLY the backbone relay R, with
//         its peer cache cleared (a fresh NAT node has no cached peers).
//   [5]   bChild must recover the child chain through its relay + the rendezvous and track
//         the source past its reboot tip.

import { spawn } from 'node:child_process'
import { mkdirSync, createWriteStream, rmSync } from 'node:fs'
import { allocPorts, smokeRoot, BIN, requireBinary } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

requireBinary()
const ROOT = smokeRoot('relay-discovery')
const [a, r, bn, bc, childPorts, bsupPorts] = await allocPorts(6)
const CHILD = 'Relayed'
const TARGET = 5        // initial synced tip
const EXTRA = 4         // blocks the follower must still track after the relay-only reboot

console.log('=== relay-discovery smoke test (relay must not mask same-chain discovery) ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const A = net.add(new LatticeNode({ name: 'A', dir: `${ROOT}/A`, port: a.port, rpcPort: a.rpcPort }))
const R = net.add(new LatticeNode({ name: 'R', dir: `${ROOT}/R`, port: r.port, rpcPort: r.rpcPort }))
const B = net.add(new LatticeNode({ name: 'B', dir: `${ROOT}/B`, port: bn.port, rpcPort: bn.rpcPort }))

console.log('\n[1] Boot A (source parent), R (backbone relay), deploy + mine the child...')
A.start(); R.start()
await Promise.all([A.waitForRPC(), R.waitForRPC()])
await Promise.all([A.readIdentity(), R.readIdentity()])
const nexusDir = (await A.chainInfo()).nexus

const aChild = net.add(await A.spawnChild({ directory: CHILD, parentDirectory: nexusDir, ports: childPorts, premine: 0 }))
const childGenesis = aChild._deployInfo.genesisHash
const genesisHex = aChild._deployInfo.genesisHex
console.log(`  A/${CHILD} source up; relay R = ${R.peerArg().slice(0, 24)}…`)

const miner = net.addMiner(new LatticeMiner(A, [aChild], { workers: 1, minBlockIntervalMs: 3000 }))
await miner.start()
await A.announceChild({ nexusDir, child: CHILD, genesisHash: childGenesis })
await waitFor(async () => (await aChild.height(CHILD)) >= TARGET ? true : null,
  `source ${CHILD} ≥ ${TARGET}`, { timeoutMs: 240_000, intervalMs: 1000 })

console.log('\n[2] Boot B: a content-less Nexus follower that FOLLOWS the child (the rendezvous)...')
// B peers A for Nexus and follows the child, so it manages the directory (can answer the
// getChildPeers rendezvous) and its supervised child fetches the bodies from A's source —
// but B itself (the Nexus process bChild subscribes to) never holds the child bodies.
B.start(['--peer', A.peerArg(), '--supervise-children'], { env: { LATTICE_SUPERVISE_RECONCILE_SECONDS: '3' } })
await B.waitForRPC()
await B.followChild({ nexusDir, child: CHILD, expectGenesis: childGenesis })
console.log('  B follows the child (rendezvous ready)')

// bChild: a raw single-chain follower. It subscribes to B (content-less parent) and is
// given NO --peer to any same-chain source — the source must be found via getChildPeers.
const bdir = `${ROOT}/bChild`
mkdirSync(bdir, { recursive: true })
const bLog = createWriteStream(`${ROOT}/bChild.log`, { flags: 'a' })
// Two boot modes: the first sync is DIRECT (no relay); the NAT reboot bootstraps to the
// real backbone relay R (`--use-relay` + `--peer R`, the realistic deploy posture — relays
// in config, still no hand-fed same-chain source).
const bArgs = (withRelay) => [
  'node', '--genesis-hex', genesisHex,
  '--chain-directory', CHILD, '--chain-path', `${nexusDir}/${CHILD}`,
  '--subscribe-p2p', B.peerArg(),
  '--port', String(bc.port), '--rpc-port', String(bc.rpcPort), '--data-dir', bdir,
  '--no-dns-seeds', '--min-peer-key-bits', '0', '--min-fee-rate', '0',
  // Simulate NAT: advertise an unroutable (RFC 5737 TEST-NET) endpoint so NO peer can dial
  // INTO bChild. Like a real NAT'd node it can only reach same-chain peers by dialing OUT
  // via getChildPeers — the outbound path the relay-count bug masks. (On loopback without
  // this, some peer dials in and hands bChild a same-chain link for free, hiding the bug.)
  '--external-address', `192.0.2.123:${bc.port}`,
  ...(withRelay ? ['--peer', R.peerArg(), '--use-relay', R.peerArg()] : []),
]
const bootBChild = (withRelay) => {
  const p = spawn(BIN, bArgs(withRelay), { stdio: ['ignore', 'pipe', 'pipe'] })
  p.stdout.pipe(bLog, { end: false }); p.stderr.pipe(bLog, { end: false })
  p.on('exit', (code) => console.log(`[bChild] exited code=${code}`))
  return p
}
const bHeight = async () => {
  try {
    const j = await (await fetch(`http://127.0.0.1:${bc.rpcPort}/api/chain/info`)).json()
    return j?.chains?.find((c) => c.directory === CHILD)?.height ?? 0
  } catch { return -1 }
}
const stopBChild = async (p) => {
  try { p.kill('SIGTERM') } catch {}
  for (let i = 0; i < 40 && p.exitCode === null && p.signalCode === null; i++) await sleep(100)
  if (p.exitCode === null && p.signalCode === null) { try { p.kill('SIGKILL') } catch {} ; await sleep(300) }
}

console.log('\n[3] Boot bChild (direct, no relay): discover the source via getChildPeers + sync...')
let bProc = bootBChild(false)
await waitFor(async () => {
  const h = await bHeight()
  process.stdout.write(`\r  bChild@${h} (syncing to ${TARGET})   `)
  return h >= TARGET ? true : null
}, `bChild synced to ≥ ${TARGET}`, { timeoutMs: 180_000, intervalMs: 1000 })
const baseline = await bHeight()
console.log(`\n  bChild synced to ${CHILD}@${baseline}`)

console.log('\n[4] Reboot bChild as a NAT node behind ONLY the backbone relay R...')
// A fresh NAT node reboots with no cached peers — only its configured relay. Clearing the
// peer cache forces it back onto the getChildPeers rendezvous. Chain state is kept, so it
// reboots PAST GENESIS — the exact condition the relay-count bug mishandles.
await stopBChild(bProc)
await sleep(1500)
rmSync(`${bdir}/peers.json`, { force: true })
bProc = bootBChild(true)
await waitFor(async () => (await bHeight()) >= baseline ? true : null,
  `bChild rebooted at persisted tip ≥ ${baseline}`, { timeoutMs: 120_000, intervalMs: 1000 })
console.log(`  bChild rebooted at ${CHILD}@${await bHeight()} behind relay R (peer cache cleared)`)

console.log('\n[5] bChild must recover via its relay + the rendezvous and track the source...')
const goal = baseline + EXTRA
await waitFor(async () => (await aChild.height(CHILD)) >= goal ? true : null,
  `source ${CHILD} advanced ≥ ${goal}`, { timeoutMs: 240_000, intervalMs: 1000 })
const finalH = await waitFor(async () => {
  const h = await bHeight()
  process.stdout.write(`\r  bChild@${h} (tracking source to ${goal})   `)
  return h >= goal ? h : null
}, `bChild tracked source past reboot tip ≥ ${goal}`, { timeoutMs: 180_000, intervalMs: 2000 })

await miner.stop()
console.log(`\n\n  ✓ bChild (NAT'd, behind relay R) recovered the child chain via the rendezvous`)
console.log(`    and advanced ${baseline} → ${finalH} past its reboot tip`)

console.log('\n✓ relay-discovery smoke test passed.')
await stopBChild(bProc)
net.teardown()
await sleep(500)
process.exit(0)
