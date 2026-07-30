import ArgumentParser
import Crypto
import Foundation
import Hummingbird
import Ivy
import Lattice
import LatticeNode
import UInt256

/// Match DiskBroker's default storage-age grace: a newly stored orphan that
/// misses one sweep is old enough to reclaim at the next.
let volumeMaintenanceIntervalNanoseconds: UInt64 = 600 * 1_000_000_000

func runVolumeMaintenance(
    everyNanoseconds interval: UInt64 = volumeMaintenanceIntervalNanoseconds,
    evict: @escaping @Sendable () async throws -> Void
) async {
    precondition(interval > 0)
    while !Task.isCancelled {
        do {
            try await Task.sleep(nanoseconds: interval)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        do {
            try await evict()
        } catch {
            FileHandle.standardError.write(Data(
                "lattice-node volume maintenance failed: \(error)\n".utf8
            ))
        }
    }
}

@main
struct LatticeNodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-node",
        abstract: "Run one Lattice chain process"
    )

    @Option(help: "Absolute slash-separated path, always beginning with Nexus")
    var chainPath = "Nexus"

    @Option(help: "Storage directory; defaults to ~/.lattice/chains/<chain-path>")
    var dataDirectory: String?

    @Option(help: "Process identity key file; created with mode 0600 when absent")
    var identityKey: String?

    @Option(help: "Same-chain overlay listen port")
    var listenPort: UInt16 = 4001

    @Option(help: "Private parent/child fact-plane listen port")
    var factListenPort: UInt16 = 4002

    @Option(help: "Loopback HTTP API port")
    var rpcPort: UInt16 = 8080

    @Option(help: "HTTP bind address; only loopback addresses are accepted")
    var rpcBind = "127.0.0.1"

    @Option(parsing: .upToNextOption, help: "Overlay peer as public-key@host:port")
    var peer: [String] = []

    @Option(help: "Immediate parent fact endpoint as public-key@host:port")
    var parent: String?

    @Option(help: "Minimum overlay peer-key work bits")
    var minimumPeerKeyBits = 0

    mutating func run() async throws {
        guard let address = ChainAddress(string: chainPath) else {
            throw ValidationError("--chain-path must be absolute and begin with Nexus")
        }
        guard ["127.0.0.1", "::1", "localhost"].contains(rpcBind.lowercased()) else {
            throw ValidationError("the unauthenticated HTTP API may bind only to loopback")
        }

        let storage = try storageURL(for: address)
        let keyURL = identityKey.map { URL(fileURLWithPath: $0) }
            ?? storage.appendingPathComponent("process.key")
        let privateKeyHex = try loadOrCreateIdentity(at: keyURL)
        let parentEndpoint = try parent.map(parseParentEndpoint)
        let overlayPeers = try peer.map(parsePeerEndpoint)

        let configuration = try NodeConfiguration(
            chainPath: address.components,
            storagePath: storage,
            privateKeyHex: privateKeyHex,
            listenPort: listenPort,
            factListenPort: factListenPort,
            rpcPort: rpcPort,
            bootstrapPeers: overlayPeers,
            parentEndpoint: parentEndpoint,
            minPeerKeyBits: minimumPeerKeyBits
        )

        let network = try NodeNetworkRuntime(configuration: configuration)
        let process = try await ChainProcess.open(configuration: configuration)
        let service = ChainService(
            process: process,
            childCandidateProvider: { [weak network] context in
                guard let network else { return [] }
                return await network.directChildCandidates(context)
            },
            childCandidateReservationReconciler: { [weak network] update in
                guard let network else {
                    return update.reservations.isEmpty
                        && update.handoffs.isEmpty
                }
                return await network.reconcileChildCandidateReservations(
                    update
                )
            },
            childProofPublisher: { [weak network] publication in
                guard let network else { throw CancellationError() }
                _ = try await network.publishChildProof(
                    publication.proof,
                    childDirectory: publication.directory,
                    childCID: publication.childCID
                )
            },
            acceptedBlockPublisher: { [weak network] blockCID in
                guard let network else { throw CancellationError() }
                try await network.publishAcceptedBlock(blockCID)
            },
            acceptedTransactionPublisher: { [weak network] rootCID in
                guard let network else { throw CancellationError() }
                try await network.publishTransaction(rootCID)
            }
        )
        try await service.restoreLocalTransactions()
        let handlers = NodeNetworkHandlers(
            childCandidateBuilder: { [weak service] context, parentContentSource in
                guard let service else { return nil }
                return try await service.miningCandidate(
                    parentCarrier: context.parentCarrier,
                    parentContentSource: parentContentSource,
                    rewards: context.rewards,
                    mode: context.mode
                )
            },
            candidateReservations: { [weak service] update in
                guard let service else { return false }
                return await service.replaceIssuedCandidateReservations(
                    update
                )
            },
            admission: { [weak service] admission in
                guard let service else { throw CancellationError() }
                return try await service.admitNetworkCandidate(
                    admission.header,
                    authenticatedChildPackage: admission.authenticatedChildPackage,
                    preparingChildDirectories: admission.preparingChildDirectories,
                    contentSource: admission.contentSource
                )
            },
            transaction: { [weak service] transaction in
                guard let service else { throw CancellationError() }
                return try await service.submitNetworkTransaction(transaction)
            },
            transactionInventory: { [weak service] in
                guard let service else { return [] }
                return await service.transactionInventoryRoots()
            }
        )
        try await network.start(process: process, handlers: handlers)
        let app = makeApplication(
            service: service,
            host: rpcBind,
            port: Int(rpcPort)
        )

        print("lattice-node \(address.key)")
        print("  process: \(configuration.processPublicKey)")
        print("  nexus:   \(configuration.nexusGenesisCID)")
        print("  rpc:     http://\(rpcBind):\(rpcPort)")

        let volumeMaintenance = Task {
            await runVolumeMaintenance {
                _ = try await process.evictUnretainedVolumes()
            }
        }
        do {
            try await app.runService()
        } catch {
            volumeMaintenance.cancel()
            await volumeMaintenance.value
            await network.stop()
            throw error
        }
        volumeMaintenance.cancel()
        await volumeMaintenance.value
        await network.stop()
    }

    private func storageURL(for address: ChainAddress) throws -> URL {
        var url: URL
        if let dataDirectory {
            url = URL(fileURLWithPath: dataDirectory)
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".lattice/chains", isDirectory: true)
            for component in address.components {
                url = url.appendingPathComponent(
                    storageComponent(component),
                    isDirectory: true
                )
            }
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func storageComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed)!
}

