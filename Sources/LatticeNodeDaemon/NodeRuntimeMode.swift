import ArgumentParser
import Foundation
import Hummingbird
import LatticeNode
import LatticeNodeCore
import LatticeNodeAPI
import ServiceLifecycle

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
                status: { await runtime.status(chainPath: $0) },
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
        // One group runs the listeners. SIGTERM, SIGINT and a stop or
        // restart asked through the API each shut it down gracefully: every
        // connection a listener accepted is served and closed. Cancelled
        // instead, a listener drops the connections it accepted but had not
        // taken up yet, and NIO traps on their unfinished writers.
        let listeners = Listeners(
            required: [app] + (publicReadApp.map { [$0] } ?? []),
            remote: remoteApp
        ) { error in
            guard let operatorListener else { return }
            let problem = "\(operatorListener.host):\(operatorListener.port) did not open: \(error)"
            logLine("operator listener \(problem)")
            await config?.report("operatorListen", problem)
        }
        var listening = ServiceGroupConfiguration(
            services: [.init(service: listeners)], gracefulShutdownSignals: [.sigterm, .sigint], logger: app.logger
        )
        // A client that stalls mid-request, or stops reading its answer,
        // would hold the drain open: past this the listeners are cancelled.
        // By then each has stopped accepting and taken up every connection
        // it accepted, whose handlers close (and finish) them on
        // cancellation. Under the 90 s a process manager gives a stop
        // (systemd's TimeoutStopSec, Fly's kill_timeout).
        listening.maximumGracefulShutdownDuration = .seconds(30)
        let group = ServiceGroup(configuration: listening)
        logLine(String(format: "lattice-node: serving, %.3f s after process start", Date().timeIntervalSince(processStartTime)))
        let result: Result<Void, any Error>
        do {
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                tasks.addTask {
                    await lifecycle.waitForRequest()
                    await group.triggerGracefulShutdown()
                }
                try await group.run()
                tasks.cancelAll()
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

/// The node's HTTP listeners as one service, so that a graceful shutdown
/// reaches all of them at once (a service group shuts its services down one
/// after another, and its cap would cancel those not yet asked). The remote
/// operator listener, when it cannot open (its port taken), is reported, not
/// fatal: the node stays reachable on loopback to fix it.
private struct Listeners: Service {
    let required: [any Service]
    let remote: (any Service)?
    let reportRemote: @Sendable (any Error) async -> Void

    func run() async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for listener in required {
                    group.addTask { try await listener.run() }
                }
                if let remote {
                    group.addTask {
                        do {
                            try await remote.run()
                        } catch where !Task.isCancelled {
                            await reportRemote(error)
                        }
                    }
                }
                try await group.waitForAll()
            }
        } catch where Task.isShuttingDownGracefully {
            // Cancelled at the shutdown cap: a listener can end with an error
            // then (Hummingbird's own service group reports its date cache
            // as finished unexpectedly), which is no failure to serve.
        }
    }
}
