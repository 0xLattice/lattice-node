import Foundation
import Ivy
import Tally
import cashew        // ContentAddressVerifier — verify advertised genesis entries hash to their CIDs

/// Same-chain peer bootstrap (node side). See `ChildPeerProvider` for the why:
/// the parent chain is the rendezvous, a child advertises its chain-gossip
/// endpoint over the parent link, and a follower asks the parent for the
/// endpoints of its connected same-chain children. The serve side reads the
/// LIVE spawn-trusted subscriber set (no registry); the client side is driven by
/// the parent-subscription loop.
extension LatticeNode {
    // MARK: - Serve (a parent answers a followed child)

    nonisolated public func chainNetwork(_ network: ChainNetwork, handleChildPeerAdvertise payload: Data, from peer: PeerID) async {
        guard let adv = ChildPeerProvider.decodeAdvertise(payload) else { return }
        await recordAdvertisedChildEndpoint(peer: peer, directory: adv.directory, endpoint: adv.endpoint, rpcUrl: adv.rpcUrl)
    }

    /// A connected child advertised its genesis content over the parent link. UNTRUSTED input, so
    /// verify before serving: (a) every entry's bytes must hash to its CID, and (b) the genesis
    /// block CID (the first entry) must equal the parent's ANNOUNCED child genesis for this path —
    /// a peer cannot inject a fake or unrelated genesis. On success, durably store + pin + announce
    /// the genesis on the PARENT network, so later followers resolving it via the parent network
    /// succeed without a local hex even after the original deployer has left.
    nonisolated public func chainNetwork(_ network: ChainNetwork, handleChildGenesisAdvertise payload: Data, from peer: PeerID) async {
        guard let (directory, entries) = ChildPeerProvider.decodeGenesis(payload),
              let genesisEntry = entries.first else { return }
        // (a) content-address every entry — fail closed on any mismatch (cheap, before any store).
        for (cid, data) in entries where !ContentAddressVerifier.data(data, matches: cid) { return }
        // (b) the advertised genesis block must be exactly the one the parent anchored (a peer
        //     cannot serve a fake/unrelated genesis; `announced == nil` also fails closed).
        let childPath = network.chainPath + [directory]
        guard let announced = await announcedChildGenesisCID(chainPath: childPath),
              genesisEntry.cid == announced else { return }
        // (P2) Idempotent cost-gate: if we already hold this genesis, do nothing — the periodic
        // re-advertise must not re-store/re-rebuild on every tick.
        if await network.hasCID(announced) { return }
        // (P1) Do NOT pin the advertised entries directly — a peer could append valid-CID junk
        // blobs that pass (a) but aren't part of the genesis, and pinning is durable+permanent.
        // Instead store them UNPINNED so the resolver can read them locally, then reuse
        // resolveFollowedGenesis: it rebuilds the closure from the genesis block, verifies it
        // reproduces the anchored CID, and durably pins + announces ONLY the real closure. Any
        // junk entry stays unpinned and is GC-reclaimable; an incomplete closure pins nothing.
        await network.storeBatch(entries.map { ($0.cid, $0.data) })
        _ = await resolveFollowedGenesis(DeployedChainMetadata(
            chainPath: childPath, directory: directory, parentDirectory: network.directory,
            genesisHash: announced, genesisHex: "", timestamp: 0))
    }

    // MARK: - Client (a serving child pushes its genesis to its parent)

    /// Push this child's own genesis entries to its parent(s) over the `directory` subscription
    /// link, so the parent durably re-serves the genesis on the parent network. No-op on a root
    /// node (no retained entries / no parent link). Bounded payload; the parent re-verifies.
    func advertiseGenesisToParents(directory: String) async {
        guard !childGenesisBootstrapEntries.isEmpty,
              let ivy = parentConsensusLinks[directory]?.ivy else { return }
        let payload = ChildPeerProvider.encodeGenesis(directory: directory, entries: childGenesisBootstrapEntries)
        guard payload.count <= ChildPeerProvider.maxGenesisTotalBytes else { return }
        await ivy.broadcastMessage(topic: ChildPeerProvider.genesisTopic, payload: payload)
    }

