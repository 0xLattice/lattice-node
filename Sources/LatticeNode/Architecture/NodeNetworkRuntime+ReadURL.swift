import Foundation
import Ivy
import Lattice
import Tally
import UInt256
import VolumeBroker
import cashew

extension NodeNetworkRuntime {
    /// The public read URLs declared for the chain whose genesis is
    /// `genesisCID`: this node's own declaration plus those of the providers
    /// it discovers via the DHT. Only declared URLs; bounded, cached briefly.
    public func discoverProviderReadURLs(genesisCID: String) async -> [String] {
        guard CIDIdentity.isCanonical(genesisCID) else { return [] }
        if let cached = overlayState.readURLDiscovery.cachedURLs(for: genesisCID, now: Date()) {
            return cached
        }
        // Coalesce concurrent HTTP callers onto one discovery so a request
        // burst cannot multiply overlay asks.
        if let inFlight = overlayState.readURLDiscovery.tasks[genesisCID] {
            return await inFlight.task.value
        }
        let token = makeRequestID()
        let task = Task { [weak self] in
            await self?.performReadURLDiscovery(genesisCID: genesisCID) ?? []
        }
        overlayState.readURLDiscovery.tasks[genesisCID] = (token: token, task: task)
        let urls = await task.value
        // Only the creator un-registers, and only its own entry: a stop/start
        // cycle clears the map, and a fresh discovery registered under the
        // same key must not be evicted by this stale resume.
        if overlayState.readURLDiscovery.tasks[genesisCID]?.token == token {
            overlayState.readURLDiscovery.tasks.removeValue(forKey: genesisCID)
        }
        return urls
    }

    /// Resolve the browsable read URLs for the chain whose genesis is
    /// `genesisCID`. A read URL is only ever a self-DECLARATION — the P2P
    /// plane traffics in IP literals a browser cannot dial, so browsability is
    /// its own declaration, carried from a child's hierarchy hello to its
    /// parent and served here; no URL is ever derived from a provider's
    /// announced host. This node's own declaration leads, read directly: it
    /// must not hinge on Ivy holding a provider record under our own key,
    /// which exists only once this node advertises a P2P address and an
    /// announce has landed. Then DHT-discover the other provider nodes (Ivy
    /// caches, else walks) and ask each one we hold an overlay session with.
    /// Providers that declare nothing, stay silent until the ask times out,
    /// or hold no session contribute nothing. All self-declared and
    /// unverified — the consumer verifies the served genesis against the
    /// parent's on-chain anchor. Deduped, bounded, briefly cached.
    private func performReadURLDiscovery(genesisCID: String) async -> [String] {
        let generation = runtimeGeneration
        var own: [String] = []
        // Same cheap precheck as serving an ask: the state walk runs only
        // when this node has anything to declare.
        if let process,
           configuration.publicReadURL != nil || anyChildDeclaredReadURL {
            own = await declaredReadURLs(
                genesisCID: genesisCID,
                process: process
            )
        }
        let endpoints = await overlay.discoverProviders(rootCID: genesisCID)
        // One candidate per provider identity, not per host: the ask goes to
        // the identity's session, so several providers behind one IP are
        // each asked, and one identity's several routes take one ask slot.
        var seenKeys: Set<PeerKey> = []
        var candidates: [PeerKey] = []
        for endpoint in endpoints {
            guard let key = try? PeerKey(endpoint.publicKey),
                  key.hex != configuration.processPublicKey,
                  seenKeys.insert(key).inserted else { continue }
            candidates.append(key)
            if candidates.count >= 32 { break }
        }
        var urlsByCandidate = [[String]](
            repeating: [],
            count: candidates.count
        )
        // Asks run concurrently: a legacy peer never answers (it drops the
        // unknown topic), so a sequential walk would stall the explorer route
        // for asks-times-deadline against an unupgraded fleet.
        await withTaskGroup(of: (Int, [String]).self) { group in
            var asked = 0
            for (index, key) in candidates.enumerated() {
                guard asked < ReadURLDiscovery.maximumReadEndpointAsks,
                      let peer = overlayState.overlayRecords[key]?.readyPeer else { continue }
                asked += 1
                group.addTask { [weak self] in
                    guard let self else { return (index, []) }
                    return (index, await self.askDeclaredReadURLs(
                        genesisCID: genesisCID,
                        from: peer,
                        generation: generation
                    ))
                }
            }
            for await (index, urls) in group {
                urlsByCandidate[index] = urls
            }
        }
        var seenURLs: Set<String> = []
        var declared: [String] = []
        for urls in [own] + urlsByCandidate {
            // Per-responder cap: a declaration is self-described hint data,
            // so one responder must not be able to flood the merged answer.
            for url in urls.prefix(ReadURLDiscovery.maximumDeclaredURLsPerResponder)
            where seenURLs.insert(url).inserted {
                declared.append(url)
            }
        }
        let bounded = Array(declared.prefix(16))
        guard isCurrentGeneration(generation) else { return bounded }
        overlayState.readURLDiscovery.store(bounded, for: genesisCID, now: Date())
        return bounded
    }

