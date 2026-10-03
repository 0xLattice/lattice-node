import Foundation
import Hummingbird
import Ivy
import XCTest
@testable import LatticeNode
@testable import LatticeNodeDaemon

extension XCTestCase {
    /// A node runtime over `storage`, on a loopback overlay with no peers,
    /// stopped at teardown.
    func startRuntime(_ storage: NodeStorage) async throws -> NodeRuntime {
        let configuration = storage.configuration
        let port = NetworkTransportTestPorts.allocate()
        let runtime = try await NodeRuntime.start(
            storage: storage,
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: port,
                bootstrapPeers: [],
                requestTimeout: .seconds(5),
                stunServers: [],
                healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            )
        )
        addTeardownBlock { await runtime.stop() }
        return runtime
    }
}

/// The daemon's loopback application over a runtime, as `runNodeRuntime` builds it.
func makeApplication(
    service runtime: NodeRuntime, host: String, port: Int
) -> Application<RouterResponder<BasicRequestContext>> {
    makeApplication(
        reads: runtime.reads,
        writes: runtime,
        status: { await runtime.status() },
        metrics: { runtime.metricsExposition(peers: $0, processStartTime: $1) },
        host: host,
        port: port,
        peers: { ExplorerPeersResponse(count: runtime.peerCount, peers: []) },
        processStartTime: Date()
    )
}

/// The daemon's public read application over a runtime.
func makePublicReadApplication(
    service runtime: NodeRuntime,
    host: String,
    port: Int,
    limits: PublicReadRateLimits = .default,
    healthClock: @escaping @Sendable () -> Double = PublicReadRateLimiter.monotonicSeconds
) -> Application<RouterResponder<PublicReadRequestContext>> {
    makePublicReadApplication(
        reads: runtime.reads, host: host, port: port, limits: limits, healthClock: healthClock
    )
}
