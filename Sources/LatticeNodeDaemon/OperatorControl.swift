import ArgumentParser
import Foundation
import Hummingbird
import Lattice
import LatticeCtlCore
import LatticeNode
import LatticeNodeAPI

enum OperatorConfigError: Error, CustomStringConvertible {
    /// The change is refused; nothing was applied (400).
    case invalid(String)
    /// The change does not fit what the node keeps now (409).
    case conflict(String)
    case notFound(String)
    /// The node was started with flags, not `--root` (409).
    case notOwned

    var description: String {
        switch self {
        case .invalid(let reason), .conflict(let reason), .notFound(let reason): reason
        case .notOwned: "this node was started with flags, not --root: its configuration is its command line"
        }
    }
}

/// What a configuration change applies to while the node runs: its hosted
/// child chains (with their specs, seeds and modules).
protocol HostingRuntime: Sendable {
    func host(_ hosted: HostedChildren) async throws
    var hostedChildren: [[String]] { get }
}

/// What turns mining on and off as the configuration says.
protocol MiningControl: Sendable {
    func check(_ mine: TopologyMine?) throws
    func apply(_ mine: TopologyMine?) async
}

extension MinerSupervisor: MiningControl {
    nonisolated func check(_ mine: TopologyMine?) throws { try Self.check(mine) }
}