    func recordAdvertisedChildEndpoint(peer: PeerID, directory: String, endpoint: String, rpcUrl: String? = nil) {
        advertisedChildEndpoints[peer] = (directory, endpoint, rpcUrl)
    }

    /// Public HTTP RPC endpoints that directly-connected `directory` children have
    /// advertised over `network` (self-declared; a browser MUST verify the served genesis
    /// against the parent's anchor before trusting one). Deduped by URL, bounded.
    func advertisedChildRPCEndpoints(network: ChainNetwork, directory: String) async -> [(rpcUrl: String, pubkey: String)] {
        let connected = await network.ivy.connectedPeers
        var out: [(rpcUrl: String, pubkey: String)] = []
        var seen = Set<String>()
        for p in connected {
            guard let adv = advertisedChildEndpoints[p], adv.directory == directory,
                  let rpc = adv.rpcUrl, !rpc.isEmpty, seen.insert(rpc).inserted else { continue }
            out.append((rpcUrl: rpc, pubkey: p.publicKey))
            if out.count >= ChildPeerProvider.maxEndpoints { break }
        }
        return out
    }

    nonisolated public func chainNetwork(_ network: ChainNetwork, handleChildPeerRequest payload: Data, from peer: PeerID) async -> Data? {
        guard let req = ChildPeerProvider.decodeRequest(payload) else { return nil }
        var endpoints = await collectChildPeerEndpoints(network: network, directory: req.directory, asker: peer)
        // Transitive forward (one hop): if we serve no DIRECT same-chain child for this
        // directory but were asked with ttl>0, ask OUR OWN same-chain peers — one of them
        // may be the source's parent, which DOES have it advertised. ttl=0 on the forward →
        // no re-forward (single hop, no loops); fan-out is capped; forwarded sub-requests
        // use a short timeout so the handler never holds a gossip-task slot long (H1).
        // GATE (H2): only forward for a directory that is genuinely OUR OWN managed child —
        // so an attacker cannot make us reflect an 8-way fan-out at our peers for arbitrary
        // (garbage) directory strings. A legitimate follower only ever asks its parent for
        // its parent's child chains, so this never blocks real discovery.
        if endpoints.isEmpty, req.ttl > 0, await isManagedChildDirectory(req.directory) {
            endpoints = await forwardChildPeerQuery(network: network, directory: req.directory, asker: peer)
        }
        return ChildPeerProvider.encodeResponse(requestId: req.requestId, endpoints: endpoints)
    }

    /// One-hop forward of an UNANSWERED getChildPeers query to our own same-chain peers
    /// (peers on `network`, excluding the asker), bounded by `maxForwardFanout` and sent
    /// with ttl=0 so they never re-forward. Parallel, so the responder stays fast (it
    /// returns as soon as the source's parent answers from its direct subscriber set).
    /// Is `directory` one of THIS node's own managed (non-detached) children? Cheap
    /// in-memory check used to gate the transitive forward, so we only ever reflect a
    /// fan-out for chains we genuinely parent — never for an attacker-supplied directory.
    func isManagedChildDirectory(_ directory: String) -> Bool {
        let ownChainPath = config.fullChainPath ?? [genesisConfig.directory]
        let key = chainKey(forPath: ownChainPath + [directory])
        return (deployedChildChains[key].map { !$0.detached }) ?? false
    }

