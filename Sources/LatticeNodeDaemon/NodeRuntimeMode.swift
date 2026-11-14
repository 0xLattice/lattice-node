import Foundation
import Hummingbird
import LatticeNode
import LatticeNodeCore
import LatticeNodeAPI
import LatticeCtlCore

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
        operatorListener: OperatorListener?,
        owner: (layout: HostLayout, topology: Topology)?,
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
        // The operator's control of the node: restart always; under --root
        // its configuration (mining included), logs and wipe.
        let lifecycle = NodeLifecycle()
        var control = OperatorControl(
            tokens: operatorListener?.tokens, lifecycle: lifecycle, storagePath: configuration.storagePath
        )
        if let owner {
            let mining = MinerSupervisor(layout: owner.layout)
            control.mining = mining
            control.config = OperatorConfig(
                layout: owner.layout, started: owner.topology, runtime: runtime, mining: mining
            )
            control.logs = [
                "node": owner.layout.logFile(for: "lattice-node"), "mine": owner.layout.logFile(for: "mine"),
            ]
            await mining.apply(owner.topology.mine)
        }
        // The loopback API and the remote operator listener: one set of
        // routes, each listener with its own credentials.
        let operatorApplication = { (host: String, port: Int, access: OperatorAccess) in
            makeApplication(
                reads: runtime.reads,
                levelReads: { Array(runtime.levelReads.values) },
                writes: runtime,
                status: { await runtime.status() },
                metrics: { runtime.metricsExposition(peers: $0, processStartTime: $1) },
                host: host,
                port: port,
                peers: peers,
                processStartTime: processStartTime,
                auth: access,
                endpoints: { await runtime.chainEndpoints($0) },
                control: control
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
        }
        let app = operatorApplication(rpcBind, Int(rpcPort), .loopback(auth))
        let remoteApp = operatorListener.map {
            operatorApplication($0.host, $0.port, .remote($0.tokens, allowedOrigins: $0.allowedOrigins))
        }
        var submit: PublicSubmit?
        if publicSubmit {
            submit = { @Sendable request in try await runtime.submitPublicTransaction(request) }
        }
        let fetchLimit = PublicVolumeFetches.limit(
            requested: publicReadFetches, inFlightVolumeBytes: servingMaxInFlightVolumeBytes
        )
        let publicReadApp = publicReadPort.map { port in
            makePublicReadApplication(
                reads: runtime.reads,
                levelReads: { Array(runtime.levelReads.values) },
                host: "0.0.0.0",
                port: Int(port),
                peers: peers,
                limits: publicReadLimits,
                endpoints: { await runtime.chainEndpoints($0) },
                submit: submit,
                fetches: fetchLimit == 0 ? nil : PublicVolumeFetches(limit: fetchLimit) {
                    try await runtime.fetchVolume(
                        $0, maximumArchiveBytes: maximumCompleteVolumeArchiveBytes,
                        maximumEntries: maximumCompleteVolumeArchiveEntries
                    )
                }
            )
        }
        print("lattice-node (node runtime)")
        print("  storage: \(configuration.processPublicKey)")
        print("  nexus:   \(configuration.nexusGenesisCID)")
        print("  rpc:     http://\(rpcBind):\(rpcPort) (cookie: \(cookieFile.path))")
        if let publicReadPort {
            print("  public-read: http://0.0.0.0:\(publicReadPort)")
            if publicSubmit { print("  public-submit: POST /transactions on the public read port") }
            print("  public-read-fetches: \(fetchLimit) at once")
        }
        if let operatorListener {
            print("  operator: http://\(operatorListener.host):\(operatorListener.port) (bearer tokens, \(operatorListener.tokens.count) listed)")
        }
        let result: Result<Void, any Error>
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await app.runService() }
                if let publicReadApp { group.addTask { try await publicReadApp.runService() } }
                if let remoteApp { group.addTask { try await remoteApp.runService() } }
                group.addTask { await lifecycle.waitForRequest() }
                do {
                    _ = try await group.next()
                } catch {
                    group.cancelAll()
                    throw error
                }
                group.cancelAll()
            }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        await control.mining?.stop()
        await runtime.stop()
        try result.get()
        if lifecycle.restartRequested {
            print("restarting as asked")
            try? FileManager.default.removeItem(at: cookieFile)
            NodeLifecycle.reexec()
        }
    }
}
