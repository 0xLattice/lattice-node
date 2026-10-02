import Foundation
import Hummingbird
import Ivy
import XCTest
@testable import LatticeNode
@testable import LatticeNodeDaemon

extension XCTestCase {
    /// A core driver over `process`, on a loopback overlay with no peers,
    /// stopped at teardown.
    func startDriver(_ process: ChainProcess) async throws -> CoreDriver {
        let configuration = process.configuration
        let port = NetworkTransportTestPorts.allocate()
        let driver = try await CoreDriver.start(
            process: process,
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
        addTeardownBlock { await driver.stop() }
        return driver
    }
}

/// The daemon's loopback application over a driver, as `runCoreDriver` builds it.
func makeApplication(
    service driver: CoreDriver, host: String, port: Int
) -> Application<RouterResponder<BasicRequestContext>> {
    makeApplication(
        reads: driver.reads,
        writes: driver,
        status: { await driver.status() },
        metrics: { driver.metricsExposition(peers: $0, processStartTime: $1) },
        host: host,
        port: port,
        peers: { ExplorerPeersResponse(count: driver.peerCount, peers: []) },
        processStartTime: Date()
    )
}

/// The daemon's public read application over a driver.
func makePublicReadApplication(
    service driver: CoreDriver,
    host: String,
    port: Int,
    limits: PublicReadRateLimits = .default,
    healthClock: @escaping @Sendable () -> Double = PublicReadRateLimiter.monotonicSeconds
) -> Application<RouterResponder<PublicReadRequestContext>> {
    makePublicReadApplication(
        reads: driver.reads, host: host, port: port, limits: limits, healthClock: healthClock
    )
}