    func forwardChildPeerQuery(network: ChainNetwork, directory: String, asker: PeerID) async -> [String] {
        guard let provider = childPeerProvider else { return [] }
        let targets = await network.ivy.connectedPeers.filter { $0 != asker }.prefix(ChildPeerProvider.maxForwardFanout)
        guard !targets.isEmpty else { return [] }
        var aggregated: [String] = []
        await withTaskGroup(of: [String].self) { group in
            for p in targets {
                group.addTask { await provider.requestChildPeers(from: p, directory: directory, ttl: 0, timeout: ChildPeerProvider.forwardTimeout) }
            }
            for await eps in group {
                aggregated.append(contentsOf: eps)
                // Return as soon as a peer answers, so the responder stays well within the
                // original asker's request timeout (the source's parent answers fast from
                // its direct subscriber set). Stragglers time out harmlessly.
                if !aggregated.isEmpty { group.cancelAll(); break }
            }
        }
        var seen = Set<String>()
        return Array(aggregated.filter { seen.insert($0).inserted }.prefix(ChildPeerProvider.maxEndpoints))
    }

    /// Endpoints of THIS chain's connected `directory` children — the live
    /// subscribers on `network` that advertised that directory. The directory is
    /// self-declared (verified on dial); the asker is excluded so a follower never
    /// dials itself. Reads the live connection set, so eviction is by disconnect.
    func collectChildPeerEndpoints(network: ChainNetwork, directory: String, asker: PeerID) async -> [String] {
        let connected = await network.ivy.connectedPeers
        var result: [String] = []
        for p in connected where p != asker {
            if let adv = advertisedChildEndpoints[p], adv.directory == directory {
                result.append(adv.endpoint)
            }
        }
        return result
    }

    nonisolated public func chainNetwork(_ network: ChainNetwork, handleChildPeerResponse payload: Data, from peer: PeerID) async {
        await childPeerProvider?.handleResponse(payload, from: peer)
    }

    /// Route a getChildPeers response that arrived on the parent-subscription link
    /// into the client correlation (responder-bound).
    func deliverChildPeerResponse(_ payload: Data, from peer: PeerID) async {
        await childPeerProvider?.handleResponse(payload, from: peer)
    }

    // MARK: - Client (a followed child finds same-chain peers via its parents)

    /// This node's own chain-gossip endpoint to advertise to parents: the operator
    /// public address when set (cloud/NAT), else loopback for local/test — the same
    /// self-advertisement source the rest of the node uses.
    var ownChainGossipEndpoint: String {
        let host = config.externalAddress?.host ?? "127.0.0.1"
        let port = config.externalAddress?.port ?? config.listenPort
        return "\(config.p2pPublicKey)@\(host):\(port)"
    }

    /// Advertise our chain endpoint to every parent on the `directory` subscription
    /// link, so a parent can serve us to a same-chain follower.
    func advertiseChainEndpointToParents(directory: String) async {
        guard let ivy = parentConsensusLinks[directory]?.ivy else { return }
        let payload = ChildPeerProvider.encodeAdvertise(directory: directory, endpoint: ownChainGossipEndpoint, rpcUrl: config.rpcPublicUrl)
        await ivy.broadcastMessage(topic: ChildPeerProvider.advertiseTopic, payload: payload)
    }

    /// Direct peer count on the `directory` chain-gossip network, EXCLUDING known
    /// relay peers. A `--use-relay` circuit-relay peer is connected directly (it
    /// lives in Ivy's `connections`, so `directPeerCount` counts it) but is a
    /// cross-chain bootstrap node that never serves this child chain. Counting it
    /// would make `needsSameChainPeer` return false once a NAT'd node is past
    /// genesis, masking the getChildPeers rendezvous discovery — the node would
    /// then never find real same-chain peers without an explicit `--peer`.
    func chainGossipPeerCount(directory: String) async -> Int {
        guard let network = network(for: directory) else { return 0 }
        // Both branches derive from the SAME source (`connectedPeers` = connections +
        // any mDNS local peers) so the count is consistent whether or not relays are
        // configured; the relay branch just additionally drops known-relay keys.
        let connectedKeys = await network.ivy.connectedPeers.map { $0.publicKey }
        guard !config.knownRelays.isEmpty else { return connectedKeys.count }
        return Self.nonRelayPeerCount(connectedPeerKeys: connectedKeys,
                                      knownRelayKeys: config.knownRelays.map { $0.publicKey })
    }

