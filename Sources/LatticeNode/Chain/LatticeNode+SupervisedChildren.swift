import Foundation
import Lattice
import cashew
import LatticeNodeRPCFuzzSupport  // GenesisHexCodec/GenesisHexEntry (shared genesis-hex codec)
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession/URLRequest live here on Linux
#endif

// Contract 4 / Item 2 (supervised child lifecycle as a continuous reconciler).
// The child lifecycle is a durable state machine, reconciled on a loop — not a
// one-shot launcher:
//
//   DEPLOYED ─spawn─▶ RUNNING ─cookie+auth─▶ AUTHENTICATED ─register─▶ REGISTERED
//      ▲                  │                                                │
//      │            wedged > grace                          unregister-rpc │
//      │            (force restart)                                        ▼
//      └──────── re-deploy (clears detached) ◀──────────────────────── DETACHED
//
// The reconcile loop re-evaluates every non-detached deployed child each interval,
// so a child that is slow to bind RPC, hung, or that died after registration is
// eventually driven back to REGISTERED (or explicitly logged DEGRADED) without an
// operator. On a parent crash/restart a child may still be alive holding its ports,
// so each pass PROBES before spawning and adopts a live child rather than spawning a
// duplicate into occupied ports.
extension LatticeNode {

    /// Reconcile/auto-follow sweep cadence. Default 30s; overridable via env so a deep
    /// self-assembling tree (each level discovers its children one sweep after syncing)
    /// can converge faster in tests without waiting 30s per level. Inherited by spawned
    /// children (they share the supervisor's environment), so one override speeds the
    /// whole subtree.
    static var supervisedReconcileIntervalSeconds: UInt64 {
        if let s = ProcessInfo.processInfo.environment["LATTICE_SUPERVISE_RECONCILE_SECONDS"],
           let v = UInt64(s), v > 0 { return v }
        return 30
    }

    /// Hard bounds on RECURSIVE AUTO-FOLLOW. Child announcement is permissionless
    /// on-chain data (anyone who can land a GenesisAction can announce a child), and
    /// auto-follow turns each announcement into an OS process — recursively. Without
    /// caps, a single cheap stream of garbage announcements fork-bombs every
    /// supervising node (process/fd/disk/port exhaustion). These bound THIS node's
    /// resource use (not consensus), so they are applied identically at every level —
    /// still self-similar. Operator-overridable via env; explicit `chain follow` is
    /// NOT subject to these caps (it is an operator decision, not attacker-driven).
    static var maxAutoFollowedChildren: Int {
        if let s = ProcessInfo.processInfo.environment["LATTICE_MAX_SUPERVISED_CHILDREN"],
           let v = Int(s), v >= 0 { return v }
        return 64
    }
    static var maxAutoFollowDepth: Int {
        if let s = ProcessInfo.processInfo.environment["LATTICE_MAX_SUPERVISE_DEPTH"],
           let v = Int(s), v >= 1 { return v }
        return 8
    }
    /// Stop actively re-resolving an unresolvable announced genesis (garbage/withheld
    /// CID) after this many failed sweeps, so one bad announcement can't keep a hot
    /// fetch/pinner-discovery loop running forever. It drops to a slow re-probe.
    static let maxFollowedGenesisResolveAttempts = 10

    /// A child port for `basePort + slot`, kept in a valid non-privileged range even when
    /// `basePort` is high: `basePort &+ 1 &+ slot` can otherwise WRAP (e.g. base ~49k +
    /// slot ~16k > 65535) into a tiny/privileged port. Fold the slot into the headroom
    /// below 65535 so the result is always a usable port.
    func safeChildPort(basePort: UInt16, slot: UInt16) -> UInt16 {
        let headroom = basePort < 65534 ? UInt32(65534 - basePort) : 1
        let safeSlot = UInt16(UInt32(slot) % Swift.max(1, Swift.min(headroom, 0x4000)))
        return basePort &+ 1 &+ safeSlot
    }

    /// The base 14-bit port slot for a directory (mirrors `deterministicPort`'s FNV-1a).
    private func childPortSlot(_ directory: String) -> UInt16 {
        var h: UInt32 = 2166136261
        for byte in directory.utf8 { h = (h ^ UInt32(byte)) &* 16777619 }
        return UInt16(h & 0x3FFF)
    }