    /// This node's own self-description for `genesisCID`: its configured
    /// public read URL when that is its own chain's genesis, plus the URLs its
    /// wired children declared in their hierarchy hellos when the CID is one
    /// this node anchored for a child directory. Deduped, bounded.
    func declaredReadURLs(
        genesisCID: String,
        process: ChainProcess
    ) async -> [String] {
        var urls: [String] = []
        if let own = configuration.publicReadURL,
           await process.canonicalBlockCID(atHeight: 0) == genesisCID {
            urls.append(own)
        }
        // One sample of the wired children, taken before the resolve suspends
        // and iterated below: the answer then describes a single consistent
        // moment. Reading live hierarchy roles after the suspension instead
        // would mix a child admitted mid-resolve into a lookup that never
        // asked for its directory, and drop it anyway. It is served from the
        // next ask on.
        let wiredChildren = hierarchyRoles.compactMap { key, role -> (PeerKey, String)? in
            guard case .child(let path) = role, let directory = path.last else {
                return nil
            }
            return (key, directory)
        }
        let anchored = await process.anchoredChildGenesisCIDs(
            directories: Set(wiredChildren.map(\.1))
        )
        let directories = Set(
            anchored.filter { $0.value == genesisCID }.map(\.key)
        )
        if !directories.isEmpty {
            // Shuffled, not dictionary order: wired-child roles are
            // permissionless, and a stable iteration order would let a batch
            // of sybil declarants shadow the honest child's URL from every
            // answer for the process lifetime. Random selection keeps every
            // declarant reachable across repeated asks.
            for (key, directory) in wiredChildren.shuffled() {
                guard directories.contains(directory),
                      let url = hierarchyState.hierarchyRecords[key]?.declaredReadURL,
                      !urls.contains(url) else { continue }
                urls.append(url)
                if urls.count >= ReadEndpointResponseMessage.maximumURLs {
                    break
                }
            }
        }
        return Array(urls.prefix(ReadEndpointResponseMessage.maximumURLs))
    }

    /// One bounded ask against an authenticated overlay session. Registered
    /// before the send so the response can never race the pending entry;
    /// resolves empty on send failure, timeout (legacy peers drop the topic
    /// silently), or runtime teardown.
    private func askDeclaredReadURLs(
        genesisCID: String,
        from peer: AuthenticatedPeer,
        generation: UInt64
    ) async -> [String] {
        guard isRunning, isCurrentGeneration(generation) else { return [] }
        let requestID = makeRequestID()
        guard let payload = try? ReadEndpointRequestMessage(
            requestID: requestID,
            genesisCID: genesisCID
        ).encoded() else { return [] }
        // A dedicated short deadline, NOT the overlay's content-pull timeout:
        // a legacy peer never answers, and this wait sits on the public
        // explorer route's critical path.
        let timeout = ReadURLDiscovery.readEndpointAskTimeout
        return await withCheckedContinuation { continuation in
            let timeoutTask = Timers.deadline(
                after: timeout,
                generation: generation
            ) { [weak self] _ in
                await self?.readEndpointAskTimedOut(requestID: requestID)
            }
            overlayState.readURLDiscovery.pendingReadEndpoints[requestID] = ReadURLDiscovery.PendingReadEndpoint(
                peer: peer,
                genesisCID: genesisCID,
                continuation: continuation,
                timeout: timeoutTask
            )
            Task { [weak self] in
                guard let self else { return }
                guard case .enqueued = await self.overlay.sendMessage(
                    to: peer,
                    topic: NodeNetworkTopic.readEndpointRequest,
                    payload: payload
                ) else {
                    await self.readEndpointAskTimedOut(requestID: requestID)
                    return
                }
            }
        }
    }

    private func readEndpointAskTimedOut(requestID: UInt64) {
        guard let pending = overlayState.readURLDiscovery.pendingReadEndpoints.removeValue(
            forKey: requestID
        ) else { return }
        pending.timeout.cancel()
        pending.continuation.resume(returning: [])
    }
}
