import ArgumentParser
import Foundation
import Hummingbird
import LatticeCtlCore
import LatticeNode

extension HostLevelRequest: ResponseEncodable {}

/// Each level's listeners and maintenance, from its current `lattice.json`
/// entry.
struct DaemonLevelServices: ChainHostServices {
    let command: LatticeNodeCommand
    let configURL: URL
    let layout: HostLayout
    let processStartTime: Date
    let failures: AsyncStream<String?>.Continuation

    func serve(_ node: Node, on host: ChainHost) -> Task<Void, Never> {
        command.serveLevel(
            node: node,
            chain: (try? command.loadTopology(configURL))?
                .chains[node.process.configuration.address.key],
            host: host,
            configURL: configURL,
            layout: layout,
            processStartTime: processStartTime,
            failures: failures
        )
    }
}

extension LatticeNodeCommand {
    /// One process hosting every chain of a `lattice.json` tree. Each level
    /// keeps its own ports, identity and storage, exactly as the process that
    /// used to run it; only the process boundary is gone.
    func runHost(configPath: String) async throws {
        let processStartTime = Date()
        guard parent == nil, dataDirectory == nil, identityKey == nil,
              peer.isEmpty, publicReadPort == nil, publicReadUrl == nil,
              externalAddress == nil else {
            throw ValidationError("--config takes every per-chain setting from the file; --parent, --data-directory, --identity-key, --peer, --public-read-port, --public-read-url and --external-address apply only without it")
        }
        guard ["127.0.0.1", "::1", "localhost"].contains(rpcBind.lowercased()) else {
            throw ValidationError("the unauthenticated HTTP API may bind only to loopback")
        }
        let configURL = URL(fileURLWithPath: configPath)
        let layout = HostLayout(
            root: dataRoot ?? configURL.deletingLastPathComponent().path
        )
        let topology = try loadTopology(configURL)
        // A listener failure's reason, or nil for a stop signal.
        let (events, failures) = AsyncStream<String?>.makeStream()
        var chains: [ChainAddress: ChainHost.Configure] = [:]
        for (path, chain) in topology.chains {
            let level = try hostedLevel(path: path, chain: chain, layout: layout)
            chains[level.address] = level.configure
        }
        let host = try ChainHost(chains: chains, services: DaemonLevelServices(
            command: self, configURL: configURL, layout: layout,
            processStartTime: processStartTime, failures: failures
        ))

        // Stop on a signal by stopping the levels, children first, rather
        // than letting each listener take the signal on its own.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signalSources = [SIGTERM, SIGINT].map { number in
            let source = DispatchSource.makeSignalSource(
                signal: number, queue: .global()
            )
            source.setEventHandler { failures.yield(nil) }
            source.resume()
            return source
        }
        defer { signalSources.forEach { $0.cancel() } }