    /// The STABLE 14-bit port slot a managed child uses for both its RPC and P2P ports.
    /// FNV-1a over a 14-bit slot is not collision-resistant, so an attacker can grind an
    /// announced directory name to a victim's slot. The fix is NOT a cleverer hash (any
    /// 14-bit slot is grindable) but binding each child's slot to its OWN identity and
    /// PERSISTING it on first assignment: the slot is the deterministic base if free, else
    /// the next free slot, probed against EVERY already-assigned slot (so it never collides
    /// with another child — fixing both the original slot-denial and secondary collisions).
    /// Once assigned it is persisted and reused verbatim, so a later colliding announcement
    /// can never shift a running child's port — it just probes to a different free slot for
    /// the newcomer. No rank, no dependence on the mutable/attacker-grown sibling set.
    func assignChildPortSlot(key: String, metadata: DeployedChainMetadata) async -> UInt16 {
        if let s = metadata.portSlot { return s }
        // Reserve EVERY assigned slot (including detached children, so a re-follow reuses
        // its own slot and a freed slot isn't handed to a different child mid-life).
        let used = Set(deployedChildChains.values.compactMap { $0.portSlot })
        var slot = childPortSlot(metadata.directory)
        var probes = 0
        while used.contains(slot) && probes < 0x4000 {
            slot = (slot &+ 1) & 0x3FFF
            probes += 1
        }
        // Persist against the LIVE entry (a detach may have landed); skip if detached.
        if var live = deployedChildChains[key], !live.detached {
            live.portSlot = slot
            deployedChildChains[key] = live
            await persistDeployedChildChains()
        }
        return slot
    }
    /// How long a supervisor-tracked child may answer no RPC before we treat it as
    /// wedged (hung / never bound its RPC) and force a restart, rather than waiting
    /// forever on the supervisor — which only restarts on process *exit*.
    static let supervisedHealthGraceSeconds: TimeInterval = 90

    /// Outcome of a single reconcile pass for one child (for logging/cadence/tests).
    enum SupervisedChildState: Equatable {
        case detached       // operator-detached; intentionally not managed
        case registered     // alive, authenticated, RPC registered for delivery
        case booting        // tracked/launched, RPC not yet answering (within grace)
        case degraded       // alive but no cookie authenticates — manual recovery
        case recovering     // (re)spawned this pass; will register on a later pass
        case resolving      // followed child whose genesis isn't resolved/available yet; retry next sweep
    }

    /// Result of probing a child's authenticated `/chain/auth-check`.
    enum ChildProbeResult {
        case aliveAuthValid   // 200: child alive AND accepts the presented token
        case aliveAuthStale   // answered HTTP but rejected the token (401/403/other)
        case dead             // connection refused / timeout / no HTTP response
    }

