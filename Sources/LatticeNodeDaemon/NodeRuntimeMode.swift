import ArgumentParser
import Foundation
import Hummingbird
import LatticeNode
import LatticeNodeCore
import LatticeNodeAPI

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
        owner: NodeOwner?,
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
        // Where this process listens, for the CLI on the same root: its
        // lattice.json may already say where the next start will.
        let rpcAddress = HostLayout.rpcAddress(storage: configuration.storagePath)
        let rpcHost = rpcBind.contains(":") ? "[\(rpcBind)]" : rpcBind
        try Data("http://\(rpcHost):\(rpcPort)\n".utf8).write(to: rpcAddress, options: .atomic)
        defer { try? FileManager.default.removeItem(at: rpcAddress) }
        let runtime = try await NodeRuntime.start(storage: storage, configuration: configuration)
        let peers: @Sendable () async -> ExplorerPeersResponse = {
            ExplorerPeersResponse(count: runtime.peerCount, peers: [])
        }
        // The operator's control of the node: restart always; under --root
        // its configuration, log and wipe.
        let lifecycle = NodeLifecycle()
        var control = OperatorControl(
            tokens: operatorListener?.tokens, lifecycle: lifecycle, storagePath: configuration.storagePath,
            log: nodeLog
        )
        if let owner {
            control.config = OperatorConfig(
                layout: owner.layout, desired: owner.merged, started: owner.merged.topology,
                runtime: runtime
            )
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
        logLine("lattice-node (node runtime)")
        logLine("  storage: \(configuration.processPublicKey)")
        logLine("  nexus:   \(configuration.nexusGenesisCID)")
        logLine("  rpc:     http://\(rpcBind):\(rpcPort) (cookie: \(cookieFile.path))")
        if let publicReadPort {
            logLine("  public-read: http://0.0.0.0:\(publicReadPort)")
            if publicSubmit { logLine("  public-submit: POST /transactions on the public read port") }
            logLine("  public-read-fetches: \(fetchLimit) at once")
        }
        if let operatorListener {
            logLine("  operator: http://\(operatorListener.host):\(operatorListener.port) (bearer tokens, \(operatorListener.tokens.count) listed)")
        }
        // SIGHUP: read the configuration again (as nginx and systemd do).
        let config = control.config
        if let config { Hangups.shared.onHangup { Task { await config.reload() } } }
        let result: Result<Void, any Error>
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await app.runService() }
                if let publicReadApp { group.addTask { try await publicReadApp.runService() } }
                if let remoteApp, let operatorListener {
                    // A remote listener that cannot open (its port taken) is
                    // reported, not fatal: the node stays reachable on
                    // loopback to fix it.
                    group.addTask {
                        do {
                            try await remoteApp.runService()
                        } catch where !Task.isCancelled {
                            let problem = "\(operatorListener.host):\(operatorListener.port) did not open: \(error)"
                            logLine("operator listener \(problem)")
                            await config?.report("operatorListen", problem)
                            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3_600)) }
                        }
                    }
                }
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
        await runtime.stop()
        try result.get()
        switch lifecycle.requested {
        case .restart:
            // Whatever runs the node starts it again on this status.
            logLine("stopped to restart (exit \(exitRestart))")
            throw ExitCode(exitRestart)
        case .stop:
            logLine("stopped as asked")
        case nil:
            break
        }
    }
}
