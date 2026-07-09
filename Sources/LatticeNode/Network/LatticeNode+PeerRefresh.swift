import Lattice
import Foundation
import Ivy
import Tally

extension LatticeNode {

    func startPeerRefresh() async {
        let nexusDir = genesisConfig.directory
        guard let network = network(for: nexusDir) else { return }

        // Discovery-only nodes maintain more outbound connections to
        // maximize the routing table they can share with joining peers.
        let targetOutbound = config.discoveryOnly
            ? max(config.maxPeerConnections / 4, PeerDiversity.targetOutbound)
            : PeerDiversity.targetOutbound
        let refreshInterval = config.discoveryOnly ? 30 : 60

        // Tally is the shared per-node reputation ledger; one binding reused for
        // replay, all three refresh selection sites, the stale-tip probe, and
        // anchor scoring. The score closure ranks candidates AFTER the key-work +
        // netgroup hard filters applied inside selectDiversePeers.
        let tally = await network.ivy.tally
        let score: @Sendable (PeerEndpoint) -> Double = {
            tally.reputation(for: PeerID(publicKey: $0.publicKey))
        }

        let savedAnchors = await anchorPeers.load()
        for anchor in savedAnchors {
            try? await network.ivy.connect(to: anchor)
        }

        // Module 6: replay persisted router candidates through Ivy's normal
        // admission + liveness path (no separate selection engine). Skip anchors
        // and anything already connected.
        let anchorKeys = Set(savedAnchors.map { $0.publicKey })
        let alreadyConnected = Set(await network.ivy.connectedPeers.map { $0.publicKey })
        let replayCandidates = await peerStore.load().filter {
            !anchorKeys.contains($0.publicKey) && !alreadyConnected.contains($0.publicKey)
        }
        // Apply the same key-work + netgroup + reputation selection used for
        // refresh/probe candidates, so replay never dials unvetted entries even if
        // the persisted `source` provenance later broadens beyond the connected
        // set. Diversity is measured relative to the anchors dialed above.
        let replaySelected = PeerDiversity.selectDiversePeers(
            from: replayCandidates,
            existing: savedAnchors,
            maxNew: targetOutbound,
            minKeyWorkBits: config.minPeerKeyBits,
            score: score
        )
        var replayed = 0
        for candidate in replaySelected {
            try? await network.ivy.connect(to: candidate)
            replayed += 1
        }
        if replayed > 0 {
            metrics.increment("eclipse_candidates_replayed", by: Int64(replayed))
        }

        // Module 4: stale-tip detection state for the nexus chain. We watch local
        // tip height across refresh intervals; if it stalls while no connected
        // peer advertises anything heavier, we may be eclipsed and open a couple
        // of extra outbound probes to diverse, persisted candidates.
        let nexusKey = chainKey(forPath: chainPath(forDirectory: nexusDir))
        let staleThresholdIntervals = 3
        let probeCooldownIntervals = 3
        var lastLocalHeight: UInt64 = 0
        var intervalsSinceAdvance = 0
        var iteration = 0
        var lastProbeInterval = -probeCooldownIntervals
        var staleProbeActive = false

        while !Task.isCancelled {
            guard await sleepUnlessCancelled(.seconds(refreshInterval)) else { break }

            // Discover new peers via DHT random walk
            let discovered = await network.ivy.findNode(target: UUID().uuidString)

            // Separate actually-connected peers from all known peers in the routing table
            let connectedIDs = Set(await network.ivy.connectedPeers.map { $0.publicKey })
            let allKnown = await network.ivy.router.allPeers()
            let connectedEndpoints = allKnown
                .filter { connectedIDs.contains($0.id.publicKey) }
                .map { $0.endpoint }
            let connected = connectedEndpoints.count

            if connected < targetOutbound {
                // Use discovered peers + known-but-not-connected peers as candidates
                let unconnectedKnown = allKnown
                    .filter { !connectedIDs.contains($0.id.publicKey) }
                    .map { $0.endpoint }
                let candidates = discovered + unconnectedKnown
                let diverse = PeerDiversity.selectDiversePeers(
                    from: candidates,
                    existing: [],
                    maxNew: targetOutbound - connected,
                    minKeyWorkBits: config.minPeerKeyBits,
                    score: score
                )
                for peer in diverse {
                    try? await network.ivy.connect(to: peer)
                }

                // If still short, try DNS seeds as fallback
                if connected + diverse.count < targetOutbound {
                    let dnsSeeds = config.isTestnet ? await DNSSeeds.resolveTestnet() : await DNSSeeds.resolve()
                    let dnsCandidates = dnsSeeds.filter { !connectedIDs.contains($0.publicKey) }
                    let dnsSelection = PeerDiversity.selectDiversePeers(
                        from: dnsCandidates,
                        existing: [],
                        maxNew: targetOutbound - connected - diverse.count,
                        minKeyWorkBits: config.minPeerKeyBits,
                        score: score
                    )
                    for peer in dnsSelection {
                        try? await network.ivy.connect(to: peer)
                    }
                }
            }

            if connected >= 2 {
                let bestPeers = Array(connectedEndpoints.prefix(6))
                let scoring: ReputationScoring = { endpoint in
                    tally.reputation(for: PeerID(publicKey: endpoint.publicKey))
                }
                await anchorPeers.update(peers: bestPeers, scoring: scoring)
            }

            // Module 4: stale-tip detection + feeler probes.
            iteration += 1
            let localHeight = await chain(for: nexusDir)?.getHighestBlockHeight() ?? 0
            let peerMaxHeight = knownPeerTips[nexusKey]?.values.map { $0.height }.max() ?? 0
            if localHeight > lastLocalHeight {
                lastLocalHeight = localHeight
                intervalsSinceAdvance = 0
                staleProbeActive = false
            } else {
                intervalsSinceAdvance += 1
            }
            let isStale = Self.tipLooksStale(
                intervalsSinceAdvance: intervalsSinceAdvance,
                staleThreshold: staleThresholdIntervals,
                localHeight: localHeight,
                peerMaxHeight: peerMaxHeight
            )
            metrics.set("eclipse_stale_detected", value: isStale ? 1.0 : 0.0)
            if isStale && iteration - lastProbeInterval >= probeCooldownIntervals {
                // Sample outside the current neighborhood: diverse-netgroup
                // persisted/discovered candidates we are not already connected to.
                let persisted = await peerStore.load()
                let probeCandidates = (persisted + discovered)
                    .filter { !connectedIDs.contains($0.publicKey) }
                let probes = PeerDiversity.selectDiversePeers(
                    from: probeCandidates,
                    existing: [],
                    maxNew: 2,
                    minKeyWorkBits: config.minPeerKeyBits,
                    score: score
                )
                for probe in probes {
                    try? await network.ivy.connect(to: probe)
                }
                if !probes.isEmpty {
                    metrics.increment("eclipse_stale_probes_opened", by: Int64(probes.count))
                    lastProbeInterval = iteration
                    staleProbeActive = true
                }
            }
            // A heavier peer tip surfacing after a probe means the feeler worked.
            if staleProbeActive && peerMaxHeight > localHeight {
                metrics.set("eclipse_better_tip_found", value: 1.0)
                staleProbeActive = false
            }

            // Module 6: keep peers.json fresh at runtime so a crash (not just a
            // clean shutdown) preserves the validated candidate set for replay.
            await peerStore.save(connectedEndpoints, source: "discovered")
        }
    }

    /// Pure stale-tip decision: our tip height has not advanced for at least
    /// `staleThreshold` refresh intervals AND no connected peer advertises a tip
    /// heavier than ours (if one did, that is a sync gap, not an eclipse).
    static func tipLooksStale(
        intervalsSinceAdvance: Int,
        staleThreshold: Int,
        localHeight: UInt64,
        peerMaxHeight: UInt64
    ) -> Bool {
        intervalsSinceAdvance >= staleThreshold && peerMaxHeight <= localHeight
    }
}
