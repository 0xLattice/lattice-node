import Foundation

/// One chain process with its service and network runtime, wired the way
/// the daemon runs them. The service reaches the runtime through a
/// `WeakNetwork` and the runtime reaches the service through a `WeakChain`,
/// so neither keeps the other alive: the caller owns all three.
public struct Node: Sendable {
    public let network: NodeNetworkRuntime
    public let process: ChainProcess
    public let service: ChainService

    /// Open the process, restore its local transactions and start the
    /// network runtime against the service. A child level reads its parent
    /// facts from `parentLevel`.
    public static func build(
        configuration: NodeConfiguration,
        parentLevel: (any ParentLevel)? = nil
    ) async throws -> Node {
        let network = try NodeNetworkRuntime(
            configuration: configuration, parentLevel: parentLevel
        )
        let process = try await ChainProcess.open(configuration: configuration)
        let service = ChainService(
            process: process,
            network: WeakNetwork(network),
            parentLevel: parentLevel
        )
        try await service.restoreLocalTransactions()
        do {
            try await network.start(process: process, chain: WeakChain(service))
        } catch {
            // Restoring may have armed the walk: join it so nothing keeps
            // the process, and its storage lock, past this failure.
            await service.shutdown()
            throw error
        }
        return Node(network: network, process: process, service: service)
    }

    /// Stop in dependency order: the network runtime first, so no ingress
    /// reaches the service, then the service stops and joins its background
    /// work. `afterNetworkStops` runs between the two, for caller tasks that
    /// the network's stop unblocks. Afterwards nothing but the caller holds
    /// the process; its stores and storage lock close when the caller drops
    /// it. Idempotent.
    public func shutdown(
        afterNetworkStops: () async -> Void = {}
    ) async {
        await network.stop()
        await afterNetworkStops()
        await service.shutdown()
    }
}