/// The node's one configuration, `<root>/lattice.json`, which a node started
/// with `--root` read at its start and alone writes while it runs (its
/// storage lock is held meanwhile; `lattice` edits the file only while the
/// node is stopped).
///
/// Every change is applied one at a time, in arrival order: checked as a
/// whole (as a start would check it), then what applies live is applied
/// (hosted chains, their peers, mining), then the file is written to say
/// what took effect, a chain that did not start left out of it, then the
/// change is answered. Every other key is kept for the next start and
/// reported as waiting for a restart.
actor OperatorConfig {
    let layout: HostLayout
    /// What this process started with: the keys that differ from it and take
    /// a restart are reported as waiting for one.
    let started: Topology
    private(set) var saved: Topology
    private let runtime: any HostingRuntime
    private let mining: any MiningControl
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(layout: HostLayout, started: Topology, runtime: any HostingRuntime, mining: any MiningControl) {
        self.layout = layout
        self.started = started
        self.saved = started
        self.runtime = runtime
        self.mining = mining
    }

    func current() throws -> ConfigResponse {
        ConfigResponse(config: saved, restartRequired: try saved.restartRequired(comparedTo: started))
    }

    /// Applies an RFC 7396 merge patch of `lattice.json`. A `remote` client
    /// may not name files on this node's disk (`mine.worker`,
    /// `operatorTokens`).
    func patch(_ patch: Data, remote: Bool) async throws -> ConfigChangeResponse {
        try await serially {
            let next: Topology
            do {
                next = try saved.applying(mergePatch: patch)
            } catch {
                throw OperatorConfigError.invalid("\(error)")
            }
            if remote, next.mine?.worker != saved.mine?.worker || next.operatorTokens != saved.operatorTokens {
                throw OperatorConfigError.invalid("the operator listener takes no file paths: mine.worker and operatorTokens are set beside the node")
            }
            return try await apply(next)
        }
    }

    /// Hosts `chain`, creating it from its inline spec (kept under `specs/`
    /// as `lattice child create` keeps one) when it has one. Repeating a
    /// request that took effect changes nothing.
    func host(_ chain: HostedChain) async throws -> ConfigChangeResponse {
        try await serially {
            guard let address = ChainAddress(string: chain.path), address.key == chain.path, !address.isNexus else {
                throw OperatorConfigError.invalid("\(chain.path) is not a child chain's path")
            }
            if chain.spec != nil {
                try writeSpec(chain)
            } else if chain.premineTo != nil || chain.genesisTransactions != nil || chain.policyModules != nil {
                throw OperatorConfigError.invalid("premineTo, genesisTransactions and policyModules come with a spec")
            }
            var next = saved
            if !(next.hostedChains ?? []).contains(chain.path) {
                next.hostedChains = (next.hostedChains ?? []) + [chain.path]
            }
            return try await apply(next)
        }
    }

    /// Stops hosting `path`, and with it its peers, mining recipient and
    /// minimum work. Its data and spec stay. A chain whose children are
    /// hosted is refused: unhost them first.
    func unhost(_ path: String) async throws -> ConfigChangeResponse {
        try await serially {
            let hosted = saved.hostedChains ?? []
            guard hosted.contains(path) else { throw OperatorConfigError.notFound("\(path) is not hosted") }
            if let child = hosted.first(where: { $0.hasPrefix(path + "/") }) {
                throw OperatorConfigError.conflict("\(child) is hosted under \(path); unhost it first")
            }
            return try await apply(saved.removingChains([path]))
        }
    }

    private func serially<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
        }
        return try await body()
    }

    private func apply(_ proposed: Topology) async throws -> ConfigChangeResponse {
        try requireUnedited()
        let next: Topology
        let hosted: HostedChildren
        do {
            next = try proposed.validated()
            try mining.check(next.mine)
            let files = HostedChainFiles(layout, next)
            hosted = try HostedChildren(
                hostChain: files.hostChain, premineTo: files.premineTo, genesisTransactions: files.genesisTransactions,
                chainPeer: files.chainPeer, policyModule: files.policyModule
            )
        } catch let error as OperatorConfigError {
            throw error
        } catch {
            throw OperatorConfigError.invalid("\(error)")
        }
        var effective = next
        var failed: [ConfigFailure] = []
        if next.hostedChains ?? [] != saved.hostedChains ?? [] || childPeers(next) != childPeers(saved) {
            var reason: String?
            do {
                try await runtime.host(hosted)
            } catch {
                reason = "\(error)"
            }
            let running = Set(runtime.hostedChildren.map { $0.joined(separator: "/") })
            let missing = (next.hostedChains ?? []).filter { !running.contains($0) }
            if !missing.isEmpty {
                effective = next.removingChains(Set(missing))
                failed += missing.map { ConfigFailure(key: "hostedChains", chain: $0, error: reason ?? "did not start") }
            } else if let reason {
                failed.append(ConfigFailure(key: "hostedChains", error: reason))
            }
        }
        let changed = try effective.changedKeys(from: saved)
        if changed.contains("mine") { await mining.apply(effective.mine) }
        if !changed.isEmpty {
            try effective.save(root: layout.root)
            saved = effective
        }
        return ConfigChangeResponse(
            config: saved,
            applied: changed.filter { Topology.liveKeys.contains($0) },
            failed: failed,
            restartRequired: try saved.restartRequired(comparedTo: started)
        )
    }

    private func childPeers(_ topology: Topology) -> [String: [String]] {
        (topology.peers?.byChain ?? [:]).filter { $0.key != ChainAddress.nexus }
    }

    /// The file is the node's while it runs: one edited by hand meanwhile
    /// would be overwritten, so the change is refused instead.
    private func requireUnedited() throws {
        let onDisk = try? Topology.load(root: layout.root).canonicalData()
        guard onDisk == (try saved.canonicalData()) else {
            throw OperatorConfigError.conflict(
                "\(Topology.fileName) was changed on disk while the node runs; `lattice restart` to load it, or undo the edit"
            )
        }
    }

    /// Keeps a chain's inline spec, premine recipient, genesis transactions
    /// and modules under `specs/`, checked first as `lattice child create`
    /// checks them. A chain is created once: the same spec again is kept as
    /// it is, a different one refused.
    private func writeSpec(_ chain: HostedChain) throws {
        guard let spec = chain.spec else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let specData = try encoder.encode(spec)
        let file = layout.childSpec(for: chain.path)
        if let existing = try? Data(contentsOf: file) {
            let decoded = try? encoder.encode(JSONDecoder().decode(ChainSpec.self, from: existing))
            guard decoded == specData else {
                throw OperatorConfigError.conflict("\(chain.path) already exists with another spec; a child chain is created once")
            }
            return
        }
        var modules: [String: Data] = [:]
        for bytes in chain.policyModules ?? [] {
            let cid = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: bytes)).rawCID
            let policies = spec.wasmPolicies.filter { $0.moduleCID == cid }
            guard !policies.isEmpty else {
                throw OperatorConfigError.invalid("module \(cid) is not named by the spec's wasmPolicies")
            }
            for policy in policies {
                do {
                    try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: bytes)
                } catch {
                    throw OperatorConfigError.invalid("module \(cid) is not valid for policy \(policy.entrypoint): \(error)")
                }
            }
            modules[cid] = bytes
        }
        if let missing = spec.wasmPolicies.map(\.moduleCID).first(where: { modules[$0] == nil }) {
            throw OperatorConfigError.invalid("the spec names policy module \(missing); send it in policyModules")
        }
        do {
            try NodeRuntime.checkPremine(
                spec: spec, to: chain.premineTo, transactions: (chain.genesisTransactions ?? []).map(\.transaction),
                on: chain.path.split(separator: "/").map(String.init), modules: Array(modules.values)
            )
        } catch {
            throw OperatorConfigError.invalid("\(chain.path): \(error)")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The spec last: it marks the chain created, so it never stands
        // without what its genesis is built from.
        if let premineTo = chain.premineTo {
            try Data(premineTo.utf8).write(to: layout.premineRecipient(for: chain.path), options: .atomic)
        }
        if let transactions = chain.genesisTransactions {
            try JSONEncoder().encode(transactions).write(to: layout.genesisTransactions(for: chain.path), options: .atomic)
        }
        if !modules.isEmpty {
            let directory = layout.policyModules(for: chain.path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (cid, bytes) in modules {
                try bytes.write(to: directory.appendingPathComponent(cid + ".wasm"), options: .atomic)
            }
        }
        try specData.write(to: file, options: .atomic)
    }
}

