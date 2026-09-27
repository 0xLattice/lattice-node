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
    /// network runtime against the service.
    public static func build(configuration: NodeConfiguration) async throws -> Node {
        let network = try NodeNetworkRuntime(configuration: configuration)
        let process = try await ChainProcess.open(configuration: configuration)
        let service = ChainService(process: process, network: WeakNetwork(network))
        try await service.restoreLocalTransactions()
        try await network.start(process: process, chain: WeakChain(service))
        return Node(network: network, process: process, service: service)
    }
}
