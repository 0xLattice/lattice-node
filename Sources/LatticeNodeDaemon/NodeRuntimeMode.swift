import Foundation
import Hummingbird
import LatticeNode
import LatticeNodeCore

/// What `GET /core/snapshot` answers: the root chain's last published
/// snapshot.
struct ChainSnapshotResponse: Codable, Equatable {
    let bestHeaderTip: String
    @DecimalString var bestHeaderHeight: UInt64
    let actOnTip: String
    @DecimalString var actOnHeight: UInt64
}

extension LatticeNodeCommand {
    /// Run the configured chain tree until SIGTERM/SIGINT. The loopback API
    /// reads published snapshots and submits core events; the public listener
    /// serves the same read routes without the write surface.
    func runNodeRuntime(
        configuration: NodeConfiguration,
        cookieFile: URL,
        publicReadLimits: PublicReadRateLimits,
        processStartTime: Date
    ) async throws {
        let storage = try await NodeStorage.open(configuration: configuration)
        // Rotated once this process owns the storage (a second node on the
        // same directory fails above, before touching the first one's
        // cookie) and before the runtime boots: a cookie left by an earlier
        // run never authenticates against this one.
        let auth = try LoopbackRPCAuth.createCookie(at: cookieFile, allowedOrigins: rpcAllowedOrigins)
        defer { try? FileManager.default.removeItem(at: cookieFile) }
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration)
        let peers: @Sendable () async -> ExplorerPeersResponse = {
            ExplorerPeersResponse(count: runtime.peerCount, peers: [])
        }
        let app = makeApplication(
            reads: runtime.reads,
            levelReads: Array(runtime.levelReads.values),
            writes: runtime,
            status: { await runtime.status() },
            metrics: { runtime.metricsExposition(peers: $0, processStartTime: $1) },
            host: rpcBind,
            port: Int(rpcPort),
            peers: peers,
            processStartTime: processStartTime,
            auth: auth,
            endpoints: { await runtime.chainEndpoints($0) }
        ) { router in
            router.get("core/snapshot") { _, _ -> Response in
                guard let snapshot = runtime.published.value else { return Response(status: .serviceUnavailable) }
                let body = try JSONEncoder().encode(ChainSnapshotResponse(
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
        var submit: PublicSubmit?
        if publicSubmit {
            submit = { @Sendable request in try await runtime.submitPublicTransaction(request) }
        }
        let publicReadApp = publicReadPort.map { port in
            makePublicReadApplication(
                reads: runtime.reads,
                levelReads: Array(runtime.levelReads.values),
                host: "0.0.0.0",
                port: Int(port),
                peers: peers,
                limits: publicReadLimits,
                endpoints: { await runtime.chainEndpoints($0) },
                submit: submit
            )
        }
        print("lattice-node (node runtime)")
        print("  storage: \(configuration.processPublicKey)")
        print("  nexus:   \(configuration.nexusGenesisCID)")
        print("  rpc:     http://\(rpcBind):\(rpcPort) (cookie: \(cookieFile.path))")
        if let publicReadPort {
            print("  public-read: http://0.0.0.0:\(publicReadPort)")
            if publicSubmit { print("  public-submit: POST /transactions on the public read port") }
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
        await runtime.stop()
        try result.get()
    }
}