extension NodeRuntime: HostingRuntime {
    func host(_ hosted: HostedChildren) async throws {
        try await host(
            hosted.children, childSpecs: hosted.specs, childPremineRecipients: hosted.premineRecipients,
            childGenesisTransactions: hosted.genesisTransactions,
            childSeedPeers: hosted.seedPeers, policyModules: hosted.policyModules
        )
    }
}

/// A restart asked for through the API (`POST /restart`, `POST /wipe`):
/// the node stops as it would on SIGTERM, then runs its own binary again
/// with the same arguments in the same process (exec), so whatever
/// supervises it sees no exit and no new pid.
final class NodeLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    var restartRequested: Bool { lock.withLock { requested } }

    func requestRestart() {
        lock.withLock { requested = true }
        continuation.yield()
        continuation.finish()
    }

    /// Returns once a restart is asked for.
    func waitForRequest() async {
        for await _ in stream { return }
    }

    /// Replaces this process with its own binary, run with the same
    /// arguments. Every descriptor but the standard three is closed on the
    /// way, so the new image finds its ports, storage lock and files free.
    static func reexec() -> Never {
        fflush(stdout)
        fflush(stderr)
        let directory = FileManager.default.fileExists(atPath: "/proc/self/fd") ? "/proc/self/fd" : "/dev/fd"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            if let fd = Int32(name), fd > 2 { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        }
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        execv(path, argv)
        print("restart failed: exec \(path): \(String(cString: strerror(errno)))")
        exit(1)
    }
}

/// The operator surface beyond the chains' reads and writes: the node's
/// configuration (with `--root`), its tokens, mining, logs, disk, restart
/// and wipe. Each part is absent where the node has none.
struct OperatorControl: Sendable {
    var config: OperatorConfig?
    var tokens: TokenStore?
    var mining: MinerSupervisor?
    var lifecycle: NodeLifecycle?
    var storagePath: URL?
    /// The node's own log and the mining loop's, by name; known when the
    /// node runs under `--root` (where `lattice up` sends its output).
    var logs: [String: URL] = [:]
}

/// Wipes the storage a `POST /wipe` asked to wipe, before anything opens it:
/// the storage directory goes, identity and configuration stay.
func performRequestedWipe(_ layout: HostLayout) throws {
    let request = layout.wipeRequest
    guard FileManager.default.fileExists(atPath: request.path) else { return }
    let directory = layout.chainDirectory(for: ChainAddress.nexus)
    if FileManager.default.fileExists(atPath: directory.path) {
        let lock: StorageDirectoryLock
        do {
            lock = try StorageDirectoryLock(directory: directory)
        } catch StorageDirectoryLockError.alreadyLocked {
            throw ValidationError("a wipe was asked for, but \(directory.path) is in use by another node")
        }
        try FileManager.default.removeItem(at: directory)
        _ = lock
    }
    try FileManager.default.removeItem(at: request)
    print("storage wiped as asked (\(directory.path)); identity and \(Topology.fileName) kept")
}

/// The last `count` lines of `file`, read from at most its last 4 MiB.
func tailLines(_ file: URL, count: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let window: UInt64 = 4 << 20
    try handle.seek(toOffset: size > window ? size - window : 0)
    let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last == "" { lines.removeLast() }
    return lines.suffix(count).joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
}