        do {
            try await host.startAll()
        } catch {
            await host.stopAll()
            throw error
        }
        var failure: String?
        for await event in events {
            failure = event
            break
        }
        await host.stopAll()
        if let failure {
            throw CtlError(failure)
        }
    }

    func loadTopology(_ url: URL) throws -> Topology {
        try JSONDecoder().decode(Topology.self, from: Data(contentsOf: url))
            .validated()
    }

    /// One level's node configuration from its `lattice.json` entry. The
    /// parent endpoint is the host's to wire.
    func hostedLevel(
        path: String, chain: TopologyChain, layout: HostLayout
    ) throws -> (address: ChainAddress, configure: ChainHost.Configure) {
        guard let address = ChainAddress(string: path) else {
            throw ValidationError("\(path) must be absolute and begin with Nexus")
        }
        let storage = layout.chainDirectory(for: path)
        try FileManager.default.createDirectory(
            at: storage, withIntermediateDirectories: true
        )
        let privateKeyHex = try loadOrCreateIdentity(
            at: layout.identityKey(for: path)
        )
        // Absent = no peer source configured, so the built-in defaults. A
        // list REPLACES them, and an explicit empty list means none.
        let configuredPeers = try chain.peers.map { try $0.map(parsePeerEndpoint) }
        let bootstrapPeers = DefaultBootstrapPeers.resolved(
            chainPath: address.components, configured: configuredPeers
        )
        let minimumPeerKeyBits = minimumPeerKeyBits
        let overlayMaxConnectionsPerNetgroup = overlayMaxConnectionsPerNetgroup
        let peerSearchInterval = peerSearchInterval
        return (address, { parentEndpoint in
            try NodeConfiguration(
                chainPath: address.components,
                storagePath: storage,
                privateKeyHex: privateKeyHex,
                listenPort: chain.listen,
                factListenPort: chain.fact,
                rpcPort: chain.rpc,
                bootstrapPeers: bootstrapPeers,
                parentEndpoint: parentEndpoint,
                minPeerKeyBits: minimumPeerKeyBits,
                overlayMaxConnectionsPerNetgroup: overlayMaxConnectionsPerNetgroup,
                externalAddress: chain.externalAddress,
                publicReadURL: chain.publicReadUrl,
                peerSearchInterval: peerSearchInterval
            )
        })
    }

    /// A level's loopback RPC listener, its optional public read listener and
    /// its volume maintenance, for as long as the level runs. A listener that
    /// fails while its level runs stops the whole host, as it stopped the
    /// process that ran the level. The root level also serves the host
    /// control routes.
    func serveLevel(
        node: Node,
        chain: TopologyChain?,
        host: ChainHost,
        configURL: URL,
        layout: HostLayout,
        processStartTime: Date,
        failures: AsyncStream<String?>.Continuation
    ) -> Task<Void, Never> {
        let configuration = node.process.configuration
        let address = configuration.address
        let network = node.network
        let service = node.service
        let process = node.process
        let peersProvider: @Sendable () async -> ExplorerPeersResponse = { [weak network] in
            guard let network else {
                return ExplorerPeersResponse(count: 0, peers: [])
            }
            return await network.peerSummaries(limit: 200)
        }
        let providerDiscovery: @Sendable (String) async -> [String] = { [weak network] genesisCID in
            guard let network else { return [] }
            return await network.discoverProviderReadURLs(
                genesisCID: genesisCID
            )
        }
        var applications: [any ApplicationProtocol] = [makeApplication(
            service: service,
            host: rpcBind,
            port: Int(configuration.rpcPort),
            peers: peersProvider,
            discoverProviders: providerDiscovery,
            processStartTime: processStartTime,
            extraRoutes: address.isNexus ? { router in
                addHostControlRoutes(
                    to: router, host: host, attach: { path in
                        let topology = try self.loadTopology(configURL)
                        guard let chain = topology.chains[path] else {
                            throw HTTPError(.notFound, message: "\(path) is not in \(configURL.path)")
                        }
                        return try self.hostedLevel(
                            path: path, chain: chain, layout: layout
                        )
                    }
                )
            } : { _ in }
        )]
        print("lattice-node \(address.key)")
        print("  process: \(configuration.processPublicKey)")
        print("  rpc:     http://\(rpcBind):\(configuration.rpcPort)")
        if let publicReadPort = chain?.publicRead {
            do {
                let limits = try PublicReadRateLimits.validated(
                    generalRate: chain?.publicReadRate
                        ?? PublicReadRateLimits.defaultGeneralRate,
                    expensiveRate: chain?.publicReadExpensiveRate
                        ?? PublicReadRateLimits.defaultExpensiveRate,
                    listenerRate: chain?.publicReadMaxRate
                        ?? PublicReadRateLimits.defaultListenerRate
                )
                applications.append(makePublicReadApplication(
                    service: service,
                    host: "0.0.0.0",
                    port: Int(publicReadPort),
                    peers: peersProvider,
                    discoverProviders: providerDiscovery,
                    limits: limits
                ))
                print("  public-read: http://0.0.0.0:\(publicReadPort)")
                print("  public-read rate limits: \(limits.bannerDescription)")
            } catch {
                failures.yield("\(address.key) public read limits: \(error)")
            }
        }
        if let declared = configuration.publicReadURL {
            print("  public-read-url: \(declared)")
        }
        let apps = applications
        return Task {
            await withTaskGroup(of: Void.self) { group in
                for app in apps {
                    group.addTask {
                        do {
                            try await app.runService(gracefulShutdownSignals: [])
                        } catch where !Task.isCancelled {
                            failures.yield("\(address.key) listener failed: \(error)")
                        } catch {}
                    }
                }
                group.addTask {
                    await runVolumeMaintenance {
                        _ = try await process.pruneUnpinnedVolumes()
                    }
                }
            }
        }
    }
}

/// Loopback host control, on the root level's operator application only:
/// attach a level newly added to the config file, or stop and start one
/// level while the rest of the tree keeps running. The root itself is not
/// stoppable here — it serves these routes — so it stops with the process.
private func addHostControlRoutes(
    to router: Router<BasicRequestContext>,
    host: ChainHost,
    attach: @escaping @Sendable (String) throws -> (
        address: ChainAddress, configure: ChainHost.Configure
    )
) {
    router.post("v1/host/levels") { request, context in
        let address = try await hostLevel(request)
        let level = try attach(address.key)
        do {
            try await host.attach(level.address, configure: level.configure)
        } catch let error as ChainHostError {
            throw HTTPError(.conflict, message: error.description)
        }
        return HostLevelRequest(path: address.key)
    }
    router.post("v1/host/levels/stop") { request, context in
        let address = try await hostLevel(request)
        guard !address.isNexus else {
            throw HTTPError(.badRequest, message: "the root level serves host control; stop the process instead")
        }
        guard await host.configuration(address) != nil else {
            throw HTTPError(.notFound, message: "\(address.key) is not hosted here")
        }
        await host.stop(address)
        return HostLevelRequest(path: address.key)
    }
    router.post("v1/host/levels/start") { request, context in
        let address = try await hostLevel(request)
        do {
            try await host.start(address)
        } catch let error as ChainHostError {
            throw HTTPError(.notFound, message: error.description)
        }
        return HostLevelRequest(path: address.key)
    }
}

private func hostLevel(_ request: Request) async throws -> ChainAddress {
    let body = try await request.body.collect(upTo: 4096)
    guard let input = try? JSONDecoder().decode(
        HostLevelRequest.self, from: Data(body.readableBytesView)
    ), let address = ChainAddress(string: input.path) else {
        throw HTTPError(.badRequest, message: "body must be {\"path\": <chain path>}")
    }
    return address
}
