import Lattice
import Foundation
import Crypto
import Ivy
import Tally
import VolumeBroker

private func sleepUntilNextTick(_ duration: Duration) async -> Bool {
    do {
        try await Task.sleep(for: duration)
        return !Task.isCancelled
    } catch {
        return false
    }
}

struct ParentSubscriptionKeyFile: Codable {
    let publicKey: String
    let privateKey: String
}

/// Load — or grind once and persist — the worked identity key for the dedicated
/// parent-subscription Ivy. Grinding is Curve25519-keygen bound
/// (≈2^minBits key generations), so it is quick at the 16-bit mainnet default and
/// minutes only if raised; caching it in the data dir keeps that a per-identity cost
/// instead of a per-start cost. A cached key is re-ground only if it is
/// unreadable, fails the private→public consistency check, or no longer meets a
/// raised `minBits`.
func loadOrGrindParentSubscriptionKey(storagePath: URL, minBits: Int) -> (publicKey: String, privateKey: Data) {
    let path = storagePath.appendingPathComponent("parent-sub-identity.json")
    if let data = try? Data(contentsOf: path),
       let file = try? JSONDecoder().decode(ParentSubscriptionKeyFile.self, from: data),
       let priv = Data(hex: file.privateKey),
       let derived = try? Curve25519.Signing.PrivateKey(rawRepresentation: priv),
       derived.publicKey.rawRepresentation.map({ String(format: "%02x", $0) }).joined() == file.publicKey,
       KeyDifficulty.trailingZeroBits(of: file.publicKey) >= minBits {
        // Re-assert key-at-rest hygiene on the reuse path.
        #if !os(Windows)
        chmod(path.path, 0o600)
        #endif
        return (publicKey: file.publicKey, privateKey: priv)
    }
    if minBits > 0 {
        NodeLogger("parent-sub").info("Grinding parent-subscription key to \(minBits) trailing-zero bits — one-time per data dir, may take minutes")
    }
    let key = grindWorkedIdentityKey(minBits: minBits)
    let file = ParentSubscriptionKeyFile(
        publicKey: key.publicKey,
        privateKey: key.privateKey.map { String(format: "%02x", $0) }.joined()
    )
    if let encoded = try? JSONEncoder().encode(file) {
        try? writePrivateKeyFile(encoded, to: path)
    }
    return key
}

func deterministicPort(basePort: UInt16, directory: String) -> UInt16 {
    var h: UInt32 = 2166136261
    for byte in directory.utf8 { h = (h ^ UInt32(byte)) &* 16777619 }
    let slot = UInt16(h & 0x3FFF)
    return basePort &+ 1 &+ slot
}

func deterministicPort(basePort: UInt16, chainPath: [String]) -> UInt16 {
    deterministicPort(basePort: basePort, directory: chainPath.joined(separator: "/"))
}

@discardableResult
func startMempoolLoop(node: LatticeNode) -> Task<Void, Never> {
    Task {
        // Only run tx_history pruning every N mempool-loop ticks so we're not
        // hitting SQLite with a DELETE every 60s on every chain.
        var tickCount = 0
        let txHistoryPruneEvery = 10 // ~every 10 minutes at the 60s cadence
        // Keep the last ~1 day of foreign-address tx history so RPC lookups for
        // recently-seen addresses still resolve; older rows are dropped because
        // the only *required* history is the node's own (rebuilt at startup).
        let txHistoryRetentionBlocks: UInt64 = 8640 // ~24h at 10s blocks
        while !Task.isCancelled {
            guard await sleepUntilNextTick(.seconds(60)) else { break }
            await node.pruneExpiredTransactions()
            await node.sweepPeerTracking()
            // P-1303: all networks share one DiskBroker — evict once on the shared
            // broker instead of N times per chain (each redundant call runs the full
            // CTE eviction query set against an already-clean database).
            let _ = try? await node.sharedDiskBroker.evictUnpinned()
            tickCount += 1
            if tickCount % txHistoryPruneEvery == 0 {
                await node.pruneTransactionHistory(retentionBlocks: txHistoryRetentionBlocks)
            }
        }
    }
}

/// Checkpoint WAL + run incremental vacuum on every chain's SQLite store.
/// Slow cadence — WAL truncation is cheap but not free, and incremental
/// vacuum is IO-heavy. Once per hour is plenty to keep the WAL from
/// ballooning and the DB file from drifting away from its logical size
/// after tx_history / state_diffs prune passes (UNSTOPPABLE_LATTICE S7).
@discardableResult
func startStorageMaintenanceLoop(node: LatticeNode) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            guard await sleepUntilNextTick(.seconds(3600)) else { break } // 1 hour
            await node.maintainStorage()
        }
    }
}

