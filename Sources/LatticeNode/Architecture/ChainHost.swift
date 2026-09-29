import Foundation

public enum ChainHostError: Error, Equatable, CustomStringConvertible {
    /// A child is configured without its immediate parent. A host runs a
    /// child only co-hosted with its whole ancestry.
    case notAncestorClosed(child: String, missingParent: String)
    case unknownChain(String)
    case alreadyHosted(String)

    public var description: String {
        switch self {
        case .notAncestorClosed(let child, let parent):
            "\(child) has no hosted parent \(parent); a hosted chain set must include every ancestor"
        case .unknownChain(let path): "\(path) is not hosted here"
        case .alreadyHosted(let path): "\(path) is already hosted here"
        }
    }
}

/// One process hosting a chain tree: one `Node` per level, built and started
/// parent-first and stopped in reverse. Each child's parent endpoint is its
/// co-hosted parent's fact plane on loopback, so the hierarchy plane runs
/// unchanged between levels of the same process.
///
/// Levels also stop and start one at a time, leaving the others running: a
/// stopped level releases its storage and its listeners exactly as a stopped
/// process did, and its neighbours see a disconnected peer.
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

    /// Starts every stopped level, parent-first.
    public func startAll() async throws {
        for address in paths where levels[address]?.running == nil {
            try await start(address)
        }
    }

    /// Stops every running level, children first.
    public func stopAll() async {
        for address in paths.reversed() {
            await stop(address)
        }
    }

    /// Starts one level. Its parent need not be running: the child dials the
    /// loopback endpoint and connects once the parent is up, as a separately
    /// started process did.
    public func start(_ address: ChainAddress) async throws {
        guard let level = levels[address] else {
            throw ChainHostError.unknownChain(address.key)
        }
        guard level.running == nil else { return }
        let node = try await Node.build(configuration: level.configuration)
        var running = Running(node: node)
        if let services {
            running.services.start { _ in services.serve(node, on: self) }
        }
        if let seeded = node.activateSeededChildGenesis(
            storage: level.configuration.storagePath
        ) {
            running.seededGenesis.start { _ in seeded }
        }
        levels[address]?.running = running
    }

    /// Stops one level and leaves the rest running. Returns once the level's
    /// services have ended, its network has stopped, and its storage lock is
    /// released, so the same process can start it again.
    public func stop(_ address: ChainAddress) async {
        guard var running = levels[address]?.running else { return }
        levels[address]?.running = nil
        let tasks = [running.services.take(), running.seededGenesis.take()]
            .compactMap { $0 }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        await running.node.network.stop()
        await running.node.service.shutdown()
        // The storage lock is held for the process's lifetime, so it is
        // released only when the last reference to the level's process goes.
        // Bounded: a reference that outlives this wait leaves the level
        // stopped, and a later `start` fails with `storageInUse`.
        let released = { [weak process = running.node.process] in
            process == nil
        }
        _ = consume running
        for _ in 0..<3_000 where !released() {
            guard await Timers.sleep(nanoseconds: 10_000_000) else { return }
        }
    }

    /// Adds a level to a running host and starts it. Its parent must already
    /// be hosted.
    public func attach(
        _ address: ChainAddress, configure: Configure
    ) async throws {
        guard levels[address] == nil else {
            throw ChainHostError.alreadyHosted(address.key)
        }
        levels[address] = Level(
            configuration: try Self.configure(
                address, configure, in: levels
            ),
            running: nil
        )
        try await start(address)
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
    func serve(_ node: Node, on host: ChainHost) -> Task<Void, Never>
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