    /// Probe a child RPC endpoint (stored API-base form, e.g. http://127.0.0.1:PORT/api).
    func probeChildEndpoint(_ endpoint: String, token: String?) async -> ChildProbeResult {
        guard let url = URL(string: endpoint + "/chain/auth-check") else { return .dead }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let session = RPCRoutes.childFanoutSession()
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .dead }
            switch http.statusCode {
            case 200: return .aliveAuthValid
            default: return .aliveAuthStale   // alive (answered HTTP) but token not accepted
            }
        } catch {
            return .dead
        }
    }

    /// Read a child's on-disk admin cookie (the token the running process accepts).
    private func readChildCookie(dataDir: String) -> String? {
        let path = URL(fileURLWithPath: dataDir).appendingPathComponent(".cookie")
        guard let token = try? String(contentsOf: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return token
    }

    /// One reconcile pass for a single child. Idempotent and quick: it probes, adopts a
    /// live child, force-restarts a wedged one past the health grace, or recovers a dead
    /// one. Returns the resulting state.
    @discardableResult
    func ensureSupervisedChild(_ metadata: DeployedChainMetadata) async -> SupervisedChildState {
        guard let supervisor = childSupervisor, let rpcBase = childRPCBasePort else { return .detached }

        let key = chainKey(forPath: metadata.chainPath)
        let dir = metadata.directory
        let parentPort = config.listenPort
        // Stable, persisted slot (see assignChildPortSlot): a child's RPC and P2P ports
        // derive from one slot it owns for life, so a colliding announcement can never
        // move a running child's port.
        let slot = await assignChildPortSlot(key: key, metadata: metadata)
        let childRPCPort = safeChildPort(basePort: rpcBase, slot: slot)
        let childPort = safeChildPort(basePort: parentPort, slot: slot)
        let endpoint = "http://127.0.0.1:\(childRPCPort)/api"
        let childDataDir = config.storagePath
            .appendingPathComponent("children").appendingPathComponent(dir).path
        let log = NodeLogger("supervisor")

        // The passed-in metadata is a reconcile SNAPSHOT and may be stale: an operator
        // `chain detach` can land while this pass is suspended on a probe/spawn/stop await,
        // setting detached and stopping the process. So the source of truth for "is this
        // child still managed?" is the LIVE dict, re-read after every await and before
        // every side effect — never the snapshot's own `detached`.
        func stillManaged() -> Bool { (deployedChildChains[key].map { !$0.detached }) ?? false }
        guard stillManaged() else { return .detached }

        let supervisorTracksLive = await supervisor.isRunning(dir)
        let persistedToken = registeredRPCAuthToken(chainPath: metadata.chainPath)
        let probe = await probeChildEndpoint(endpoint, token: persistedToken)
        // Detach may have landed during the probe — honor it before any side effect.
        guard stillManaged() else { supervisedRPCDownSince.removeValue(forKey: key); return .detached }

        switch probe {
        case .aliveAuthValid:
            // Live and our persisted token works — (re)register, clear any wedged timer.
            supervisedRPCDownSince.removeValue(forKey: key)
            registerRPCEndpoint(chainPath: metadata.chainPath, endpoint: endpoint, authToken: persistedToken)
            return .registered
        case .aliveAuthStale:
            // Alive on the port but our token is stale — the child rotated its cookie.
            // Adopt the on-disk cookie if it authenticates; never spawn into the live port.
            supervisedRPCDownSince.removeValue(forKey: key)
            if let fresh = readChildCookie(dataDir: childDataDir),
               await probeChildEndpoint(endpoint, token: fresh) == .aliveAuthValid {
                guard stillManaged() else { return .detached }   // detach during the re-probe
                registerRPCEndpoint(chainPath: metadata.chainPath, endpoint: endpoint, authToken: fresh)
                log.info("adopted live supervised child '\(dir)' with rotated cookie at \(endpoint)")
                return .registered
            }
            log.error("supervised child '\(dir)' is alive on \(endpoint) but no on-disk cookie authenticates (DEGRADED); manual recovery needed — not spawning into the occupied port")
            return .degraded
        case .dead:
            if supervisorTracksLive {
                // Tracked alive but RPC dead. The supervisor only restarts on process
                // EXIT, so a hung/slow-to-bind child would otherwise never recover.
                // Allow a health grace for RPC to come up, then force a restart.
                let now = Date()
                let downSince = supervisedRPCDownSince[key] ?? now
                supervisedRPCDownSince[key] = downSince
                if now.timeIntervalSince(downSince) < Self.supervisedHealthGraceSeconds {
                    log.info("supervised child '\(dir)' running but RPC not up yet (booting, within \(Int(Self.supervisedHealthGraceSeconds))s grace)")
                    return .booting
                }
                log.warn("supervised child '\(dir)' wedged (RPC dead > \(Int(Self.supervisedHealthGraceSeconds))s while process alive); forcing restart")
                await supervisor.stop(label: dir)
                guard stillManaged() else { supervisedRPCDownSince.removeValue(forKey: key); return .detached }
                supervisedRPCDownSince.removeValue(forKey: key)
                // fall through to a fresh spawn
            }
            // Provably dead (or just force-stopped) and the port is free — recover.
            supervisedRPCDownSince.removeValue(forKey: key)
            return await recoverDeadChild(metadata, key: key, dir: dir, childPort: childPort,
                                          childRPCPort: childRPCPort, endpoint: endpoint,
                                          childDataDir: childDataDir, supervisor: supervisor, log: log)
        }
    }

    /// Delete the stale cookie, spawn, and make a bounded attempt to register. If the
    /// child is slow to come up the reconcile loop registers it on a later pass.
    private func recoverDeadChild(
        _ metadata: DeployedChainMetadata, key: String, dir: String, childPort: UInt16, childRPCPort: UInt16,
        endpoint: String, childDataDir: String, supervisor: ChildProcessSupervisor, log: NodeLogger
    ) async -> SupervisedChildState {
        func stillManaged() -> Bool { (deployedChildChains[key].map { !$0.detached }) ?? false }
        // Re-check immediately before the destructive delete-cookie + spawn: a detach may
        // have landed since the caller's last check.
        guard stillManaged() else { return .detached }
        // A FOLLOWED child has no locally-built genesis — resolve it from the parent's on-chain
        // GenesisState + CAS before spawning (the spawn requires genesisHex). If the genesis
        // isn't available from pinners yet, stay in `resolving` and let the next sweep retry;
        // never spawn a child without its genesis. Deployed children already have genesisHex,
        // so this is skipped for them.
        var metadata = metadata
        if metadata.followed && metadata.genesisHex.isEmpty {
            // Bound resolve retries (#3): a garbage/withheld announced CID would otherwise
            // keep a hot fetch + pinner-discovery loop running every sweep forever. After
            // the attempt threshold, only re-probe every 10th sweep.
            let failures = followedGenesisResolveFailures[key] ?? 0
            let shouldAttempt = failures < Self.maxFollowedGenesisResolveAttempts || failures % 10 == 0
            guard shouldAttempt else {
                followedGenesisResolveFailures[key] = failures + 1
                return .resolving
            }
            guard let resolved = await resolveFollowedGenesis(metadata) else {
                followedGenesisResolveFailures[key] = failures + 1
                if failures + 1 == Self.maxFollowedGenesisResolveAttempts {
                    log.warn("supervised child '\(dir)' genesis unresolvable after \(failures + 1) attempts; slowing re-probe (announced CID may be garbage/withheld)")
                }
                return .resolving
            }
            followedGenesisResolveFailures.removeValue(forKey: key)  // resolved — reset
            guard stillManaged() else { return .detached }
            deployedChildChains[key] = resolved
            await persistDeployedChildChains()
            metadata = resolved
        }
        let cookiePath = URL(fileURLWithPath: childDataDir).appendingPathComponent(".cookie")
        try? FileManager.default.removeItem(at: cookiePath)
        // A followed child has no operator-supplied same-chain peer; it discovers
        // one via getChildPeers over the parent link. Passing the PARENT's endpoint
        // as the child's chain-gossip `--peer` would be a bogus cross-chain peer (a
        // Nexus node is not a Toy peer) that pollutes the Toy peer count and would
        // mask "I still need a same-chain peer". So leave it empty for followed
        // children; deployed children keep the existing parent bootstrap.
        let childBootstrapPeer = metadata.followed ? nil : "\(config.publicKey)@127.0.0.1:\(config.listenPort)"
        let spec = ChildSpec(
            directory: dir, chainPath: metadata.chainPath,
            genesisHex: metadata.genesisHex,
            subscribeP2P: "\(config.publicKey)@127.0.0.1:\(config.listenPort)",
            bootstrapPeer: childBootstrapPeer,
            port: childPort, rpcPort: childRPCPort,
            dataDir: childDataDir, inheritedArguments: childInheritedArguments
        )
        do {
            _ = try await supervisor.spawn(spec.launch(nodeExecutable: ChildProcessSupervisor.selfExecutableURL()))
            log.info("spawned supervised child '\(dir)' (p2p \(childPort), rpc \(childRPCPort))")
        } catch {
            log.error("supervised spawn of '\(dir)' failed: \(error)")
            return .recovering
        }
        // Detach may have raced the spawn — if so, stop the process we just launched so a
        // detached child is not left running, and do not register it.
        guard stillManaged() else {
            await supervisor.stop(label: dir)
            return .detached
        }
        // Bounded register attempt (~10s) for fresh-deploy snappiness; the reconcile
        // loop registers it later if the child is slower to bind RPC + write its cookie.
        for _ in 0..<40 {
            if Task.isCancelled { return .recovering }
            // Honor a detach landing mid-poll: stop the process and stop trying to register.
            guard stillManaged() else { await supervisor.stop(label: dir); return .detached }
            if let token = readChildCookie(dataDir: childDataDir),
               await probeChildEndpoint(endpoint, token: token) == .aliveAuthValid {
                guard stillManaged() else { await supervisor.stop(label: dir); return .detached }
                registerRPCEndpoint(chainPath: metadata.chainPath, endpoint: endpoint, authToken: token)
                log.info("registered supervised child '\(dir)' RPC \(endpoint) for mined-block delivery")
                return .registered
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        log.info("supervised child '\(dir)' spawned but not yet authenticated; reconcile loop will register it once its RPC is up")
        return .recovering
    }

    /// Self-similar recursive follow. A supervising node follows the children announced
    /// in ITS OWN chain's GenesisState — exactly as the root follows Nexus's children —
    /// so a whole subtree self-assembles with no chain treated specially. Each followed
    /// child is spawned with `--supervise-children` inherited (see NodeCommand), so it
    /// runs this same sweep for ITS children: one level per node, recursing process by
    /// process down `discover -> follow -> sync -> discover-deeper` until the leaves.
    ///
    /// Only brand-new announcements are followed: a child already managed (deployed,
    /// followed, or operator-detached) is left exactly as-is, so this never re-resolves
    /// a running child or un-detaches one an operator stopped.
    func autoFollowAnnouncedChildren() async {
        guard childSupervisor != nil else { return }
        let ownChainPath = config.fullChainPath ?? [genesisConfig.directory]
        let log = NodeLogger("supervise")
        // DEPTH CAP: stop the recursion from descending without bound. A node at/below
        // the cap still runs (and serves), it just doesn't AUTO-follow deeper — bounding
        // an adversarial deep announced chain. (Explicit `chain follow` is unaffected.)
        guard ownChainPath.count < Self.maxAutoFollowDepth else {
            log.warn("\(ownChainPath.joined(separator: "/")): at auto-follow depth cap (\(Self.maxAutoFollowDepth)); not following deeper")
            return
        }
        // SYNC GATE (the root fix): do NOT subscribe to (auto-follow + spawn) children until
        // THIS chain has established same-chain connectivity — a connected same-chain peer and
        // a tip past genesis. Spawning a child before the parent is connected hands the child a
        // parent-subscription to a not-yet-ready node that cannot route it to its own same-chain
        // peers, starving the deepest level. A connected parent is a stable rendezvous, so its
        // children discover reliably. (Live-safe: requires connectivity, not "caught up to an
        // exact tip" — which a perpetually-mining chain never durably is.)
        let ownDir = ownChainPath.last ?? genesisConfig.directory
        if await needsSameChainPeer(directory: ownDir) {
            log.info("\(ownChainPath.joined(separator: "/")): no same-chain connectivity yet; deferring child auto-follow until synced")
            return
        }
        let announced: [(directory: String, genesisHash: String)]
        do {
            announced = try await listChildChains(chainPath: ownChainPath)
        } catch {
            // Own tip / GenesisState not resolvable yet (e.g. this level hasn't synced).
            // Surface it so a silently-stalled middle level — which would strand its
            // whole subtree — is observable, not invisible. Retry next sweep.
            log.info("\(ownChainPath.joined(separator: "/")): children not enumerable yet (level not synced?); will retry")
            return
        }
        for child in announced {
            let childPath = ownChainPath + [child.directory]
            guard deployedChildChains[chainKey(forPath: childPath)] == nil else { continue }
            // TOTAL CAP: bound processes/disk regardless of how many children are
            // announced. Count live (non-detached) managed children. The excess is
            // logged and refused, never spawned — so a flood of announcements can't
            // exhaust the node.
            let managed = deployedChildChains.values.lazy.filter { !$0.detached }.count
            guard managed < Self.maxAutoFollowedChildren else {
                log.warn("\(ownChainPath.joined(separator: "/")): auto-follow cap reached (\(managed)/\(Self.maxAutoFollowedChildren)); refusing \(child.directory) and any further announcements this sweep")
                break
            }
            log.info("\(childPath.joined(separator: "/")): auto-following newly-announced child")
            await followChild(chainPath: childPath)
        }
    }

    /// One reconcile sweep over every non-detached deployed child.
    func reconcileSupervisedChildren() async {
        guard childSupervisor != nil else { return }
        // First discover newly-announced children of our own chain and follow them
        // (recursive self-assembly); then reconcile every managed child below.
        await autoFollowAnnouncedChildren()
        // Snapshot before the loop: ensureSupervisedChild suspends on network probes,
        // and a concurrent detach/deploy could mutate deployedChildChains mid-iteration.
        let snapshot = Array(deployedChildChains.values)
        for metadata in snapshot {
            await ensureSupervisedChild(metadata)
        }
    }

    /// Start the continuous reconcile loop (idempotent). Cancelled in `stop()`.
    func startSupervisedReconcileLoop() {
        guard childSupervisor != nil, supervisedReconcileTask == nil else { return }
        supervisedReconcileTask = Task { [self] in
            while !Task.isCancelled {
                await reconcileSupervisedChildren()
                try? await Task.sleep(nanoseconds: Self.supervisedReconcileIntervalSeconds * 1_000_000_000)
            }
        }
    }

    /// Contract 4: mark a deployed child detached (operator `unregister-rpc`), stop its
    /// supervised process, and drop its registration so nothing re-delivers to it.
    func detachSupervisedChild(chainPath: [String]) async {
        let key = chainKey(forPath: chainPath)
        if var metadata = deployedChildChains[key] {
            metadata.detached = true
            deployedChildChains[key] = metadata
            await persistDeployedChildChains()
        }
        supervisedRPCDownSince.removeValue(forKey: key)
        followedGenesisResolveFailures.removeValue(forKey: key)
        if let supervisor = childSupervisor, let dir = chainPath.last {
            await supervisor.stop(label: dir)
        }
        unregisterRPCEndpoint(chainPath: chainPath)
    }

    /// Declare that this node FOLLOWS (subscribes to) an existing, announced child chain.
    /// Records a followed-child stub (genesis empty); the reconcile loop resolves its genesis
    /// from the parent's on-chain GenesisState + CAS and spawns/syncs it. Idempotent, and
    /// clears a prior detach so re-following resumes management. No-op if not supervising.
    public func followChild(chainPath: [String]) async {
        guard childSupervisor != nil, chainPath.count >= 2, let directory = chainPath.last else { return }
        let key = chainKey(forPath: chainPath)
        let parentDir = chainPath[chainPath.count - 2]
        let existing = deployedChildChains[key]
        deployedChildChains[key] = DeployedChainMetadata(
            chainPath: chainPath, directory: directory, parentDirectory: parentDir,
            genesisHash: existing?.genesisHash ?? "", genesisHex: existing?.genesisHex ?? "",
            timestamp: existing?.timestamp ?? 0, detached: false, followed: true,
            portSlot: existing?.portSlot)  // preserve the assigned port across re-follow
        await persistDeployedChildChains()
    }

    /// Resolve a followed child's genesis into a self-contained genesis-hex payload: read its
    /// genesis CID from the parent's on-chain GenesisState, fetch the genesis block + spec +
    /// WASM policy modules from CAS by CID (ivyFetcher does pinner discovery on a local miss),
    /// and encode with the shared `GenesisHexCodec`. Returns an updated metadata with
    /// genesisHash/genesisHex filled, or nil if the genesis isn't resolvable/available yet.
    private func resolveFollowedGenesis(_ metadata: DeployedChainMetadata) async -> DeployedChainMetadata? {
        guard let parentNetwork = network(forPath: Array(metadata.chainPath.dropLast())) else { return nil }
        guard let genesisCID = await announcedChildGenesisCID(chainPath: metadata.chainPath) else { return nil }
        guard let genesisData = try? await parentNetwork.ivyFetcher.fetch(rawCid: genesisCID),
              let genesisBlock = Block(data: genesisData) else { return nil }
        var entries: [GenesisHexEntry] = [GenesisHexEntry(cid: genesisCID, data: genesisData)]
        let specCID = genesisBlock.spec.rawCID
        var spec = genesisBlock.spec.node
        if spec == nil { spec = try? await genesisBlock.spec.resolve(fetcher: parentNetwork.ivyFetcher).node }
        if let specData = spec?.toData() { entries.append(GenesisHexEntry(cid: specCID, data: specData)) }
        if let spec {
            for policy in spec.wasmPolicies {
                let moduleHeader = WasmPolicyModuleHeader(rawCID: policy.moduleCID)
                // Fail-closed like the tx path: a missing policy module → incomplete genesis-hex
                // (the rebuild-compare below can't catch it — modules are referenced by CID, not
                // embedded in the block closure). Retry rather than boot a child missing a policy.
                guard let module = try? await moduleHeader.resolve(fetcher: parentNetwork.ivyFetcher).node,
                      let moduleData = module.toData() else { return nil }
                entries.append(GenesisHexEntry(cid: policy.moduleCID, data: moduleData))
            }
        }
        // Include the genesis TRANSACTION bodies. The child rebuilds a fully-inline genesis via
        // buildGenesis(transactions:), so without these it constructs a DIFFERENT genesis block
        // (mismatched CID → the followed child forks a divergent chain that can never sync with
        // nodes on the real chain). Mirrors the deploy path's genesisBootstrapEntries.
        //
        // FAIL-CLOSED: a PARTIAL tx set (some bodies not yet fetchable) would still boot a
        // divergent genesis — but silently, and get persisted. So require every tx body to
        // resolve; on any miss return nil and let the reconciler re-probe next sweep (never
        // emit an incomplete genesis-hex).
        guard let spec,
              let txDict = try? await genesisBlock.transactions.resolveRecursive(fetcher: parentNetwork.ivyFetcher).node,
              let txVols = try? txDict.allKeysAndValues() else { return nil }
        // buildGenesis keys transactions by ARRAY INDEX and applies them in order, so the
        // reconstruction must feed txs in the original order. allKeysAndValues() keys are the
        // index as a string ("0","1",…); sort by INTEGER (not lexical: "10" < "2") to recover it.
        var genesisTxs: [Transaction] = []
        for (_, txVol) in txVols.sorted(by: { (Int($0.key) ?? Int.max) < (Int($1.key) ?? Int.max) }) {
            guard let tx = try? await txVol.resolve(fetcher: parentNetwork.ivyFetcher).node else { return nil }
            var body = tx.body.node
            if body == nil { body = try? await tx.body.resolve(fetcher: parentNetwork.ivyFetcher).node }
            guard let bodyData = body?.toData() else { return nil }
            entries.append(GenesisHexEntry(cid: tx.body.rawCID, data: bodyData))
            genesisTxs.append(tx)
        }
        // Invariant the follow path was missing entirely: verify the reconstructed genesis
        // actually reproduces the announced CID BEFORE accepting. Deterministic genesis, so a
        // rebuild from (spec, txs, timestamp, target) must equal the anchored genesisCID — if it
        // doesn't, the hex is wrong/incomplete; return nil rather than spawn a divergent child.
        var rebuiltCID: String? = nil
        if let rebuilt = try? await BlockBuilder.buildGenesis(
               spec: spec, transactions: genesisTxs,
               timestamp: genesisBlock.timestamp, target: genesisBlock.target,
               fetcher: parentNetwork.ivyFetcher),
           let vol = try? VolumeImpl<Block>(node: rebuilt) {
            rebuiltCID = vol.rawCID
        }
        // Fail-closed: reconstructed genesis must reproduce the announced CID, else the hex is
        // incomplete/wrong — return nil and let the reconciler re-probe rather than fork a child.
        guard rebuiltCID == genesisCID else { return nil }
        let genesisHex = GenesisHexCodec.encodeEntries(entries).map { String(format: "%02x", $0) }.joined()
        return DeployedChainMetadata(
            chainPath: metadata.chainPath, directory: metadata.directory,
            parentDirectory: metadata.parentDirectory, genesisHash: genesisCID,
            genesisHex: genesisHex, timestamp: metadata.timestamp, detached: metadata.detached,
            followed: true, portSlot: metadata.portSlot)  // preserve the assigned port
    }
}