@discardableResult
func startUnhealthyChainRecoveryLoop(node: LatticeNode, interval: Duration = .seconds(5)) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            guard await sleepUntilNextTick(interval) else { break }
            await node.recoverRecoverableUnhealthyChains()
        }
    }
}

@discardableResult
func startPinReannounceLoop(node: LatticeNode, interval: Duration) -> Task<Void, Never> {
    Task {
        // Short initial delay so the node finishes connecting to peers before
        // flooding them with announcements. 60s is enough for peer discovery
        // to settle while keeping the routing warm-up fast after restart.
        guard await sleepUntilNextTick(.seconds(60)) else { return }
        while !Task.isCancelled {
            for directory in await node.allDirectories() {
                await node.reannouncePinnedVolumes(directory: directory)
                await node.broadcastChainTip(directory: directory)
            }
            await node.demoteLowScoringAnchors()
            guard await sleepUntilNextTick(interval) else { break }
        }
    }
}


// Phase 3: parent chain subscription.
//
// Creates a DEDICATED Ivy instance that connects to the parent chain's P2P
// port and listens for parent-chain block gossip. A ParentChainBlockExtractor
// (with a ChildBlockExtractor implementation) handles each incoming block:
// extracting and applying this chain's embedded block from the parent block.
//
// The parent can be any chain type — today a Lattice chain, eventually Bitcoin.
// The extractor is injected at startup based on --parent-chain-type.
//
// --subscribe-p2p format: <pubkey>@host:port of the IMMEDIATE parent's P2P.
// --relative-chain-path: path from parent's chain to this chain, e.g. "SwapTest"
//   or "Mid/Stable" for a grandchild subscribing directly to the PoW root.
@discardableResult
func startParentChainSubscription(
    node: LatticeNode,
    parentP2PAddress: String,
    overrideDirectory: String? = nil
) -> Task<Void, Never> {
    Task {
        let log = NodeLogger("parent-sub")
        // overrideDirectory lets a per-process node track a chain other than its
        // genesis directory. E.g. a node started with root genesis can track "Mid"
        // by passing --chain-directory Mid, extracting Mid blocks from root gossip.
        let genesisDir = node.genesisConfig.directory
        let directory = overrideDirectory ?? genesisDir

        let parts = parentP2PAddress.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else {
            log.error("Invalid --subscribe-p2p address: \(parentP2PAddress)")
            return
        }
        var pubkey = String(parts[0])
        if pubkey.hasPrefix("ed01") && pubkey.count == 68 { pubkey = String(pubkey.dropFirst(4)) }
        let hostPort = String(parts[1]).split(separator: ":", maxSplits: 1)
        guard hostPort.count == 2, let port = UInt16(hostPort[1]) else { return }
        let parentEndpoint = PeerEndpoint(publicKey: pubkey, host: String(hostPort[0]), port: port)

        // Each node subscribes to its immediate parent and extracts one level.
        // The chain forms naturally from the PoW root to any depth, one hop at a time.
        let extractor = LatticeChildBlockExtractor()
        let configuredFullPath = await node.config.fullChainPath
        let networkChainPath = await node.network(for: directory)?.chainPath
        let localChainPath = networkChainPath
            ?? (configuredFullPath?.last == directory ? configuredFullPath : nil)
        let expectedParentDirectory = localChainPath.flatMap { $0.count >= 2 ? $0[$0.count - 2] : nil }
            ?? (overrideDirectory == nil ? nil : genesisDir)
        let expectedParentChainPath = localChainPath.flatMap { $0.count >= 2 ? Array($0.dropLast()) : nil }
        let receiver = ParentChainBlockExtractor(
            childDirectory: directory,
            parentDirectory: expectedParentDirectory,
            parentChainPath: expectedParentChainPath,
            extractor: extractor,
            node: node,
            tuning: await node.config.tuning.parentExtractor
        )

        // Dedicated Ivy instance for the parent subscription.
        // This Ivy is NOT associated with this chain's gossip network —
        // it only exists to receive parent-chain blocks and pass them to
        // the ParentChainBlockExtractor delegate.
        //
        // the worked subscription key is cached in the data dir so the
        // key grind (≈2^minPeerKeyBits Curve25519 keygens — quick at the
        // 16-bit mainnet default, minutes only if raised) is a one-time per-data-dir cost, not a
        // per-start cost that delays the subscription.
        let minPeerKeyBits = await node.config.minPeerKeyBits
        let key = loadOrGrindParentSubscriptionKey(
            storagePath: await node.config.storagePath,
            minBits: minPeerKeyBits
        )
        let ivyConfig = IvyConfig(
            publicKey: key.publicKey,
            listenPort: 0,
            bootstrapPeers: [parentEndpoint],
            enableLocalDiscovery: false,
            stunServers: [],
            signingKey: key.privateKey,
            baseThresholdMultiplier: UInt64.max,
            maxFrameSize: await node.config.maxFrameSize,
            // The parent endpoint is explicit operator configuration, while the
            // extracted blocks still pass PoW/proof/state validation before use.
            // Keep our outbound subscription identity worked so the parent admits
            // us, but do not require the configured parent node's transport key to
            // also be a miner-grade key.
            minPeerKeyBits: 0
        )
        let parentIvy = Ivy(config: ivyConfig)
        await parentIvy.setDelegate(receiver)
        // register the parent link on the node so it's a node-managed
        // trusted consensus channel — the node can send cw-requests here, and the
        // parent's identity / cw-responses route back through the normal machinery.
        await node.registerParentConsensusLink(directory: directory, ivy: parentIvy)
        // present our spawn-cert chain on the link to the parent, so the
        // parent can verify our spawn-tree membership and serve us the trusted view.
        let ownChain = node.spawnCertChain
        if !ownChain.isEmpty { await parentIvy.setSpawnCertChain(ownChain) }
        try? await parentIvy.start()

        // Register a parent-state fetcher for this child directory so per-process
        // block validation can resolve cross-chain parent-state proofs (e.g. a
        // withdrawal proving a receipt in the parent's `receiptState`) over the
        // parent P2P subscription. Fetched parent-state nodes are cached into the
        // child network's own broker. Keyed by the directory this node validates
        // as, matching the `parentStateFetchers[directory]` lookup in block
        // validation.
        if let childNetwork = await node.network(for: directory) {
            let parentStateFetcher = IvyFetcher(ivy: parentIvy, broker: childNetwork.diskBroker)
            await node.setParentStateFetcher(directory: directory, fetcher: parentStateFetcher)
        }

        // The chain's ChainNetwork is registered at startup from --genesis-hex.
        // Runtime registration without genesis bootstrap was a pre-testnet
        // migration path and is no longer supported.
        if let override = overrideDirectory, await node.network(for: override) == nil {
            log.error("\(override): --subscribe-p2p requires --genesis-hex for this chain")
            return
        }

        log.info("\(directory): subscribed to parent chain at \(parentP2PAddress)")

        // Same-chain peer bootstrap: while the parent link is up, advertise our
        // chain-gossip endpoint to parents (so a follower can find us) and — until
        // we have same-chain peers — ask parents for peers to dial. Adaptive
        // cadence: tight while still peerless (snappy first sync), relaxed once
        // connected (periodic re-advertise). Tied to this subscription's lifetime.
        let bootstrapTask = Task {
            while !Task.isCancelled {
                var needsPeer = false
                if await parentIvy.directPeerCount > 0 {
                    await node.advertiseChainEndpointToParents(directory: directory)
                    // Also push our genesis to the parent so it durably re-serves it on the parent
                    // network — lets later followers resolve the genesis without a local hex.
                    await node.advertiseGenesisToParents(directory: directory)
                    needsPeer = await node.needsSameChainPeer(directory: directory)
                    if needsPeer {
                        await node.discoverAndDialSameChainPeers(directory: directory)
                    }
                }
                // Tight cadence while still hunting a same-chain peer (snappy first
                // sync); relaxed once synced (periodic re-advertise so new followers
                // can still find us).
                do { try await Task.sleep(for: needsPeer ? .seconds(3) : .seconds(30)) }
                catch { return }
            }
        }
        defer { bootstrapTask.cancel() }

        var reconnectBackoff = ReconnectBackoff()
        while true {
            let action = ParentSubscriptionReconnectLoop.nextAction(
                isCancelled: Task.isCancelled,
                directPeerCount: await parentIvy.directPeerCount,
                backoff: &reconnectBackoff
            )
            switch action {
            case .exit:
                return
            case .wait(let delay):
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            case .reconnectAfter(let delay):
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard await parentIvy.directPeerCount == 0 else {
                    reconnectBackoff.reset()
                    continue
                }
                log.info("\(directory): reconnecting to parent \(parentP2PAddress)")
                await ParentSubscriptionReconnectLoop.performReconnect(
                    backoff: &reconnectBackoff,
                    connect: { try await parentIvy.connect(to: parentEndpoint) },
                    onFailure: { error in
                        log.error("\(directory): failed to reconnect to parent \(parentP2PAddress): \(error)")
                    }
                )
            }
        }
    }
}

@discardableResult
func startEvictionLoop(node: LatticeNode, interval: Duration) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            guard await sleepUntilNextTick(interval) else { break }
            for directory in await node.allDirectories() {
                if let network = await node.network(for: directory) {
                    await network.ivy.evict()
                }
            }
        }
    }
}
