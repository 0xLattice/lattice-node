import Foundation
import Hummingbird
import LatticeNode
import LatticeNodeCore

/// What `GET /v1/core/snapshot` answers: the driver's last published
/// snapshot.
struct CoreSnapshotResponse: Codable, Equatable {
    let bestHeaderTip: String
    let bestHeaderHeight: UInt64
    let actOnTip: String
    let actOnHeight: UInt64
}

extension LatticeNodeCommand {
    /// `--core-driver`: Nexus on the core driver, with a loopback read of its
    /// published snapshot, until SIGTERM/SIGINT.
    // PENDING N5b: the RPC surface (ChainService reads, templates, tx
    // submission) moves onto the driver's snapshot and events.
    func runCoreDriver(configuration: NodeConfiguration) async throws {
        let process = try await ChainProcess.open(configuration: configuration)
        let driver = try await CoreDriver.start(process: process, configuration: configuration)
        let router = Router()
        router.get("v1/core/snapshot") { _, _ -> Response in
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
        let app = Application(
            responder: router.buildResponder(),
            configuration: .init(address: .hostname(rpcBind, port: Int(rpcPort)))
        )
        print("lattice-node Nexus (core driver)")
        print("  process: \(configuration.processPublicKey)")
        print("  nexus:   \(configuration.nexusGenesisCID)")
        print("  rpc:     http://\(rpcBind):\(rpcPort)/v1/core/snapshot")
        let result: Result<Void, any Error>
        do {
            try await app.runService()
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await driver.stop()
        try result.get()
    }
}
