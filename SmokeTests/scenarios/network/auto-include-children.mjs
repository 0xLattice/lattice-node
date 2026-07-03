// Auto-include of served children in the merged template.
//
// A node that is already SERVING a child (deployed + registered via spawnChild) must fold
// that child into the merged mining template ON ITS OWN — so a coordinator pointed at just
// the node, with NO --child-node, still merge-mines the child. This keeps "which children to
// mine" a NODE concern (chain membership) rather than something the miner/coordinator wires.

import { allocPorts, smokeRoot } from 'lattice-node-sdk/env'
import { LatticeNode, LatticeNetwork, LatticeMiner, sleep, waitFor } from 'lattice-node-sdk'

const ROOT = smokeRoot('auto-include-children')
const [nexusPorts, childPorts] = await allocPorts(2)
const CHILD = 'Auto'

console.log('=== auto-include-children smoke test ===')
const net = new LatticeNetwork()
net.installSignalHandlers()

const node = net.add(new LatticeNode({
  name: 'node',
  dir: `${ROOT}/node`,
  port: nexusPorts.port,
  rpcPort: nexusPorts.rpcPort,
}))
node.start()
await node.waitForRPC()
const nexusDir = (await node.chainInfo()).nexus

console.log('\n[1] Deploy + spawn a child ON the node (it register-rpc\'s itself with the parent)...')
const child = await node.spawnChild({
  directory: CHILD,
  parentDirectory: nexusDir,
  ports: childPorts,
})
net.add(child)

console.log('\n[2] Mine with a coordinator that is given NO children (empty childNodes → no --child-node)...')
// The whole point: the coordinator does not know about the child. The node must auto-include
// its registered child in the template it composes.
const miner = new LatticeMiner(node, [])
net.addMiner(miner)
await miner.start()

console.log('\n[3] Both Nexus AND the auto-included child must advance...')
const heights = await waitFor(async () => {
  const [nh, ch] = await Promise.all([node.height(nexusDir), child.height(CHILD)])
  return nh >= 5 && ch >= 5 ? { nexus: nh, child: ch } : null
}, `${nexusDir} + auto-included ${CHILD} both reach height 5 (no --child-node)`, {
  timeoutMs: 120_000,
  intervalMs: 500,
})
console.log(`  ${nexusDir}@${heights.nexus}, ${CHILD}@${heights.child} — auto-include works`)

// Sanity: the child genuinely advanced (a broken auto-include would leave it at genesis).
if (heights.child < 5) {
  console.error(`  ${CHILD} did not advance without an explicit --child-node: ${heights.child}`)
  net.teardown(); await sleep(500); process.exit(1)
}

console.log('\nauto-include-children smoke test passed.')
await net.teardown()
await sleep(500)
process.exit(0)