/// Bytes on disk of each entry of `storage`, and its file system's free space.
func diskUsage(_ storage: URL) -> DiskResponse {
    let manager = FileManager.default
    func size(_ url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        let values = try? url.resourceValues(forKeys: keys)
        guard values?.isDirectory == true else {
            return UInt64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        var total: UInt64 = 0
        let walk = manager.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = walk?.nextObject() as? URL {
            let item = try? item.resourceValues(forKeys: keys)
            total += UInt64(item?.totalFileAllocatedSize ?? item?.fileAllocatedSize ?? 0)
        }
        return total
    }
    let entries = ((try? manager.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)) ?? [])
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    let stores = entries.map { DiskResponse.Store(name: $0.lastPathComponent, bytes: size($0)) }
    let free = (try? manager.attributesOfFileSystem(forPath: storage.path))?[.systemFreeSize] as? NSNumber
    return DiskResponse(
        storage: storage.path, stores: stores, totalBytes: stores.reduce(0) { $0 + $1.bytes },
        freeBytes: free?.uint64Value
    )
}

/// The operator control routes. On the remote listener (`remote`) a token
/// already allowed the route; only an `admin` token reaches `/tokens`.
func addOperatorControlRoutes(
    to router: Router<BasicRequestContext>,
    control: OperatorControl,
    writes service: any OperatorWrites,
    remote: Bool
) {
    // The child chains this node hosts, changed without a restart.
    router.get("hosted-chains") { request, context in
        let configured = await control.config?.saved.hostedChains
        return try json(
            HostedChainsResponse(
                chains: service.hostedChildren.map { $0.joined(separator: "/") },
                configured: control.config == nil ? nil : (configured ?? [])
            ),
            request: request, context: context
        )
    }
    router.post("hosted-chains") { request, context in
        if !remote { try requireLoopbackHost(request) }
        try requireJSON(request)
        let body = try await request.body.collect(upTo: context.maxUploadSize)
        let data = Data(buffer: body)
        let legacy = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["hostChain"] != nil
        guard let config = control.config else {
            // Started with flags: the whole set, as the flags name it, until
            // the next start.
            guard !remote else { throw HTTPError(.conflict, message: OperatorConfigError.notOwned.description) }
            guard let input = try? JSONDecoder().decode(HostedChainsRequest.self, from: data) else {
                throw HTTPError(.badRequest, message: "this node, started with flags, takes the chains as its flags name them (hostChain, premineTo, ...)")
            }
            return try await serviceCall(request: request, context: context) {
                try await service.hostChains(input)
                return HostedChainsResponse(chains: service.hostedChildren.map { $0.joined(separator: "/") }, configured: nil)
            }
        }
        guard !legacy else {
            throw HTTPError(.badRequest, message: "this node keeps its configuration: POST /hosted-chains hosts one chain ({path, spec, ...}) and PATCH /config sets hostedChains; update lattice")
        }
        guard let chain = try? JSONDecoder().decode(HostedChain.self, from: data) else {
            throw HTTPError(.badRequest, message: "send one chain: {path, spec?, premineTo?, genesisTransactions?, policyModules?}")
        }
        return try await configChange(request: request, context: context) { try await config.host(chain) }
    }
    router.delete("hosted-chains") { request, context in
        if !remote { try requireLoopbackHost(request) }
        guard let path = request.uri.queryParameters["chainPath"].map(String.init) else {
            throw HTTPError(.badRequest, message: "name the chain with ?chainPath=")
        }
        return try await configChange(request: request, context: context) {
            guard let config = control.config else { throw OperatorConfigError.notOwned }
            return try await config.unhost(path)
        }
    }
    router.get("config") { request, context in
        try await configChange(request: request, context: context) {
            guard let config = control.config else { throw OperatorConfigError.notOwned }
            return try await config.current()
        }
    }
    router.patch("config") { request, context in
        if !remote { try requireLoopbackHost(request) }
        let mediaType = request.headers[.contentType]?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard mediaType == "application/json" || mediaType == "application/merge-patch+json" else {
            throw HTTPError(.unsupportedMediaType, message: "Content-Type must be application/merge-patch+json or application/json")
        }
        let body = try await request.body.collect(upTo: context.maxUploadSize)
        return try await configChange(request: request, context: context) {
            guard let config = control.config else { throw OperatorConfigError.notOwned }
            return try await config.patch(Data(buffer: body), remote: remote)
        }
    }
    router.get("mining") { request, context in
        if let mining = control.mining { return try json(await mining.status(), request: request, context: context) }
        let mine = await control.config?.saved.mine
        return try json(
            MiningStatusResponse(enabled: false, running: false, pid: nil, restarts: 0, lastExit: nil, recipients: mine?.recipients ?? [:]),
            request: request, context: context
        )
    }
    router.get("logs") { request, context in
        let name = request.uri.queryParameters["file"].map(String.init) ?? "node"
        guard let file = control.logs[name], FileManager.default.fileExists(atPath: file.path) else {
            throw HTTPError(.notFound, message: control.logs.isEmpty
                ? "this node's log goes to its standard output (it was not started under --root)"
                : "no log \(name); there are \(control.logs.keys.sorted().joined(separator: ", "))")
        }
        let tail = request.uri.queryParameters["tail"].flatMap { Int($0) } ?? 200
        guard tail > 0 else { throw HTTPError(.badRequest, message: "tail is a positive number of lines") }
        return Response(
            status: .ok,
            headers: [.contentType: "text/plain; charset=utf-8", .cacheControl: "no-store"],
            body: ResponseBody(byteBuffer: ByteBuffer(string: try tailLines(file, count: min(tail, 10_000))))
        )
    }
    router.get("disk") { request, context in
        guard let storage = control.storagePath else { throw HTTPError(.notFound) }
        return try json(diskUsage(storage), request: request, context: context)
    }
    router.post("restart") { request, context in
        if !remote { try requireLoopbackHost(request) }
        guard let lifecycle = control.lifecycle else { throw HTTPError(.notFound) }
        Task {
            // Answered first: the restart begins once this reply is on its way.
            try? await Task.sleep(for: .milliseconds(200))
            lifecycle.requestRestart()
        }
        return try json(["restarting": true], request: request, context: context, status: .accepted)
    }
    router.post("wipe") { request, context in
        if !remote { try requireLoopbackHost(request) }
        guard let lifecycle = control.lifecycle, let layout = control.config?.layout else {
            throw HTTPError(.conflict, message: "a wipe needs a node started with --root, which keeps identity and configuration outside its storage")
        }
        try FileManager.default.createDirectory(at: layout.wipeRequest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: layout.wipeRequest)
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            lifecycle.requestRestart()
        }
        return try json(["restarting": true, "wiping": true], request: request, context: context, status: .accepted)
    }
    router.get("tokens") { request, context in
        guard let tokens = control.tokens else { throw HTTPError(.conflict, message: noTokenFile) }
        return try json(tokens.list(), request: request, context: context)
    }
    router.post("tokens") { request, context in
        guard let tokens = control.tokens else { throw HTTPError(.conflict, message: noTokenFile) }
        let input: CreateTokenRequest = try await decode(request, context: context, remote: remote)
        do {
            return try json(try tokens.create(input), request: request, context: context)
        } catch let error as ValidationError {
            throw HTTPError(.badRequest, message: error.message)
        }
    }
    router.delete("tokens/:name") { request, context in
        if !remote { try requireLoopbackHost(request) }
        guard let tokens = control.tokens else { throw HTTPError(.conflict, message: noTokenFile) }
        let name = context.parameters.get("name") ?? ""
        guard try tokens.revoke(name) else { throw HTTPError(.notFound, message: "no token named \(name)") }
        return try json(tokens.list(), request: request, context: context)
    }
}

private let noTokenFile = "no operator token file: set operatorListen and operatorTokens (then restart), or start with --operator-tokens"

/// A configuration change's answer: 200 when all of it took effect, 500
/// with the same body when a part failed (left out of what is kept).
private func configChange<Value: Encodable & Sendable>(
    request: Request, context: BasicRequestContext, _ operation: () async throws -> Value
) async throws -> Response {
    do {
        let value = try await operation()
        let failed = !((value as? ConfigChangeResponse)?.failed.isEmpty ?? true)
        return try json(value, request: request, context: context, status: failed ? .internalServerError : .ok)
    } catch let error as OperatorConfigError {
        switch error {
        case .invalid(let reason): throw HTTPError(.badRequest, message: reason)
        case .conflict(let reason): throw HTTPError(.conflict, message: reason)
        case .notFound(let reason): throw HTTPError(.notFound, message: reason)
        case .notOwned: throw HTTPError(.conflict, message: error.description)
        }
    }
}

private func json<Value: Encodable>(
    _ value: Value, request: Request, context: BasicRequestContext, status: HTTPResponse.Status
) throws -> Response {
    var response = try json(value, request: request, context: context)
    response.status = status
    return response
}
