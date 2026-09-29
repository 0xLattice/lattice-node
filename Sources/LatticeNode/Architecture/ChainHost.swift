import Foundation

public enum ChainHostError: Error, Equatable, CustomStringConvertible {
    /// A child is configured without its immediate parent. A host runs a
    /// child only co-hosted with its whole ancestry.
    case notAncestorClosed(child: String, missingParent: String)

    public var description: String {
        switch self {
        case .notAncestorClosed(let child, let parent):
            "\(child) has no hosted parent \(parent); a hosted chain set must include every ancestor"
        }
    }
}

/// One process hosting a chain tree: one `Node` per level, built and started
/// parent-first and stopped in reverse. Each child's parent endpoint is its
/// co-hosted parent's fact plane on loopback, so the hierarchy plane runs
/// unchanged between levels of the same process.
///
/// The level set is fixed when the host is built: a chain added to the
/// configuration takes effect when the process restarts. Only the host's
/// owner calls it, one call at a time: `startAll`, then `stop` for a child
/// level that failed, then `stopAll`.
public actor ChainHost {
    /// This level's configuration, given the endpoint the host wired for its
    /// parent (nil for Nexus).
    public typealias Configure = @Sendable (ParentEndpoint?) throws -> NodeConfiguration
    private struct Level {
        let configuration: NodeConfiguration
        var running: Running?
    }

    private struct Running {
        let node: Node
        var services = TaskSlot()
        var seededGenesis = TaskSlot()
    }

    private var levels: [ChainAddress: Level] = [:]
    private let services: (any ChainHostServices)?

    /// Configures every level, parent-first. Throws `notAncestorClosed` when
    /// a configured child's parent is not configured too.
    public init(
        chains: [ChainAddress: Configure],
        services: (any ChainHostServices)? = nil
    ) throws {
        self.services = services
        for address in chains.keys.sorted(by: Self.parentFirst) {
            levels[address] = Level(
                configuration: try Self.configure(
                    address, chains[address]!, in: levels
                ),
                running: nil
            )
        }
    }

    public var paths: [ChainAddress] {
        levels.keys.sorted(by: Self.parentFirst)
    }

    public func node(_ address: ChainAddress) -> Node? {
        levels[address]?.running?.node
    }

    public func configuration(_ address: ChainAddress) -> NodeConfiguration? {
        levels[address]?.configuration
    }

    /// Starts every level, parent-first. A child that fails to start is
    /// skipped and returned, and the rest of the tree still starts; only a
    /// root that fails to start throws.
    @discardableResult
    public func startAll() async throws -> [(path: ChainAddress, error: any Error)] {
        var failed: [(path: ChainAddress, error: any Error)] = []
        for address in paths {
            do {
                try await start(address)
            } catch {
                if address.parent == nil { throw error }
                failed.append((address, error))
            }
        }
        return failed
    }

    /// Stops every running level, children first.
    public func stopAll() async {
        for address in paths.reversed() {
            await stop(address)
        }
    }

    /// Stops one level and leaves the rest running: how the host contains a
    /// child level that failed. Returns once the level's services have ended
    /// and its network has stopped.
    public func stop(_ address: ChainAddress) async {
        guard var running = levels[address]?.running else { return }
        levels[address]?.running = nil
        let services = running.services.take()
        let seeded = running.seededGenesis.take()
        services?.cancel()
        seeded?.cancel()
        await services?.value
        // The seed task is joined after the network stops, which resumes its
        // parent-record wait.
        await running.node.shutdown {
            await seeded?.value
        }
    }

    private func start(_ address: ChainAddress) async throws {
        guard let level = levels[address], level.running == nil else { return }
        let node = try await Node.build(configuration: level.configuration)
        var running = Running(node: node)
        if let services {
            running.services.start { _ in services.serve(node) }
        }
        if let seeded = node.activateSeededChildGenesis(
            storage: level.configuration.storagePath
        ) {
            running.seededGenesis.start { _ in seeded }
        }
        levels[address]?.running = running
    }

    private static func configure(
        _ address: ChainAddress,
        _ configure: Configure,
        in levels: [ChainAddress: Level]
    ) throws -> NodeConfiguration {
        guard let parentAddress = address.parent else {
            return try configure(nil)
        }
        guard let parent = levels[parentAddress] else {
            throw ChainHostError.notAncestorClosed(
                child: address.key, missingParent: parentAddress.key
            )
        }
        return try configure(ParentEndpoint(
            publicKey: parent.configuration.processPublicKey,
            host: "127.0.0.1",
            port: parent.configuration.factListenPort
        ))
    }

    private static func parentFirst(_ a: ChainAddress, _ b: ChainAddress) -> Bool {
        (a.components.count, a.key) < (b.components.count, b.key)
    }
}

/// What runs beside a hosted level for as long as it runs (its HTTP
/// listeners, maintenance). `ChainHost.stop` cancels the task and waits for
/// it.
public protocol ChainHostServices: Sendable {
    func serve(_ node: Node) -> Task<Void, Never>
}

extension Node {
    /// A deployed child holds its own self-contained genesis bytes: the
    /// parent only RECORDED the CID. If the deployer seeded
    /// `child-genesis.json` into `storage`, rebuild the identical genesis and
    /// self-admit it — but only after confirming, over the authenticated
    /// parent fact plane, that the parent actually recorded THIS CID. That is
    /// the same record honest followers demand before admitting the genesis,
    /// so a genesis the parent never recorded cannot self-activate here
    /// either. Retries until active so a child started slightly ahead of its
    /// parent's anchor (or its parent connection) still comes up once the
    /// record lands. Nil when there is no seed to activate.
    public func activateSeededChildGenesis(storage: URL) -> Task<Void, Never>? {
        guard process.configuration.chainPath.count > 1,
              let seedData = try? Data(
                  contentsOf: storage.appendingPathComponent("child-genesis.json")
              ),
              let seed = try? JSONDecoder().decode(
                  ChildGenesisSeed.self, from: seedData
              ) else {
            return nil
        }
        let process = process
        let network = network
        return Task { [weak process, weak network] in
            while !Task.isCancelled {
                guard let process else { return }
                if await process.status().phase == .active { return }
                if (try? await process.activateSeededChildGenesis(
                    seed: seed,
                    confirmParentRecordedGenesis: { childGenesisCID in
                        guard let network else { return false }
                        return await network
                            .confirmParentRecordedChildGenesis(
                                childGenesisCID: childGenesisCID
                            )
                    }
                )) == true {
                    return
                }
                guard await Timers.sleep(nanoseconds: 1_000_000_000) else {
                    return
                }
            }
        }
    }
}
