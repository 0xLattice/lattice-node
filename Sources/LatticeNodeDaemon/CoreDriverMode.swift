import Foundation
import Hummingbird
import LatticeNode
import LatticeNodeCore

/// What `GET /core/snapshot` answers: the driver's last published
/// snapshot.
struct CoreSnapshotResponse: Codable, Equatable {
    let bestHeaderTip: String
    let bestHeaderHeight: UInt64
    let actOnTip: String
    let actOnHeight: UInt64
}

extension LatticeNodeCommand {
    /// Nexus on the core driver until SIGTERM/SIGINT. The loopback API reads
    /// from the driver's published snapshot, writes as core events, plus a
    /// loopback read of the snapshot itself; the public read listener serves
    /// the same read routes.
    // PENDING: per-peer summaries in `api/peers` (count only).
    func runCoreDriver(
        configuration: NodeConfiguration,
        publicReadLimits: PublicReadRateLimits,
        processStartTime: Date
    ) async throws {
        let process = try await ChainProcess.open(configuration: configuration)
        let driver = try await CoreDriver.start(process: process, configuration: configuration)
        let peers: @Sendable () async -> ExplorerPeersResponse = {
            ExplorerPeersResponse(count: driver.peerCount, peers: [])
        }
        let app = makeApplication(
            reads: driver.reads,
            levelReads: Array(driver.levelReads.values),
            writes: driver,
            status: { await driver.status() },
            metrics: { driver.metricsExposition(peers: $0, processStartTime: $1) },
            host: rpcBind,
            port: Int(rpcPort),
            peers: peers,
            processStartTime: processStartTime
        ) { router in
            router.get("core/snapshot") { _, _ -> Response in
                guard let snapshot = driver.published.value else { return Response(status: .serviceUnavailable) }
                let body = try JSONEncoder().encode(CoreSnapshotResponse(
                    bestHeaderTip: snapshot.bestHeaderTip,
                    bestHeaderHeight: snapshot.bestHeaderHeight,
                    actOnTip: snapshot.actOnTip,
                    actOnHeight: snapshot.actOnHeight
                ))
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/json"],
                    body: ResponseBody(byteBuffer: ByteBuffer(bytes: body))
                )
            }
        }
        let publicReadApp = publicReadPort.map { port in
            makePublicReadApplication(
                reads: driver.reads,
            levelReads: Array(driver.levelReads.values),
                host: "0.0.0.0",
                port: Int(port),
                peers: peers,
                    limits: publicReadLimits
            )
        }
        print("lattice-node Nexus (core driver)")
        print("  process: \(configuration.processPublicKey)")
        print("  nexus:   \(configuration.nexusGenesisCID)")
        print("  rpc:     http://\(rpcBind):\(rpcPort)")
        if let publicReadPort {
            print("  public-read: http://0.0.0.0:\(publicReadPort)")
        }
        let result: Result<Void, any Error>
        do {
            if let publicReadApp {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await app.runService() }
                    group.addTask { try await publicReadApp.runService() }
                    do {
                        _ = try await group.next()
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                    group.cancelAll()
                }
            } else {
                try await app.runService()
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await driver.stop()
        try result.get()
    }
}