    /// Count of connected peers excluding known relays. Pure so it is unit-testable
    /// independent of a live Ivy: Ivy stores connected keys stripped of the `ed01`
    /// multicodec prefix while config/`--use-relay` keys keep it, so both sides are
    /// normalized before comparison.
    static func nonRelayPeerCount(connectedPeerKeys: [String], knownRelayKeys: [String]) -> Int {
        let relays = Set(knownRelayKeys.map { normalizedPeerKey($0) })
        return connectedPeerKeys.filter { !relays.contains(normalizedPeerKey($0)) }.count
    }

    /// Strip the `ed01` multicodec prefix from an ed25519 peer key and lowercase it
    /// so keys from different sources (Ivy connections vs config) compare equal. Ivy
    /// and Tally canonicalize connection keys with `.lowercased()` (see Tally's
    /// `canonicalRawHex` / Ivy's `SpawnCertificate`), so a `--use-relay` key entered
    /// in a different hex case must fold to the same form here to be excluded.
    static func normalizedPeerKey(_ key: String) -> String {
        let lowered = key.lowercased()
        return (lowered.hasPrefix("ed01") && lowered.count == 68) ? String(lowered.dropFirst(4)) : lowered
    }

    /// Whether a followed child still needs a same-chain peer: it has no peer on
    /// its chain-gossip network, or it has not synced any block past genesis yet.
    /// (A peer count alone is insufficient — a cross-chain bootstrap peer can be
    /// connected without ever serving this chain.)
    func needsSameChainPeer(directory: String) async -> Bool {
        if await chainGossipPeerCount(directory: directory) == 0 { return true }
        let height = await chain(for: directory)?.getHighestBlockHeight() ?? 0
        return height == 0
    }

    /// Ask every connected parent for this chain's same-chain peers and dial any
    /// returned endpoints on the chain-gossip network. Verify-not-trust: the dial
    /// authenticates the identity and consensus validates the chain, so a bogus
    /// endpoint costs only a wasted dial. Our own endpoint is skipped.
    func discoverAndDialSameChainPeers(directory: String) async {
        guard let ivy = parentConsensusLinks[directory]?.ivy,
              let provider = childPeerProvider,
              let network = network(for: directory) else { return }
        let ownPubkey = config.p2pPublicKey
        let connected = Set(await network.ivy.connectedPeers.map { $0.publicKey })
        let log = NodeLogger("childpeers")
        for parent in await ivy.connectedPeers {
            let endpoints = await provider.requestChildPeers(from: parent, directory: directory)
            for ep in endpoints {
                guard let endpoint = Self.parseChainEndpoint(ep),
                      endpoint.publicKey != ownPubkey,
                      !connected.contains(endpoint.publicKey) else { continue }
                log.info("\(directory): dialing same-chain peer \(String(ep.prefix(24)))… (found via getChildPeers)")
                try? await network.ivy.connect(to: endpoint)
            }
        }
    }

    /// Parse a `pubkey@host:port` chain endpoint (raw or ed01-prefixed key).
    static func parseChainEndpoint(_ s: String) -> PeerEndpoint? {
        let parts = s.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        var pubkey = String(parts[0])
        if pubkey.hasPrefix("ed01") && pubkey.count == 68 { pubkey = String(pubkey.dropFirst(4)) }
        let hostPort = String(parts[1]).split(separator: ":", maxSplits: 1)
        guard hostPort.count == 2, let port = UInt16(hostPort[1]), !pubkey.isEmpty else { return nil }
        return PeerEndpoint(publicKey: pubkey, host: String(hostPort[0]), port: port)
    }
}
