// Outbound-first NAT participation: a producer that CANNOT accept inbound dials
// (NAT-simulated via an unroutable RFC 5737 TEST-NET --external-address) and has
// NO --use-relay must still deliver its newly mined blocks to a public follower.
// Push-gossip over the producer's own OUTBOUND connection is the PRIMARY path for
// the common producer→public-follower topology; relays exist only for relay-only
// (NAT-to-NAT) reachability. This is the regression proof behind the NAT guidance
// in docs/running-a-child-chain.md ("NAT: outbound-first, relays as an assist").
//
// Topology (loopback, NO relay anywhere):
//   F (public follower, just listening)  ◀── single outbound dial ── P (producer)
//
//   P advertises 192.0.2.x, so every peer-visible endpoint of P is undialable —
//   the loopback pitfall where some node dials back INTO the "NAT'd" node and
//   hands it inbound connectivity for free cannot occur (same trick as
//   scenarios/follower/relay-discovery.mjs). Blocks reaching F can therefore
//   only have traveled over the one connection P dialed out to F.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor, peerCount } from 'lattice-node-sdk'

const ROOT = smokeRoot('outbound-push-no-relay')
const [f, p] = await allocPorts(2, { seed: 97 })
const TARGET = 8

console.log('=== outbound-push-no-relay smoke test (NAT producer pushes to public follower, no relay) ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const F = net.add(new LatticeNode({ name: 'F', dir: `${ROOT}/F`, port: f.port, rpcPort: f.rpcPort }))
const P = net.add(new LatticeNode({ name: 'P', dir: `${ROOT}/P`, port: p.port, rpcPort: p.rpcPort }))

console.log('\n[1] Boot F: the public follower (no peers, just listening)...')
F.start()
const fBoot = await F.waitForRPC()
const nexusDir = fBoot.nexus
await F.readIdentity()

console.log('\n[2] Boot P: NAT-simulated producer — unroutable external address, outbound --peer F, NO relay...')
P.start(['--peer', F.peerArg(), '--external-address', `192.0.2.77:${p.port}`])
await P.waitForRPC()
await waitFor(async () => (await peerCount(P)) >= 1 && (await peerCount(F)) >= 1 ? true : null,
  'P dialed out to F (both sides hold the connection)', { timeoutMs: 30_000 })

console.log(`\n[3] Mine on P: F must receive new blocks pushed over P's outbound connection...`)
const miner = net.addMiner(new LatticeMiner(P, [], { workers: 1 }))
await miner.start()
await waitFor(async () => (await P.height(nexusDir)) >= TARGET ? true : null,
  `producer mined Nexus ≥ ${TARGET}`, { timeoutMs: 120_000, intervalMs: 500 })

// The follower must track the producer's chain live. These blocks can ONLY have
// traveled over P's outbound connection: P is undialable and no relay exists in
// this topology.
await waitFor(async () => (await F.height(nexusDir)) >= TARGET ? true : null,
  `follower received pushed blocks ≥ ${TARGET}`, { timeoutMs: 120_000, intervalMs: 500 })
console.log(`  F reached ${await F.height(nexusDir)} via push over P's outbound connection`)

console.log('\n[4] Freeze and require exact tip convergence...')
await miner.stop()
await P.awaitQuiesced(nexusDir)
await sleep(1000)
// Compare against P's CURRENT tip each poll and require P stable across the
// poll (an in-flight block right after miner.stop() must not race the check).
let lastPTip = null
await waitFor(async () => {
  const pTip = await P.tip(nexusDir)
  const stable = pTip === lastPTip
  lastPTip = pTip
  if (!stable) return null
  return (await F.tip(nexusDir)) === pTip ? true : null
}, 'follower converged on the producer tip', { timeoutMs: 60_000, intervalMs: 1000 })

console.log(`\n✓ follower converged on ${nexusDir}@${await F.height(nexusDir)} with no relay in the topology`)
console.log('✓ outbound-push-no-relay smoke test passed.')
net.teardown()
await sleep(500)
process.exit(0)
