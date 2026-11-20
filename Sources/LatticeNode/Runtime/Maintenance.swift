import Foundation
import Ivy
import LatticeNodeCore

extension NodeRuntime {
    /// Maintenance: the passes that keep each hosted chain's peers up,
    /// renew what this node announces as a provider, and count each chain's
    /// current peers. A pass is planned on the loop and runs off it, posting
    /// what it found back as inputs. Only the loop touches it.
    struct Maintenance: Sendable {
        let ivy: Ivy
        let inputs: Inputs
        /// What the open sessions' hellos advertised.
        let capabilities: PeerCapabilities
        let peerMemory: PeerMemory?
        /// The Volumes the operator pinned, as last read: announced with the
        /// chains by each maintenance pass.
        var operatorPins: [String] = []
        /// What maintenance passes announced, with the expiry they sent.
        var announcedRoots: [String: UInt64] = [:]
        var peerSearch = PeerSearch()
        var maintenanceInFlight = false
        /// When a lost session last brought maintenance forward.
        var lastUrgentMaintenanceAt: Int64 = .min / 2
        /// Each hosted chain's current peers as the last maintenance pass
        /// counted them: for a child, what its rendezvous adds to the
        /// sessions whose hello named it.
        var currentPeers: [ChainPath: Set<String>] = [:]
        /// A maintenance pass asked for while one was running: run it next.
        var maintenancePending = false

        init(ivy: Ivy, inputs: Inputs, capabilities: PeerCapabilities, peerMemory: PeerMemory?) {
            self.ivy = ivy
            self.inputs = inputs
            self.capabilities = capabilities
            self.peerMemory = peerMemory
        }

        /// The pins to announce, read on the loop.
        mutating func readPins(from storage: NodeStorage, configuration: NodeConfiguration) async {
            // Read here, on the loop: the pass runs off it and must not
            // hold the store open past a stop. Pins not announced are
            // not read.
            operatorPins = configuration.announcePins ? await storage.operatorPins() : []
        }

        /// The current peers a pass counted.
        mutating func counted(_ current: [ChainPath: Set<String>]) {
            currentPeers = current
        }

        /// The network I/O of a pass ended: true when another was asked for
        /// meanwhile, to run now.
        mutating func finished() -> Bool {
            maintenanceInFlight = false
            guard maintenancePending else { return false }
            maintenancePending = false
            return true
        }

        /// Every session is gone.
        mutating func sessionsClosed() {
            // With every session gone, what was announced may have
            // reached no one who still holds it: the pass the next
            // session starts announces it again.
            announcedRoots = announcedRoots.mapValues { _ in 0 }
        }

        /// A session closed, leaving `peers` sessions.
        mutating func sessionLost(peers: Int, configuration: NodeConfiguration) {
            // Nothing redials a seed or a remembered peer but a
            // maintenance pass. Left with too few peers, the node looks
            // again now, not at the next interval: at most once per
            // `SeedPolicy.retryInterval`, so a peer that keeps dropping
            // cannot make it spin.
            let now = NodeRuntime.now()
            if !configuration.seedPeers.isEmpty,
               SeedPolicy.needsSeeds(peers: peers, below: configuration.peersBeforeSeeds),
               now - lastUrgentMaintenanceAt >= SeedPolicy.retryInterval {
                lastUrgentMaintenanceAt = now
                inputs.yield(.maintenance)
            }
        }

        /// A level no longer hosted.
        mutating func drop(_ path: ChainPath) {
            currentPeers[path] = nil
        }

