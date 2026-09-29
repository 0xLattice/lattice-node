import ArgumentParser
import Foundation
import Hummingbird
import LatticeCtlCore
import LatticeNode
import Synchronization

/// What ends or narrows a running host: a stop signal, or a level whose
/// listener failed.
enum HostEvent: Sendable {
    case signal
    case failed(ChainAddress, String)
}

/// Counts stop signals: the first stops the tree, a second exits at once.
final class SignalCount: Sendable {
    private let count = Atomic<Int>(0)

    func next() -> Int {
        count.wrappingAdd(1, ordering: .relaxed).newValue
    }
}

/// Each level's listeners and maintenance.
struct DaemonLevelServices: ChainHostServices {
    let command: LatticeNodeCommand
    /// Each level's `lattice.json` entry, as the host booted with it.
    let entries: [String: TopologyChain]
    let processStartTime: Date
    let events: AsyncStream<HostEvent>.Continuation

    func serve(_ node: Node) -> Task<Void, Never> {
        Task {
            await command.serveLevel(
                node: node,
                chain: entries[node.process.configuration.address.key],
                services: self
            )
        }
    }
}

extension LatticeNodeCommand {
    /// One process hosting every chain of a `lattice.json` tree. Each level
    /// keeps its own ports, identity and storage, exactly as the process that
    /// used to run it; only the process boundary is gone. A child level that
    /// fails is stopped alone; only a root failure or a signal ends the
    /// process. The chain set is read once: a chain added to the file is
    /// hosted from the next start.
    func runHost(configPath: String) async throws {
        let processStartTime = Date()
        try refuseSingleChainOptions()
        guard ["127.0.0.1", "::1", "localhost"].contains(rpcBind.lowercased()) else {
            throw ValidationError("the unauthenticated HTTP API may bind only to loopback")
        }
        let configURL = URL(fileURLWithPath: configPath)
        let layout = HostLayout(
            root: dataRoot ?? configURL.deletingLastPathComponent().path
        )
        let topology = try loadTopology(configURL)
        try layout.migrateIdentityKeys(for: topology.chains.keys)
        let (events, continuation) = AsyncStream<HostEvent>.makeStream()
        var chains: [ChainAddress: ChainHost.Configure] = [:]
        for (path, chain) in topology.chains {
            let level = try hostedLevel(path: path, chain: chain, layout: layout)
            chains[level.address] = level.configure
        }
        let host = try ChainHost(chains: chains, services: DaemonLevelServices(
            command: self, entries: topology.chains,
            processStartTime: processStartTime, events: continuation
        ))

        // Stop on a signal by stopping the levels, children first, rather
        // than letting each listener take the signal on its own. A second
        // signal while that runs exits at once.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signals = SignalCount()
        let signalSources = [SIGTERM, SIGINT].map { number in
            let source = DispatchSource.makeSignalSource(
                signal: number, queue: .global()
            )
            source.setEventHandler {
                if signals.next() > 1 { Foundation.exit(1) }
                continuation.yield(.signal)
            }
            source.resume()
            return source
        }
        defer { signalSources.forEach { $0.cancel() } }

        do {
            for (path, error) in try await host.startAll() {
                logHostError("\(path.key) failed to start: \(error)")
            }
        } catch {
            await host.stopAll()
            throw error
        }
        var failure: String?
        events: for await event in events {
            switch event {
            case .signal:
                break events
            case .failed(let address, let reason):
                if address.parent == nil {
                    failure = reason
                    break events
                }
                logHostError("\(reason); stopping \(address.key)")
                await host.stop(address)
            }
        }
        await host.stopAll()
        if let failure {
            throw CtlError(failure)
        }
    }

    /// Host mode takes every per-chain setting from the file, so a
    /// single-chain option given alongside it would be silently ignored.
    private func refuseSingleChainOptions() throws {
        let defaults = try Self.parse([])
        let given = [
            ("--chain-path", chainPath != defaults.chainPath),
            ("--data-directory", dataDirectory != nil),
            ("--identity-key", identityKey != nil),
            ("--listen-port", listenPort != defaults.listenPort),
            ("--fact-listen-port", factListenPort != defaults.factListenPort),
            ("--rpc-port", rpcPort != defaults.rpcPort),
            ("--peer", !peer.isEmpty),
            ("--no-default-peers", noDefaultPeers),
            ("--parent", parent != nil),
            ("--public-read-port", publicReadPort != nil),
            ("--public-read-rate", publicReadRate != defaults.publicReadRate),
            ("--public-read-expensive-rate",
             publicReadExpensiveRate != defaults.publicReadExpensiveRate),
            ("--public-read-max-rate", publicReadMaxRate != defaults.publicReadMaxRate),
            ("--external-address", externalAddress != nil),
            ("--public-read-url", publicReadUrl != nil),
        ].filter(\.1).map(\.0)
        guard given.isEmpty else {
            throw ValidationError("--config takes every per-chain setting from the file; \(given.joined(separator: ", ")) apply only without it")
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
    /// fails is reported, and the host stops that level.
    func serveLevel(
        node: Node,
        chain: TopologyChain?,
        services: DaemonLevelServices
    ) async {
        let configuration = node.process.configuration
        let address = configuration.address
        let network = node.network
        let service = node.service
        let process = node.process
        let events = services.events
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
            processStartTime: services.processStartTime
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
                events.yield(.failed(address, "\(address.key) public read limits: \(error)"))
            }
        }
        if let declared = configuration.publicReadURL {
            print("  public-read-url: \(declared)")
        }
        let apps = applications
        await withTaskGroup(of: Void.self) { group in
            for app in apps {
                group.addTask {
                    do {
                        try await app.runService(gracefulShutdownSignals: [])
                    } catch where !Task.isCancelled {
                        events.yield(.failed(address, "\(address.key) listener failed: \(error)"))
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

private func logHostError(_ message: String) {
    FileHandle.standardError.write(Data("lattice-node: \(message)\n".utf8))
}
