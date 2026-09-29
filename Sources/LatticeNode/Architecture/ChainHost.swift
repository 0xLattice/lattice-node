import Foundation

public enum ChainHostError: Error, Equatable, CustomStringConvertible {
    /// A child is configured without its immediate parent. A host runs a
    /// child only co-hosted with its whole ancestry.
    case notAncestorClosed(child: String, missingParent: String)
    case unknownChain(String)
    case alreadyHosted(String)
    /// A level would bind a port another running level already holds.
    case portInUse(port: UInt16, path: String, heldBy: String)
    /// A stopped level's process is still referenced, so its storage lock is
    /// still held and the level cannot be started again yet.
    case storageStillHeld(String)

    public var description: String {
        switch self {
        case .notAncestorClosed(let child, let parent):
            "\(child) has no hosted parent \(parent); a hosted chain set must include every ancestor"
        case .unknownChain(let path): "\(path) is not hosted here"
        case .alreadyHosted(let path): "\(path) is already hosted here"
        case .portInUse(let port, let path, let holder):
            "\(path) needs port \(port), which running level \(holder) holds"
        case .storageStillHeld(let path):
            "\(path) stopped but its storage is still held; retry the start later"
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
/// process did, and its neighbours see a disconnected peer. Starts and stops
/// of one level are serialized: a stop that arrives while the level is still
/// being built waits for the build and then tears it down, and a second start
/// joins the first.
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
    /// Levels with a start or stop in flight, and who is waiting their turn.
    private var busy: Set<ChainAddress> = []
    private var waiting: [ChainAddress: [CheckedContinuation<Void, Never>]] = [:]

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

    /// Whether a start or stop of `address` is in flight.
    func isBusy(_ address: ChainAddress) -> Bool {
        busy.contains(address)
    }

    /// Starts every stopped level, parent-first. A child that fails to start
    /// is skipped and returned, and the rest of the tree still starts; only a
    /// root that fails to start throws. Every level's turn is taken up front,
    /// so a start or stop requested for a level not yet reached joins this
    /// start instead of acting ahead of it.
    @discardableResult
    public func startAll() async throws -> [(path: ChainAddress, error: any Error)] {
        let order = paths
        for address in order { await acquire(address) }
        var failed: [(path: ChainAddress, error: any Error)] = []
        for (index, address) in order.enumerated() {
            do {
                try await startLocked(address)
            } catch {
                if address.parent == nil {
                    order[index...].forEach(release)
                    throw error
                }
                failed.append((address, error))
            }
            release(address)
        }
        return failed
    }

    /// Stops every running level, children first, after any start or stop in
    /// flight for it.
    public func stopAll() async {
        for address in paths.reversed() {
            try? await stop(address)
        }
    }

    /// Starts one level, or joins a start already in flight. Its parent need
    /// not be running: the child dials the loopback endpoint and connects once
    /// the parent is up, as a separately started process did.
    public func start(_ address: ChainAddress) async throws {
        guard levels[address] != nil else {
            throw ChainHostError.unknownChain(address.key)
        }
        await acquire(address)
        defer { release(address) }
        try await startLocked(address)
    }

    /// Stops one level and leaves the rest running, after any start in
    /// flight for it. Returns once the level's services have ended, its
    /// network has stopped, and its storage lock is released, so the same
    /// process can start it again; throws `storageStillHeld` if the lock is
    /// not released in time.
    public func stop(_ address: ChainAddress) async throws {
        await acquire(address)
        defer { release(address) }
        try await stopLocked(address)
    }

    /// Adds a level to a running host and starts it. Its parent must already
    /// be hosted. A level that fails to start is not kept.
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
        do {
            try await start(address)
        } catch {
            if levels[address]?.running == nil {
                levels[address] = nil
            }
            throw error
        }
    }

    private func startLocked(_ address: ChainAddress) async throws {
        guard let level = levels[address], level.running == nil else { return }
        try checkPortsFree(address, level.configuration)
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

    private func stopLocked(_ address: ChainAddress) async throws {
        guard var running = levels[address]?.running else { return }
        levels[address]?.running = nil
        let tasks = [running.services.take(), running.seededGenesis.take()]
            .compactMap { $0 }
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        await running.node.network.stop()
        await running.node.service.shutdown()
        // The storage lock is held for the process's lifetime, so it is
        // released only once the last reference to the level's process has
        // gone and its deinit has run. Probed on the lock itself: the weak
        // reference clears before that deinit closes the descriptor.
        let storage = running.node.process.configuration.storagePath
        let released = {
            (try? StorageDirectoryLock(directory: storage)) != nil
        }
        _ = consume running
        for _ in 0..<3_000 where !released() {
            guard await Timers.sleep(nanoseconds: 10_000_000) else { break }
        }
        guard released() else {
            throw ChainHostError.storageStillHeld(address.key)
        }
    }

    private func checkPortsFree(
        _ address: ChainAddress, _ configuration: NodeConfiguration
    ) throws {
        for (other, level) in levels where other != address {
            guard let held = level.running?.node.process.configuration else {
                continue
            }
            let heldPorts = [held.listenPort, held.factListenPort, held.rpcPort]
            for port in [
                configuration.listenPort,
                configuration.factListenPort,
                configuration.rpcPort,
            ] where heldPorts.contains(port) {
                throw ChainHostError.portInUse(
                    port: port, path: address.key, heldBy: other.key
                )
            }
        }
    }

    private func acquire(_ address: ChainAddress) async {
        while busy.contains(address) {
            await withCheckedContinuation { continuation in
                waiting[address, default: []].append(continuation)
            }
        }
        busy.insert(address)
    }

    private func release(_ address: ChainAddress) {
        busy.remove(address)
        guard var queue = waiting[address], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        waiting[address] = queue.isEmpty ? nil : queue
        next.resume()
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