        /// Snapshot the discovery plan on the serial loop, then perform its
        /// potentially slow dials outside it. A dead bootstrap endpoint must
        /// never pause consensus, RPC writes, or persistence while connect
        /// timeouts expire. `sessionReady`: a session is ready.
        mutating func start(_ core: NodeCore, sessionReady: Bool, configuration: NodeConfiguration) {
            let now = NodeRuntime.now()
            guard !maintenanceInFlight else {
                maintenancePending = true
                return
            }
            maintenanceInFlight = true

            let expiry = configuration.announcementExpiry(at: now)
            let nexus = configuration.nexusGenesisCID
            // Conversion from an operator-supplied Double must not trap even
            // for a finite but unreasonably large value.
            let maximumSeconds = Double(Int64.max / 1_000)
            let interval = Int64(min(configuration.peerSearchInterval, maximumSeconds) * 1_000)
            let due = peerSearch.due(
                heights: core.ordered.compactMap { path in
                    core.levels[path].map { (path, $0.snapshot.actOnHeight) }
                },
                now: now, interval: interval,
                connected: sessionReady
            )
            // Only a child short of the target as the last pass counted it
            // spends its turn: one that drops short just after is not kept
            // waiting an interval by a turn it did not need.
            let topUps = peerSearch.topUps(
                paths: core.ordered.filter {
                    $0 != core.rootPath && (currentPeers[$0]?.count ?? 0) < configuration.peerTarget
                },
                now: now, interval: interval, connected: sessionReady
            )
            // Every hosted chain, Nexus down, with what its routine needs.
            // The levels differ only in where discovery asks: a child has a
            // rendezvous among its parent's peers and the seeds its operator
            // gave it; Nexus, with no parent, has its seeds alone, by name
            // and then at fixed addresses.
            let root = core.rootPath
            let chains = core.ordered.map { path in
                (
                    path: path,
                    // The chain and its ancestors: a peer that hosts a chain
                    // hosts every one of them.
                    lineage: (root.count...path.count).map { Array(path.prefix($0)) },
                    hosts: ChainHosts.of(path, nexusGenesisCID: nexus),
                    stalled: due.contains(path),
                    topUp: topUps.contains(path),
                    seeds: path == root
                        ? [configuration.seedPeers, configuration.fixedSeedPeers]
                        : [configuration.childSeedPeers[path] ?? []]
                )
            }
            // A declared read URL is findable from the parent of each hosted
            // child level: announced under the level's read-endpoint key.
            let announced = chains.compactMap(\.hosts?.key) + (configuration.publicReadURL == nil ? [] : core.ordered
                .filter { $0 != core.rootPath }
                .map { ReadEndpointKey.key(nexusGenesisCID: configuration.nexusGenesisCID, chainPath: $0) })
            let (ivy, inputs, bootstrap, ownKey, capabilities) = (
                ivy, inputs, configuration.bootstrapPeers, configuration.processPublicKey, self.capabilities
            )
            let (peerMemory, target, beforeSeeds) = (
                peerMemory, configuration.peerTarget, configuration.peersBeforeSeeds
            )
            let retriesSeeds = !configuration.seedPeers.isEmpty
            // What the operator pinned is announced with the chains; a key
            // no longer wanted stops being provided.
            let (announcing, withdrawn) = configuration.announcementRenewal(
                wanted: Set(announced + operatorPins), announced: announcedRoots, at: now
            )
            for key in withdrawn { announcedRoots.removeValue(forKey: key) }
            // With no session open, the walk has no one to tell: the pass
            // the first session starts announces again.
            if sessionReady {
                for key in announcing { announcedRoots[key] = expiry }
            }
            NodeRuntime.spawn {
                for key in withdrawn {
                    await ivy.stopProviding(rootCID: key)
                }
                for key in announcing {
                    await ivy.announceProvider(rootCID: key, expiresAt: expiry)
                }
                var connected = Set((await ivy.connectedPeers).map(\.publicKey))
                // An address is dialled at most once in a pass, whichever
                // chains want it and however the dial ends. True when this dial
                // reached it, false when it failed, nil when none was made:
                // a session that is already open was not reached at this
                // address, which is then not one to remember.
                var attempted: Set<PeerEndpoint> = []
                func dial(_ endpoint: PeerEndpoint) async -> Bool? {
                    guard attempted.insert(endpoint).inserted else { return nil }
                    guard !(await ivy.connectedPeers).contains(where: { $0.publicKey == endpoint.publicKey }) else {
                        connected.insert(endpoint.publicKey)
                        return nil
                    }
                    do {
                        try await ivy.connect(to: endpoint)
                        connected.insert(endpoint.publicKey)
                        // A peer that could not be dialled may have been
                        // reached through another: connected, but not at
                        // this address.
                        guard let peer = await ivy.connectedPeers.first(where: {
                            $0.publicKey == endpoint.publicKey
                        }) else { return true }
                        return await ivy.session(with: peer)?.route == .direct
                    } catch {
                        return false
                    }
                }
                // One routine, run for each hosted chain: keep the chain's
                // own current peers up from the peers it remembers, then
                // from discovery. Every dial is a random draw, so whoever
                // orders a book or a lookup's answer does not pick them.
                for chain in chains {
                    var current = chain.hosts == nil ? connected
                        : Set(await capabilities.sessions(hosting: chain.hosts, ivy: ivy).map(\.id.publicKey))
                    // The operator's configured peers are Nexus's: redialled
                    // when it stalls.
                    for endpoint in bootstrap
                    where chain.hosts == nil && chain.stalled && !connected.contains(endpoint.publicKey) {
                        if await dial(endpoint) == true { current.insert(endpoint.publicKey) }
                    }
                    // The chain's network as this node last knew it. Short
                    // of peers (always, just after a start) or stalled, it
                    // dials some it remembers, so it rejoins without leaning
                    // on its seeds or a lookup, or when neither answers. A
                    // peer reached is a Nexus peer; whether it still hosts
                    // this chain is for its session to say.
                    if let peerMemory, current.count < target || chain.stalled {
                        let remembered = await peerMemory.candidates(
                            for: chain.path, excluding: connected, count: NodeRuntime.rememberedPeerDials
                        )
                        for endpoint in remembered {
                            switch await dial(endpoint) {
                            case true?:
                                current.insert(endpoint.publicKey)
                                await peerMemory.reached(endpoint, chains: [root], now: now)
                            case false?: await peerMemory.failed(endpoint.publicKey)
                            case nil: break
                            }
                        }
                    }
                    // A child's rendezvous names the peers that can sync it.
                    // It is searched while the chain has no current peer,
                    // when it stalled, and while it is short of the target
                    // once an interval: a chain whose whole network is a few
                    // nodes does not search on every pass.
                    if let hosts = chain.hosts,
                       current.isEmpty || chain.stalled || (chain.topUp && current.count < target) {
                        let fresh = (await ivy.discoverProviders(rootCID: hosts.key))
                            .filter { $0.publicKey != ownKey && !connected.contains($0.publicKey) && !attempted.contains($0) }
                        for endpoint in fresh.shuffled().prefix(4) where await dial(endpoint) == true {
                            current.insert(endpoint.publicKey)
                            await peerMemory?.reached(endpoint, chains: chain.lineage, now: now)
                        }
                    }
                    // Seeds last, and only on need: with too few peers still,
                    // after the remembered ones had their turn. A fresh node
                    // has nothing to remember and comes straight here. Each
                    // layer is asked only if the one before left the chain
                    // short.
                    for layer in chain.seeds where SeedPolicy.needsSeeds(peers: current.count, below: beforeSeeds) {
                        for endpoint in layer.shuffled()
                        where !connected.contains(endpoint.publicKey) {
                            guard await dial(endpoint) == true else { continue }
                            current.insert(endpoint.publicKey)
                            await peerMemory?.reached(endpoint, chains: chain.lineage, now: now)
                        }
                    }
                }
                // Each chain's current peers now: every open session for
                // Nexus, the sessions that say they host it for a child.
                var open: [ChainPath: Set<String>] = [:]
                for chain in chains {
                    open[chain.path] = chain.hosts == nil
                        ? Set((await ivy.connectedPeers).map(\.publicKey))
                        : Set(await capabilities.sessions(hosting: chain.hosts, ivy: ivy).map(\.id.publicKey))
                }
                await peerMemory?.stillOpen(byChain: open, now: now)
                inputs.yield(.currentPeers(open))
                // Nexus still short of peers (a seed that was down, no
                // network yet): nothing else will look again before the next
                // interval, so this pass asks for another soon. The overlay
                // no longer redials the seeds itself.
                if retriesSeeds, SeedPolicy.needsSeeds(peers: open[root]?.count ?? 0, below: beforeSeeds) {
                    inputs.yield(.maintenanceFinished)
                    guard await Timers.sleep(nanoseconds: UInt64(SeedPolicy.retryInterval) * 1_000_000) else { return }
                    inputs.yield(.maintenance)
                    return
                }
                inputs.yield(.maintenanceFinished)
            }
        }
    }
}