private func loadOrCreateIdentity(at url: URL) throws -> String {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: url.path) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw ValidationError("identity key permissions must not grant group or other access")
        }
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 64,
              Data(hex: value) != nil else {
            throw ValidationError("identity key must contain exactly 32 hexadecimal bytes")
        }
        return value.lowercased()
    }

    try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let key = Curve25519.Signing.PrivateKey()
    let value = key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    try Data((value + "\n").utf8).write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return value
}

private func parsePeerEndpoint(_ value: String) throws -> PeerEndpoint {
    let parsed = try parseEndpoint(value)
    return PeerEndpoint(publicKey: parsed.key, host: parsed.host, port: parsed.port)
}

private func parseParentEndpoint(_ value: String) throws -> ParentEndpoint {
    let parsed = try parseEndpoint(value)
    return ParentEndpoint(publicKey: parsed.key, host: parsed.host, port: parsed.port)
}

private func parseEndpoint(_ value: String) throws -> (key: String, host: String, port: UInt16) {
    guard let separator = value.firstIndex(of: "@"),
          separator != value.startIndex else {
        throw ValidationError("endpoint must use public-key@host:port")
    }
    let key = String(value[..<separator])
    let address = String(value[value.index(after: separator)...])
    guard let colon = address.lastIndex(of: ":"),
          let port = UInt16(address[address.index(after: colon)...]),
          port != 0 else {
        throw ValidationError("endpoint must use public-key@host:port")
    }
    var host = String(address[..<colon])
    if host.first == "[", host.last == "]" {
        host.removeFirst()
        host.removeLast()
    }
    guard !host.isEmpty else {
        throw ValidationError("endpoint host must be nonempty")
    }
    return (key, host, port)
}

func makeApplication(
    service: ChainService,
    host: String,
    port: Int
) -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router()

    router.get("health") { request, context in
        try json(await service.status(), request: request, context: context)
    }
    router.get("v1/status") { request, context in
        try json(await service.status(), request: request, context: context)
    }
    router.post("v1/transactions") { request, context in
        let input: SubmitTransactionRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.submitTransaction(input)
        }
    }
    router.post("v1/mining/templates") { request, context in
        let input: MiningTemplateRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.miningTemplate(input)
        }
    }
    router.post("v1/mining/work") { request, context in
        let input: SubmitWorkRequest = try await decode(request, context: context)
        return try await serviceCall(request: request, context: context) {
            try await service.submitWork(input)
        }
    }
    router.post("v1/children/intents") { request, context in
        let input: ChildDeployIntentRequest = try await decode(
            request,
            upTo: ChainServiceLimits.maximumChildIntentPayloadBytes
        )
        return try await serviceCall(request: request, context: context) {
            try await service.createChildDeployIntent(input)
        }
    }

    return Application(
        responder: router.buildResponder(),
        configuration: .init(address: .hostname(host, port: port))
    )
}

private func decode<Value: Decodable>(
    _ request: Request,
    upTo maximumBytes: Int
) async throws -> Value {
    do {
        let buffer = try await request.body.collect(upTo: maximumBytes)
        return try JSONDecoder().decode(
            Value.self,
            from: Data(buffer.readableBytesView)
        )
    } catch {
        throw HTTPError(.badRequest)
    }
}

private func decode<Value: Decodable, Context: RequestContext>(
    _ request: Request,
    context: Context
) async throws -> Value {
    do {
        return try await request.decode(as: Value.self, context: context)
    } catch {
        throw HTTPError(.badRequest)
    }
}

private func serviceCall<Value: Encodable, Context: RequestContext>(
    request: Request,
    context: Context,
    operation: () async throws -> Value
) async throws -> Response {
    do {
        return try json(
            try await operation(),
            request: request,
            context: context
        )
    } catch ChainServiceError.childIntentLimitReached {
        throw HTTPError(.tooManyRequests)
    } catch ChainServiceError.noDeploymentAvailable {
        throw HTTPError(.conflict)
    } catch ChainServiceError.mempoolUnavailable,
            ChainServiceError.parentUnavailable {
        throw HTTPError(.serviceUnavailable)
    } catch is ChainServiceError {
        throw HTTPError(.badRequest)
    } catch TransactionPoolError.full {
        throw HTTPError(.tooManyRequests)
    } catch is TransactionPoolError {
        throw HTTPError(.badRequest)
    } catch is MiningTemplateError {
        throw HTTPError(.badRequest)
    } catch ChainProcessError.chainNotBootstrapped {
        throw HTTPError(.conflict)
    }
}

private func json<Value: Encodable, Context: RequestContext>(
    _ value: Value,
    request: Request,
    context: Context
) throws -> Response {
    try context.responseEncoder.encode(value, from: request, context: context)
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }
}
