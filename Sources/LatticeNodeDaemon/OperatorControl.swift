import ArgumentParser
import Foundation
import Hummingbird
import Lattice
import LatticeNode
import LatticeNodeAPI

enum OperatorConfigError: Error, CustomStringConvertible {
    /// The change is refused; nothing was written (400).
    case invalid(String)
    case notFound(String)
    /// The node was started with flags, not `--root` (409).
    case notOwned

    var description: String {
        switch self {
        case .invalid(let reason), .notFound(let reason): reason
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

/// The configuration of a node started with `--root`: `<root>/lattice.json`
/// and the fragments of `<root>/config.d`, merged (`MergedConfig`). The node
/// reads them at its start, again on SIGHUP, and after each change of a
/// fragment through its API, and converges to what they say: hosted chains
/// and their peers at once, every other key at its next start (reported as
/// pending a restart). It writes the fragments it is sent, and never
/// lattice.json. Changes are applied one at a time, in arrival order.
actor OperatorConfig {
    let layout: HostLayout
    /// What this process started with: a key that differs from it and takes
    /// a restart is reported as pending one.
    let started: Topology
    private(set) var desired: MergedConfig
    /// The listed chains that did not start, and why.
    private var failures: [String: String]
    /// What else does not match, by what it concerns (`reload`, a listener).
    private var problems: [String: String] = [:]
    private var appliedPeers: [String: [String]]
    private let runtime: any HostingRuntime
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(
        layout: HostLayout, desired: MergedConfig, started: Topology,
        failures: [String: String] = [:], runtime: any HostingRuntime
    ) {
        self.layout = layout
        self.desired = desired
        self.started = started
        self.failures = failures
        self.appliedPeers = Self.childPeers(started)
        self.runtime = runtime
    }

    var desiredChains: [String] { desired.topology.hostedChains ?? [] }

    func current() throws -> ConfigResponse {
        let running = Set(runtime.hostedChildren.map { $0.joined(separator: "/") })
        let depth = { (path: String) in path.split(separator: "/").count }
        let listed = desired.declaredBy.keys.sorted { (depth($0), $0) < (depth($1), $1) }
        var chains = listed.map { path in
            ConfigStatus.Chain(
                path: path, from: desired.declaredBy[path] ?? [],
                actual: running.contains(path) ? "hosted" : "notHosted",
                error: desired.chainErrors[path] ?? failures[path]
            )
        }
        for path in running.subtracting(listed).sorted() {
            chains.append(ConfigStatus.Chain(path: path, from: [], actual: "hosted", error: "no layer lists it, and it did not stop"))
        }
        return ConfigResponse(
            spec: desired.topology, fragments: desired.layers,
            status: ConfigStatus(
                chains: chains, pendingRestart: try desired.topology.restartRequired(comparedTo: started),
                errors: problems.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            )
        )
    }

    /// A layer's file as it is: a fragment, or lattice.json as `lattice`.
    func fragment(_ name: String) throws -> Data {
        let file = name == ConfigFragments.baseName
            ? layout.root.appendingPathComponent(Topology.fileName)
            : ConfigFragments.file(root: layout.root, name: name)
        guard ConfigFragments.isValidName(name) || name == ConfigFragments.baseName,
              let data = try? Data(contentsOf: file) else {
            throw OperatorConfigError.notFound("no fragment \(name)")
        }
        return data
    }

    /// Replaces the fragment `name` with `data` (one JSON object), once the
    /// configuration it makes checks as a start would check it. A `remote`
    /// client may not name a file on this node's disk (`operatorTokens`).
    func put(_ name: String, _ data: Data, remote: Bool) async throws -> ConfigResponse {
        guard ConfigFragments.isValidName(name) else {
            throw OperatorConfigError.invalid(name == ConfigFragments.baseName
                ? "\(Topology.fileName) is not written through the API; a fragment of \(ConfigFragments.directoryName) is"
                : "a fragment's name is lowercase letters, digits, ., _ and -, starting with a letter or digit")
        }
        let object: [String: Any]
        do {
            object = try ConfigFragments.object(data, named: name)
        } catch {
            throw OperatorConfigError.invalid("\(error)")
        }
        return try await serially {
            try change(name, to: object, remote: remote)
            try writeDurably(data, to: ConfigFragments.file(root: layout.root, name: name))
            await converge()
            return try current()
        }
    }

    /// Removes the fragment `name`, once the configuration left checks.
    func delete(_ name: String, remote: Bool) async throws -> ConfigResponse {
        try await serially {
            let file = ConfigFragments.file(root: layout.root, name: name)
            guard ConfigFragments.isValidName(name), FileManager.default.fileExists(atPath: file.path) else {
                throw OperatorConfigError.notFound("no fragment \(name)")
            }
            try change(name, to: nil, remote: remote)
            try FileManager.default.removeItem(at: file)
            await converge()
            return try current()
        }
    }

    /// Reads every layer again (SIGHUP). A configuration that does not
    /// check is not used, and reported, until one does.
    func reload() async {
        await serially {
            do {
                desired = try MergedConfig.load(root: layout.root)
                problems["reload"] = nil
            } catch {
                problems["reload"] = "\(error)"
                logLine("configuration not reloaded: \(error)")
                return
            }
            await converge()
        }
    }

    /// Something the configuration names that the node could not do, kept
    /// for its status.
    func report(_ key: String, _ problem: String) {
        problems[key] = problem
    }

    /// Refuses a restart the configuration on disk would not survive: a
    /// node that cannot start is out of reach of this API.
    func checkRestart() throws {
        do {
            try checkPlan(try MergedConfig.load(root: layout.root).topology)
        } catch {
            throw OperatorConfigError.invalid("the configuration would not start the node: \(error); fix it before restarting")
        }
    }

    /// The configuration with fragment `name` as `object` (nil: without
    /// it), made the desired one once it checks.
    private func change(_ name: String, to object: [String: Any]?, remote: Bool) throws {
        let next: MergedConfig
        do {
            next = try MergedConfig.merge(ConfigFragments.layers(root: layout.root, replacing: name, with: object))
            try checkPlan(next.topology)
        } catch {
            throw OperatorConfigError.invalid("\(error)")
        }
        if remote, next.topology.operatorTokens != desired.topology.operatorTokens {
            throw OperatorConfigError.invalid("the operator listener takes no file paths: operatorTokens is set beside the node")
        }
        desired = next
    }

    /// Whether `topology` would start the node: its flags parse and pass the
    /// start's own checks.
    private func checkPlan(_ topology: Topology) throws {
        _ = try LatticeNodeCommand.parse(topology.nodeArguments(layout: layout)).plan()
    }

    private func serially<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
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

    /// Hosts what `desired` lists: a chain it creates is created first (its
    /// files under `specs/`), and one that does not start is reported, with
    /// its children.
    private func converge() async {
        let running = Set(runtime.hostedChildren.map { $0.joined(separator: "/") })
        var prepared = prepareCreates(desired, layout: layout) { path in
            // A chain followed from its peers is not created again here.
            running.contains(path) && !FileManager.default.fileExists(atPath: layout.childSpec(for: path).path)
        }
        let target = desired.topology.removingChains(Set(prepared.failures.keys))
        let peers = Self.childPeers(target)
        defer { failures = prepared.failures }
        guard Set(target.hostedChains ?? []) != running || peers != appliedPeers else { return }
        var reason: String?
        do {
            let files = HostedChainFiles(layout, target)
            try await runtime.host(HostedChildren(
                hostChain: files.hostChain, premineTo: files.premineTo, genesisTransactions: files.genesisTransactions,
                chainPeer: files.chainPeer, policyModule: files.policyModule
            ))
            appliedPeers = peers
        } catch {
            reason = "\(error)"
        }
        let now = Set(runtime.hostedChildren.map { $0.joined(separator: "/") })
        for path in target.hostedChains ?? [] where !now.contains(path) {
            prepared.failures[path] = reason ?? "did not start"
            prepared.created.first { $0.path == path }?.remove()
        }
    }

    private static func childPeers(_ topology: Topology) -> [String: [String]] {
        (topology.peers?.byChain ?? [:]).filter { $0.key != ChainAddress.nexus }
    }
}

/// Writes the files of each chain `merged` creates that is not created yet
/// (`specs/`). A chain whose files are refused is not hosted, nor are its
/// children; nor is a chain `skip` names (refused with the reason it gives).
func prepareCreates(
    _ merged: MergedConfig, layout: HostLayout, skip: (String) -> Bool = { _ in false }
) -> (failures: [String: String], created: [ChainFiles]) {
    var failures: [String: String] = [:]
    var created: [ChainFiles] = []
    for path in merged.topology.hostedChains ?? [] {
        if let parent = ChainAddress(string: path)?.parent?.key, failures[parent] != nil {
            failures[path] = "waiting for \(parent), which is not hosted"
            continue
        }
        guard let chain = merged.creates[path] else { continue }
        if skip(path) {
            failures[path] = "\(path) is hosted as an existing chain, synced from its peers; it takes no spec"
            continue
        }
        do {
            if let files = try prepareChain(chain, layout: layout) {
                try files.write()
                created.append(files)
            }
        } catch {
            failures[path] = "\(error)"
        }
    }
    return (failures, created)
}

/// A new chain's inline spec, premine recipient, genesis transactions
/// and modules, checked as `lattice child create` checks them, as the
/// files `specs/` keeps; nil when the chain was created with exactly
/// these. A chain is created once: anything else for it is refused.
func prepareChain(_ chain: HostedChain, layout: HostLayout) throws -> ChainFiles? {
    guard let spec = chain.spec else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let specData = try encoder.encode(spec)
    let specFile = layout.childSpec(for: chain.path)
    let premineFile = layout.premineRecipient(for: chain.path)
    let genesisFile = layout.genesisTransactions(for: chain.path)
    let genesisData = try chain.genesisTransactions.map { try encoder.encode($0) }
    if let existing = try? Data(contentsOf: specFile) {
        // Modules are named by CID in the spec: the same spec, the same modules.
        let sameSpec = (try? encoder.encode(JSONDecoder().decode(ChainSpec.self, from: existing))) == specData
        let premine = (try? String(contentsOf: premineFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let genesis = (try? Data(contentsOf: genesisFile)).flatMap {
            try? encoder.encode(JSONDecoder().decode([SubmitTransactionRequest].self, from: $0))
        }
        guard sameSpec, premine == chain.premineTo, genesis == genesisData else {
            throw CtlError(
                "\(chain.path) already exists with another spec, premine recipient or genesis transactions; a child chain is created once"
            )
        }
        return nil
    }
    var modules: [String: Data] = [:]
    for bytes in chain.policyModules ?? [] {
        let cid = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: bytes)).rawCID
        let policies = spec.wasmPolicies.filter { $0.moduleCID == cid }
        guard !policies.isEmpty else {
            throw CtlError("module \(cid) is not named by the spec's wasmPolicies")
        }
        for policy in policies {
            do {
                try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: bytes)
            } catch {
                throw CtlError("module \(cid) is not valid for policy \(policy.entrypoint): \(error)")
            }
        }
        modules[cid] = bytes
    }
    if let missing = spec.wasmPolicies.map(\.moduleCID).first(where: { modules[$0] == nil }) {
        throw CtlError("the spec names policy module \(missing); send it in policyModules")
    }
    do {
        try NodeRuntime.checkPremine(
            spec: spec, to: chain.premineTo, transactions: (chain.genesisTransactions ?? []).map(\.transaction),
            on: chain.path.split(separator: "/").map(String.init), modules: Array(modules.values)
        )
    } catch {
        throw CtlError("\(chain.path): \(error)")
    }
    var files: [(URL, Data)] = []
    if let premineTo = chain.premineTo { files.append((premineFile, Data(premineTo.utf8))) }
    if let genesisData { files.append((genesisFile, genesisData)) }
    let directory = layout.policyModules(for: chain.path)
    for (cid, bytes) in modules.sorted(by: { $0.key < $1.key }) {
        files.append((directory.appendingPathComponent(cid + ".wasm"), bytes))
    }
    // The spec last: it marks the chain created, so it never stands
    // without what its genesis is built from.
    files.append((specFile, specData))
    return ChainFiles(path: chain.path, files: files, moduleDirectory: modules.isEmpty ? nil : directory)
}

/// A chain's files under `specs/`, written for a chain being created and
/// removed again when it is not kept.
struct ChainFiles: Sendable {
    let path: String
    let files: [(URL, Data)]
    let moduleDirectory: URL?

    func write() throws {
        for (file, data) in files { try writeDurably(data, to: file) }
    }

    /// The spec first: without it the chain counts as never created.
    func remove() {
        for (file, _) in files.reversed() { try? FileManager.default.removeItem(at: file) }
        if let moduleDirectory { try? FileManager.default.removeItem(at: moduleDirectory) }
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

/// The process's exit status asking whatever runs the node to start it
/// again (`POST /restart`, `POST /wipe`): sysexits' EX_TEMPFAIL.
let exitRestart: Int32 = 75

/// The process's exit status for a configuration it cannot start from:
/// sysexits' EX_CONFIG. systemd is told not to retry it
/// (`RestartPreventExitStatus=78`); launchd and Docker retry it, throttled.
let exitConfigurationError: Int32 = 78

/// A stop asked for through the API: `POST /stop` (the process exits 0 and
/// stays stopped) or `POST /restart` and `POST /wipe` (it exits 75, and
/// whatever runs it starts it again). Either way the node first stops as it
/// would on SIGTERM. The node never starts itself.
final class NodeLifecycle: @unchecked Sendable {
    enum Request: Sendable { case stop, restart }

    private let lock = NSLock()
    private var request: Request?
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    /// What was asked for, if anything; the first request stands.
    var requested: Request? { lock.withLock { request } }

    /// Asks for `request`, recorded at once and begun after `delay` (so an
    /// answer saying so goes out first). False, and nothing changes, when a
    /// stop or restart was asked for already: the first request stands.
    /// `prepare` runs only for a request that will be recorded, before it is
    /// and before any other can be; if it throws, nothing is recorded.
    @discardableResult
    func ask(_ request: Request, after delay: Duration = .zero) -> Bool {
        ask(request, after: delay, prepare: {})
    }

    func ask(_ request: Request, after delay: Duration, prepare: () throws -> Void) rethrows -> Bool {
        let first = try lock.withLock { () -> Bool in
            guard self.request == nil else { return false }
            try prepare()
            self.request = request
            return true
        }
        guard first else { return false }
        Task { [continuation] in
            try? await Task.sleep(for: delay)
            continuation.yield()
            continuation.finish()
        }
        return true
    }

    /// Returns once a stop or restart is asked for.
    func waitForRequest() async {
        for await _ in stream { return }
    }
}

/// A node started with `--root`: its root, the configuration it started
/// from (`started`, the chains that could not be created left out), what
/// its layers say (`merged`), and the chains that could not be created.
struct NodeOwner: Sendable {
    let layout: HostLayout
    let started: Topology
    let merged: MergedConfig
    let failures: [String: String]
}

/// The operator surface beyond the chains' reads and writes: the node's
/// configuration (with `--root`), its tokens, log, disk, restart
/// and wipe. Each part is absent where the node has none.
struct OperatorControl: Sendable {
    var config: OperatorConfig?
    var tokens: TokenStore?
    var lifecycle: NodeLifecycle?
    var storagePath: URL?
    /// The node's recent output (`GET /logs`).
    var log: NodeLog?
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
    logLine("storage wiped as asked (\(directory.path)); identity and \(Topology.fileName) kept")
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
    // The child chains this node hosts, and those its configuration lists.
    router.get("hosted-chains") { request, context in
        let configured = await control.config?.desiredChains
        return try json(
            HostedChainsResponse(chains: service.hostedChildren.map { $0.joined(separator: "/") }, configured: configured),
            request: request, context: context
        )
    }
    router.get("config") { request, context in
        try await configChange(request: request, context: context) {
            guard let config = control.config else { throw OperatorConfigError.notOwned }
            return try await config.current()
        }
    }
    router.get("config/fragments/:name") { request, context in
        guard let config = control.config else { throw HTTPError(.conflict, message: OperatorConfigError.notOwned.description) }
        do {
            let data = try await config.fragment(context.parameters.get("name") ?? "")
            return Response(
                status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-store"],
                body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
            )
        } catch let error as OperatorConfigError {
            throw HTTPError(.notFound, message: error.description)
        }
    }
    router.put("config/fragments/:name") { request, context in
        if !remote { try requireLoopbackHost(request) }
        try requireJSON(request)
        let body = try await request.body.collect(upTo: context.maxUploadSize)
        let name = context.parameters.get("name") ?? ""
        return try await configChange(request: request, context: context) {
            guard let config = control.config else { throw OperatorConfigError.notOwned }
            return try await config.put(name, Data(buffer: body), remote: remote)
        }
    }
    router.delete("config/fragments/:name") { request, context in
        if !remote { try requireLoopbackHost(request) }
        let name = context.parameters.get("name") ?? ""
        return try await configChange(request: request, context: context) {
            guard let config = control.config else { throw OperatorConfigError.notOwned }
            return try await config.delete(name, remote: remote)
        }
    }
    router.get("logs") { request, context in
        // Only the node's own: a client that runs beside it keeps its log.
        if let name = request.uri.queryParameters["file"], name != "node" {
            throw HTTPError(.notFound, message: "no log \(name): the node serves its own output only")
        }
        guard let log = control.log else { throw HTTPError(.notFound) }
        let tail = request.uri.queryParameters["tail"].flatMap { Int($0) } ?? 200
        guard tail > 0 else { throw HTTPError(.badRequest, message: "tail is a positive number of lines") }
        return Response(
            status: .ok,
            headers: [.contentType: "text/plain; charset=utf-8", .cacheControl: "no-store"],
            body: ResponseBody(byteBuffer: ByteBuffer(string: log.tail(min(tail, NodeLog.maximumLines))))
        )
    }
    router.get("disk") { request, context in
        guard let storage = control.storagePath else { throw HTTPError(.notFound) }
        return try json(diskUsage(storage), request: request, context: context)
    }
    router.post("restart") { request, context in
        if !remote { try requireLoopbackHost(request) }
        guard let lifecycle = control.lifecycle else { throw HTTPError(.notFound) }
        try await checkRestart(control)
        // Answered first: the restart begins once this reply is on its way.
        guard lifecycle.ask(.restart, after: .milliseconds(200)) else {
            throw HTTPError(.conflict, message: "a stop or restart is already under way")
        }
        return try json(["restarting": true], request: request, context: context, status: .accepted)
    }
    router.post("stop") { request, context in
        if !remote { try requireLoopbackHost(request) }
        guard let lifecycle = control.lifecycle else { throw HTTPError(.notFound) }
        lifecycle.ask(.stop, after: .milliseconds(200))
        return try json(["stopping": true], request: request, context: context, status: .accepted)
    }
    router.post("wipe") { request, context in
        if !remote { try requireLoopbackHost(request) }
        guard let lifecycle = control.lifecycle, let layout = control.config?.layout else {
            throw HTTPError(.conflict, message: "a wipe needs a node started with --root, which keeps identity and configuration outside its storage")
        }
        // The wipe itself runs at the next start, before storage opens: once
        // a stop is under way that start may never come, so none is asked for.
        let underWay = "a stop or restart is already under way; ask for the wipe once the node is back"
        guard lifecycle.requested == nil else { throw HTTPError(.conflict, message: underWay) }
        try await checkRestart(control)
        // The marker is written only by the request that is recorded, so a
        // 409 always leaves no wipe pending, even with a stop in between.
        let asked = try lifecycle.ask(.restart, after: .milliseconds(200)) {
            try FileManager.default.createDirectory(at: layout.wipeRequest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: layout.wipeRequest)
        }
        guard asked else { throw HTTPError(.conflict, message: underWay) }
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

/// A restart the node would not come back from is refused (409).
private func checkRestart(_ control: OperatorControl) async throws {
    do {
        try await control.config?.checkRestart()
    } catch let error as OperatorConfigError {
        throw HTTPError(.conflict, message: error.description)
    }
}

private let noTokenFile = "no operator token file: set operatorListen and operatorTokens (then restart), or start with --operator-tokens"

/// A configuration read or change: 200 with its answer, or the refusal.
private func configChange<Value: Encodable & Sendable>(
    request: Request, context: BasicRequestContext, _ operation: () async throws -> Value
) async throws -> Response {
    do {
        return try json(try await operation(), request: request, context: context)
    } catch let error as OperatorConfigError {
        switch error {
        case .invalid(let reason): throw HTTPError(.badRequest, message: reason)
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
