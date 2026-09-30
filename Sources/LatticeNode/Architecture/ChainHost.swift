import Foundation

public enum ChainHostError: Error, Equatable, CustomStringConvertible {
    /// A child is configured without its immediate parent. A host runs a
    /// child only co-hosted with its whole ancestry.
    case notAncestorClosed(child: String, missingParent: String)
    /// A child's parent level is not running (it failed to start), so the
    /// child has no parent facts to admit blocks against.
    case parentNotRunning(child: String, parent: String)

    public var description: String {
        switch self {
        case .notAncestorClosed(let child, let parent):
            "\(child) has no hosted parent \(parent); a hosted chain set must include every ancestor"
        case .parentNotRunning(let child, let parent):
            "\(child) cannot start: its parent \(parent) is not running"
        }
    }
}

/// One process hosting a chain tree: one `Node` per level, built and started
/// parent-first and stopped in reverse. Each child reads its parent facts
/// from its co-hosted parent level (`LocalParentLevel`) and is told, in
/// order, when the parent's tip moves and when a run the parent credits into
/// its directory changes. Each parent announces its hosted children's
/// geneses and serves their public read URLs.
///
/// The level set is fixed when the host is built: a chain added to the
/// configuration takes effect when the process restarts. Only the host's
/// owner calls it, one call at a time: `startAll`, then `stop` for a child
/// level that failed, then `stopAll`.
public actor ChainHost {
    /// This level's configuration.
    public typealias Configure = @Sendable () throws -> NodeConfiguration
    private struct Level {
        var configuration: NodeConfiguration
        var running: Running?
    }

    private struct Running {
        let node: Node
        var services = TaskSlot()
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
        // Each parent announces the genesis and serves the public read URL
        // of each child it hosts.
        for address in levels.keys {
            guard let parent = address.parent,
                  let child = levels[address]?.configuration,
                  let hosting = levels[parent]?.configuration
            else { continue }
            levels[parent]?.configuration = hosting.withHostedChild(
                directory: address.directory,
                publicReadURL: child.publicReadURL
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
    /// skipped and returned, and so is every descendant of it
    /// (`parentNotRunning`); the rest of the tree still starts. Only a root
    /// that fails to start throws.
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
            await stopLevel(address)
        }
    }

    /// Stops one level and every level below it, children first, and leaves
    /// the rest running: how the host contains a child level that failed,
    /// since a child cannot run without its parent level. Returns the
    /// descendants it stopped, once every stopped level's services have
    /// ended and its network has stopped.
    @discardableResult
    public func stop(_ address: ChainAddress) async -> [ChainAddress] {
        let descendants = paths.reversed().filter {
            $0.components.count > address.components.count
                && $0.components.starts(with: address.components)
                && levels[$0]?.running != nil
        }
        for descendant in descendants {
            await stopLevel(descendant)
        }
        await stopLevel(address)
        return descendants
    }

    private func stopLevel(_ address: ChainAddress) async {
        guard var running = levels[address]?.running else { return }
        levels[address]?.running = nil
        let services = running.services.take()
        services?.cancel()
        await services?.value
        await running.node.shutdown()
    }

    private func start(_ address: ChainAddress) async throws {
        guard let level = levels[address], level.running == nil else { return }
        let parent = address.parent.flatMap { levels[$0]?.running?.node }
        if let parentAddress = address.parent, parent == nil {
            throw ChainHostError.parentNotRunning(
                child: address.key, parent: parentAddress.key
            )
        }
        let node = try await Node.build(
            configuration: level.configuration,
            parentLevel: parent.map { LocalParentLevel($0.process) }
        )
        if let parent {
            // The child's one ordered mailbox from its parent. The parent
            // only enqueues into it. The child's drain serves this
            // directory's runs on the parent (now, and again when the child's
            // genesis activates) outside any lease of the child's: the
            // parent's serve may take the parent's gate, so it is never
            // called from inside a child's lease (§2.4).
            let directory = address.directory
            let mailbox = await node.service.openParentMailbox(
                tipChanged: { [weak network = node.network] in
                    await network?.parentChanged(.tipChanged)
                },
                serveParentRuns: { [weak parentService = parent.service] in
                    await parentService?.serveRuns(for: directory)
                },
                // Marks the parent's own rebuild; takes no lease (§2.4).
                candidateChanged: { [weak parentService = parent.service] in
                    await parentService?.childCandidateChanged()
                }
            )
            await parent.service.attachChildLevel(LocalChildLevel(
                directory: directory,
                mailbox: mailbox,
                service: node.service
            ))
            // A tip change while the child was starting found no listener.
            mailbox.send(.tipChanged)
        }
        var running = Running(node: node)
        if let services {
            running.services.start { _ in services.serve(node) }
        }
        levels[address]?.running = running
    }

    private static func configure(
        _ address: ChainAddress,
        _ configure: Configure,
        in levels: [ChainAddress: Level]
    ) throws -> NodeConfiguration {
        guard let parentAddress = address.parent else {
            return try configure()
        }
        guard levels[parentAddress] != nil else {
            throw ChainHostError.notAncestorClosed(
                child: address.key, missingParent: parentAddress.key
            )
        }
        return try configure()
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
