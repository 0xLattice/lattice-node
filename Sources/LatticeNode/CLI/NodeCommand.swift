import ArgumentParser
import Foundation
import Synchronization
import LatticeNodeAuth
import Lattice
import Ivy
import cashew
import VolumeBroker

let LatticeNodeVersion = LatticeProtocol.nodeVersion
let ProtocolVersion = LatticeProtocol.version

struct NodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "node",
        abstract: "Run the Lattice node daemon"
    )

    @Option(name: .long, help: "P2P listen port")
    var port: UInt16 = 4001

    @Option(name: .long, help: "Storage directory")
    var dataDir: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattice").path

    @Option(name: .long, parsing: .singleValue, help: "Bootstrap peer (pubKey@host:port, repeatable)")
    var peer: [String] = []

    @Option(name: .long, help: "Memory for CAS cache in GB")
    var memory: Double = 0.25

    @Option(name: .long, help: "Disk for CAS storage in GB")
    var disk: Double = 1.0

    @Option(name: .long, help: "Mempool memory in MB")
    var mempool: Double = 64.0

    @Option(name: .long, help: "Nonces per mining batch")
    var miningBatch: UInt64 = 10_000

    @Flag(name: .long, help: "Auto-detect system resources")
    var autosize: Bool = false

    @Option(name: .long, help: "Cap for autosize memory in GB")
    var maxMemory: Double?

    @Option(name: .long, help: "Cap for autosize disk in GB")
    var maxDisk: Double?

    @Option(name: .long, help: "Enable JSON RPC server on port")
    var rpcPort: UInt16?

    @Option(name: .long, help: "RPC bind address")
    var rpcBind: String = "127.0.0.1"

    @Option(name: .long, help: "Public P2P address to advertise to peers (host:port). Required for cloud/NAT nodes whose locally-observed address is not externally dialable (e.g. fly 172.x). Without it peers learn an unreachable address and cannot join.")
    var externalAddress: String?

    @Option(name: .long, help: "Public, CORS-enabled HTTP RPC base URL for this node (e.g. https://node.example.com), advertised through the child-peer rendezvous so a browser can be pointed straight at this node's chain via GET /api/chain/endpoints. Set it on a child-chain node you want browsable; leave unset for NAT/private nodes.")
    var rpcPublicUrl: String?

    @Flag(name: .long, help: "Serve as a circuit relay: forward traffic for peers that cannot connect directly (NAT). Defaults on when --external-address is set (public/backbone nodes).")
    var relay: Bool = false

    @Option(name: .long, parsing: .singleValue, help: "Relay peer to route through when a direct dial fails (pubKey@host:port, repeatable).")
    var useRelay: [String] = []

    @Option(name: .long, help: "CORS allowed origin")
    var rpcAllowedOrigin: String = "http://127.0.0.1"

    @Flag(name: .long, help: "Enable mDNS local peer discovery (off by default; headless/server deployments don't need it)")
    var localDiscovery: Bool = false

    @Flag(name: .long, help: "Deprecated: cookie-based RPC authentication is always on. Retained for compatibility; has no effect.")
    var rpcAuth: Bool = false

    @Flag(name: .long, help: "Trust X-Forwarded-For and X-Real-IP headers for rate limiting (enable only when behind a trusted reverse proxy)")
    var rpcTrustProxyHeaders: Bool = false

    @Flag(name: .long, help: "Disable DNS seed resolution")
    var noDnsSeeds: Bool = false

    @Flag(name: .long, help: "Discovery-only mode: relay peers without syncing or mining")
    var discoveryOnly: Bool = false

    @Flag(name: .long, help: "Stateless mode: disk CAS budget forced to 0 (holds no local CAS; validates and mines by fetching from peers on demand)")
    var stateless: Bool = false

    @Option(name: .long, help: "State storage mode: stateless | stateful | historical (default: stateful). historical keeps full state trie for all main-chain blocks.")
    var storageMode: String = "stateful"

    @Option(name: .long, help: "Block retention policy: tip | retention | historical (default: retention). historical keeps all main-chain block volumes.")
    var blockRetention: String = "retention"

    @Option(name: .long, help: "Parent chain P2P address to subscribe to for block extraction (Phase 3 per-process mode). Format: <pubkey>@host:port. When set, this node extracts its own blocks from parent-chain gossip blocks.")
    var subscribeP2p: String?

    @Option(name: .long, help: "Override the chain directory this node tracks (Phase 3 per-process mode). When set with --subscribe-p2p, the node extracts blocks for THIS directory from parent gossip rather than the genesis directory. E.g. --chain-directory Mid on a node subscribed to Nexus P2P.")
    var chainDirectory: String?

    @Option(name: .long, help: "Full chain path from Nexus root, slash-separated (e.g. Nexus/Mid/Stable). Transactions submitted to this node are validated against this path, enabling direct submission using the full ancestral chain path.")
    var chainPath: String?

    @Option(name: .long, help: "Hex-encoded genesis block bytes for per-process child chain bootstrap. Obtained from the parent node's POST /api/chain/deploy response (genesisHex field). The child process uses this genesis instead of building one from spec parameters.")
    var genesisHex: String?

    @Flag(name: .long, help: "Spawn and supervise one OS process per deployed child chain (process-per-chain spawn tree). Deploying a child launches a managed lattice-node with no manual port/genesis/peer wiring; stopping this node quiesces the subtree. Default off.")
    var superviseChildren: Bool = false

    @Option(name: .long, help: "This node's spawn-certificate chain (root→…→self), base64-encoded JSON, delivered by the spawn-tree parent. Presented to peers after identify so ancestors can verify spawn-tree membership and serve the trusted consensus view. Absent ⇒ federated node.")
    var spawnCertChain: String?


    @Option(name: .long, help: "Maximum peer connections (default 128, discovery-only 512)")
    var maxPeers: Int?

    @Option(name: .long, help: "Maximum Ivy wire frame size in bytes (default 4194304)")
    var maxFrameSize: UInt32 = IvyConfig.defaultMaxFrameSize

    @Option(name: .long, help: "Node-local minimum fee rate in units per serialized-body byte for mempool admission/relay (default 1). Relay policy only — not a consensus rule.")
    var minFeeRate: UInt64 = 1

    @Option(name: .long, help: "Minimum proof-of-work bits a peer identity key must carry to be admitted (default 16 — the live-network value; 0 disables). Raises the cost of Sybil/eclipse routing-table poisoning; must match the network you join.")
    var minPeerKeyBits: Int = LatticeNodeConfig.defaultMinPeerKeyBits

    @Option(name: .long, help: "Default finality confirmations for all chains (default: no finality in PoW)")
    var finalityConfirmations: UInt64 = UInt64.max

    @Option(name: .long, parsing: .singleValue, help: "Per-chain finality (chain:confirmations, repeatable)")
    var finalityPolicy: [String] = []

    @Option(name: .long, help: "Path to JSON config file (overrides CLI defaults)")
    var config: String?

    @Option(name: .long, help: "Password for encrypting/decrypting the node private key (prefer LATTICE_KEY_PASSWORD env var — CLI arg is visible in ps output)")
    var keyPassword: String?

    @Flag(name: .long, help: "Connect to the Lattice testnet instead of mainnet")
    var testnet: Bool = false

    @Option(name: .long, help: "DEV/TEST ONLY: override the built-genesis timestamp (ms since epoch). Produces a non-pinned genesis (the frozen expectedBlockHash check is skipped) so a node can mine before the real flag-day instant. NEVER use on a real network.")
    var genesisTimestamp: Int64?

    @Option(name: .long, help: "DEV/TEST ONLY: override the built-genesis target block time in ms. Produces a private, non-pinned genesis and requires --no-dns-seeds. NEVER use on a real network.")
    var genesisTargetBlockTime: UInt64?

    @Option(name: .long, help: "DEV/TEST ONLY: override the built-genesis retarget window. Produces a private, non-pinned genesis and requires --no-dns-seeds. NEVER use on a real network.")
    var genesisRetargetWindow: UInt64?

    @Option(name: .long, help: "Public payout address credited in the block-template coinbase. The node signs with its local coinbase authority; the miner never sends or holds any signing key. When unset, templates carry no reward.")
    var coinbaseAddress: String?

    func run() async throws {
        #if canImport(Darwin)
        setbuf(Darwin.stdout, nil)
        #endif
        // Load config file if provided — values override CLI defaults
        var effectivePort = port
        var effectiveDataDir = dataDir
        var effectivePeer = peer
        var effectiveMemory = memory
        var effectiveDisk = disk
        var effectiveMempool = mempool
        var effectiveMiningBatch = miningBatch
        var effectiveAutosize = autosize
        let effectiveMaxMemory = maxMemory
        let effectiveMaxDisk = maxDisk
        var effectiveRpcPort = rpcPort
        var effectiveRpcBind = rpcBind
        var effectiveRpcAllowedOrigin = rpcAllowedOrigin
        var effectiveLocalDiscovery = localDiscovery
        var effectiveRpcTrustProxyHeaders = rpcTrustProxyHeaders
        var effectiveNoDnsSeeds = noDnsSeeds
        var effectiveDiscoveryOnly = discoveryOnly
        var effectiveStateless = stateless
        var effectiveMaxPeersOpt = maxPeers
        var effectiveMaxFrameSize = maxFrameSize
        var effectiveMinFeeRate = minFeeRate
        var effectiveFinalityConfirmations = finalityConfirmations
        var effectiveFinalityPolicy = finalityPolicy
        var effectiveKeyPassword = keyPassword ?? ProcessInfo.processInfo.environment["LATTICE_KEY_PASSWORD"]
        var effectiveTestnet = testnet
        var effectiveMinPeerKeyBits = minPeerKeyBits

        if let configPath = config {
            let configURL = URL(fileURLWithPath: configPath)
            if let configData = try? Data(contentsOf: configURL),
               let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
                if let v = json["port"] as? Int, v >= 1 && v <= 65535 { effectivePort = UInt16(v) }
                if let v = json["dataDir"] as? String { effectiveDataDir = v }
                if let v = json["memory"] as? Double { effectiveMemory = v }
                if let v = json["disk"] as? Double { effectiveDisk = v }
                if let v = json["mempool"] as? Double { effectiveMempool = v }
                if let v = json["miningBatch"] as? Int, v >= 0 { effectiveMiningBatch = UInt64(v) }
                if let v = json["rpcPort"] as? Int, v >= 1 && v <= 65535 { effectiveRpcPort = UInt16(v) }
                if let v = json["rpcBind"] as? String { effectiveRpcBind = v }
                if let v = json["rpcAllowedOrigin"] as? String { effectiveRpcAllowedOrigin = v }
                if let v = json["rpcTrustProxyHeaders"] as? Bool { effectiveRpcTrustProxyHeaders = v }
                if let v = json["localDiscovery"] as? Bool { effectiveLocalDiscovery = v }
                else if let v = json["noDiscovery"] as? Bool { effectiveLocalDiscovery = !v }
                if let v = json["noDnsSeeds"] as? Bool { effectiveNoDnsSeeds = v }
                if let v = json["discoveryOnly"] as? Bool { effectiveDiscoveryOnly = v }
                if let v = json["stateless"] as? Bool { effectiveStateless = v }
                if let v = json["maxPeers"] as? Int { effectiveMaxPeersOpt = v }
                if let v = json["maxFrameSize"] as? Int, v > 0, v <= Int(UInt32.max) { effectiveMaxFrameSize = UInt32(v) }
                if let v = json["minFeeRate"] as? Int, v >= 0 { effectiveMinFeeRate = UInt64(v) }
                if let v = json["autosize"] as? Bool { effectiveAutosize = v }
                if let v = json["finalityConfirmations"] as? Int { effectiveFinalityConfirmations = UInt64(v) }
                if let v = json["keyPassword"] as? String { effectiveKeyPassword = v }
                if let v = json["testnet"] as? Bool { effectiveTestnet = v }
                if let v = json["minPeerKeyBits"] as? Int, v >= 0 { effectiveMinPeerKeyBits = v }
                if let peers = json["peers"] as? [String] { effectivePeer = peers }
                if let policies = json["finalityPolicy"] as? [String] { effectiveFinalityPolicy = policies }
            } else {
                print("  WARNING: Could not load config file: \(configPath)")
            }
        }

        let defaultDataDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattice").path
        if effectiveTestnet && effectiveDataDir == defaultDataDir {
            effectiveDataDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lattice-testnet").path
        }

        let dataDirURL = URL(fileURLWithPath: effectiveDataDir)
        let bootstrapPeers = effectivePeer.compactMap { parsePeer($0) }
        let usesDevGenesisOverride = genesisTimestamp != nil
            || genesisTargetBlockTime != nil
            || genesisRetargetWindow != nil

        // Safety fence for DEV/TEST genesis overrides: they shift the genesis hash
        // off the frozen value, so the node belongs to a private dev network. Refuse
        // to also enable DNS-seed discovery, which would dial the real mainnet/testnet
        // with a divergent genesis. Explicit --peer (loopback dev nodes) is still
        // allowed; the real-network bootstrap fallback is suppressed below.
        if usesDevGenesisOverride && !effectiveNoDnsSeeds {
            print("  FATAL: genesis overrides are DEV/TEST only and require --no-dns-seeds")
            print("         (refusing to enable real-network DNS discovery with a divergent genesis).")
            throw ExitCode.failure
        }
        if genesisTargetBlockTime == 0 || genesisRetargetWindow == 0 {
            print("  FATAL: genesis target block time and retarget window overrides must be positive")
            throw ExitCode.failure
        }

        if effectiveStateless {
            effectiveDisk = 0.0
        }

        let effectiveMaxPeers = effectiveMaxPeersOpt ?? (effectiveDiscoveryOnly
            ? BootstrapPeers.maxPeerConnectionsDiscovery
            : BootstrapPeers.maxPeerConnections)

        let nodeArgs = NodeArgs(
            port: effectivePort,
            dataDir: dataDirURL,
            bootstrapPeers: bootstrapPeers,
            memoryGB: effectiveMemory,
            diskGB: effectiveDisk,
            mempoolMB: effectiveMempool,
            miningBatch: effectiveMiningBatch,
            autosize: effectiveAutosize,
            maxMemoryGB: effectiveMaxMemory,
            maxDiskGB: effectiveMaxDisk,
            rpcPort: effectiveRpcPort,
            rpcBindAddress: effectiveRpcBind,
            enableDiscovery: effectiveLocalDiscovery,
            rpcAllowedOrigin: effectiveRpcAllowedOrigin,
            discoveryOnly: effectiveDiscoveryOnly,
            maxPeerConnections: effectiveMaxPeersOpt,
            maxFrameSize: effectiveMaxFrameSize
        )

        let state = NodeState(nodeArgs: nodeArgs)

        // remote default-config nodes gate OUR identify key on their
        // minPeerKeyBits, so the node's own identity must carry the same work.
        // #243: the grind is a one-time-per-data-dir cost on a COLD first boot —
        // quick at the 16-bit default, multi-minute only if raised. It only presents on the
        // wire (ivy.start, inside node.start()) — the local RPC control plane and
        // all the identity-independent boot prep (DNS seed resolution, peer-store
        // I/O, genesis decode/verify) do not need it. So kick the grind off in a
        // detached Task and overlap it with that prep; we await it (fail-closed)
        // only just before node.start(), the single place the identity hits the
        // wire. A node with a cached current-bits identity returns instantly, so
        // the warm path is unchanged.
        let grindNeeded = identityGrindRequired(
            dataDir: dataDirURL,
            minKeyBits: effectiveMinPeerKeyBits
        )
        let identityTask = Task { () throws -> IdentityFile in
            try loadOrCreateIdentity(
                dataDir: dataDirURL,
                password: effectiveKeyPassword,
                minKeyBits: effectiveMinPeerKeyBits
            )
        }

        print()
        if effectiveDiscoveryOnly {
            print("  Lattice Discovery Node v\(LatticeNodeVersion) (protocol \(ProtocolVersion))")
            print("  ========================")
        } else {
            print("  Lattice Node v\(LatticeNodeVersion) (protocol \(ProtocolVersion))")
            print("  ============")
        }
        print("  Network:     \(effectiveTestnet ? "TESTNET" : "mainnet")")
        if grindNeeded {
            print("  Identity:    grinding node key to \(effectiveMinPeerKeyBits) bits (overlaps boot prep; ~seconds–minutes on first boot, then RPC binds)...")
        }
        print("  Data dir:    \(dataDirURL.path)")
        print("  Listen port: \(effectivePort)")
        print("  Max peers:   \(effectiveMaxPeers)")
        print("  Discovery:   \(effectiveLocalDiscovery ? "enabled" : "disabled")")
        if !bootstrapPeers.isEmpty {
            print("  Peers:       \(bootstrapPeers.count) bootstrap peer(s)")
        }
        print()

        let resources = effectiveDiscoveryOnly ? NodeResourceConfig.light : configureResources(nodeArgs)
        var updatedArgs = nodeArgs
        updatedArgs.memoryGB = resources.memoryBudgetGB
        updatedArgs.diskGB = resources.diskBudgetGB
        updatedArgs.mempoolMB = resources.mempoolBudgetMB
        updatedArgs.miningBatch = resources.miningBatchSize
        await state.updateArgs(updatedArgs)

        if !effectiveDiscoveryOnly {
            print("  Memory:      \(String(format: "%.2f", resources.memoryBudgetGB)) GB")
            if effectiveStateless {
                print("  Disk:        0.00 GB (stateless)")
            } else {
                print("  Disk:        \(String(format: "%.2f", resources.diskBudgetGB)) GB")
            }
            print("  Mempool:     \(String(format: "%.0f", resources.mempoolBudgetMB)) MB")
            print("  Mine batch:  \(resources.miningBatchSize)")
            print("  Max frame:   \(effectiveMaxFrameSize) bytes")
        }

        // Under DEV genesis overrides, never fall back to the real mainnet/testnet
        // bootstrap peers — a dev node only connects to explicit --peer.
        let fallbackPeers = usesDevGenesisOverride
            ? []
            : (effectiveTestnet ? BootstrapPeers.testnet : BootstrapPeers.nexus)
        var allPeers = await loadPeers(dataDirURL: dataDirURL, bootstrapPeers: bootstrapPeers, fallbackPeers: fallbackPeers)
        if !effectiveNoDnsSeeds {
            let dnsConfigured = effectiveTestnet
                ? DNSSeeds.isTestnetBootstrapConfigured
                : DNSSeeds.isMainnetBootstrapConfigured
            if !dnsConfigured {
                print("  DNS seeds:   disabled (no trusted seed signing keys pinned)")
            } else {
                let dnsResolved = effectiveTestnet ? await DNSSeeds.resolveTestnet() : await DNSSeeds.resolve()
                if !dnsResolved.isEmpty {
                    let existingKeys = Set(allPeers.map { $0.publicKey })
                    for peer in dnsResolved where !existingKeys.contains(peer.publicKey) {
                        allPeers.append(peer)
                    }
                    print("  DNS seeds:   \(dnsResolved.count) peer(s) resolved")
                }
            }
        }
        if !allPeers.isEmpty {
            let peerStore = PeerStore(dataDir: dataDirURL)
            let savedCount = await peerStore.load().count
            print("  Bootstrap:   \(allPeers.count) peer(s) (\(savedCount) persisted)")
        }

        let parsedFinality = FinalityConfig(
            policies: effectiveFinalityPolicy.compactMap { FinalityPolicy.parse($0) },
            defaultConfirmations: effectiveFinalityConfirmations
        )

        let retentionDepth = ProcessInfo.processInfo.environment["RETENTION_DEPTH"].flatMap(UInt64.init) ?? DEFAULT_RETENTION_DEPTH
        let pinExpiry = ProcessInfo.processInfo.environment["PIN_ANNOUNCE_EXPIRY"].flatMap(UInt64.init) ?? 86400
        let reannounceSeconds = ProcessInfo.processInfo.environment["REANNOUNCE_INTERVAL"].flatMap(Double.init) ?? 86400
        let evictionSeconds = ProcessInfo.processInfo.environment["EVICTION_INTERVAL"].flatMap(Double.init) ?? 21600

        let parsedStorageMode = StorageMode(rawValue: storageMode) ?? .stateful
        let parsedBlockRetention = BlockRetention(rawValue: blockRetention) ?? .retention

        // The node identity is the first thing that has to be REAL: nodeConfig,
        // and through it the nexus Ivy built eagerly in LatticeNode.init, derive
        // nodeAddress / coinbase signing / the presented P2P key from it. So we
        // join the background grind here — it has been running while DNS seeds
        // resolved and the peer store loaded above. Fail closed: a grind error
        // (or an undecryptable key) propagates now, long before node.start(), so
        // P2P never starts with a bad or empty identity.
        let identity = try await identityTask.value
        guard let privateKey = identity.privateKey else {
            print("  FATAL: Could not decrypt private key. Provide --key-password.")
            throw ExitCode.failure
        }
        print("  Public key:  \(String(identity.publicKey.prefix(32)))...")

        // Parse --external-address (host:port) into the advertised endpoint.
        let parsedExternalAddress: (host: String, port: UInt16)? = externalAddress.flatMap { raw in
            guard let idx = raw.lastIndex(of: ":"),
                  let p = UInt16(raw[raw.index(after: idx)...]) else { return nil }
            let h = String(raw[..<idx])
            return h.isEmpty ? nil : (host: h, port: p)
        }
        if externalAddress != nil && parsedExternalAddress == nil {
            print("  WARNING: --external-address '\(externalAddress!)' is not host:port — ignoring")
        } else if let ext = parsedExternalAddress {
            print("  External:    advertising \(ext.host):\(ext.port) to peers")
        }

        // Circuit relay: serve by default when we advertise a public address.
        let effectiveRelay = relay || parsedExternalAddress != nil
        let parsedRelays = useRelay.compactMap { parsePeer($0) }
        if effectiveRelay { print("  Relay:       serving as a circuit relay") }
        if !parsedRelays.isEmpty { print("  Relays:      \(parsedRelays.count) known relay(s) for fallback") }

        let nodeConfig = LatticeNodeConfig(
            publicKey: identity.publicKey,
            privateKey: privateKey,
            listenPort: effectivePort,
            bootstrapPeers: allPeers,
            storagePath: dataDirURL,
            enableLocalDiscovery: effectiveLocalDiscovery,
            persistInterval: 100,
            retentionDepth: retentionDepth,
            resources: resources,
            tuning: NodeTuning.fromEnvironment(),
            finality: parsedFinality,
            maxPeerConnections: effectiveMaxPeers,
            discoveryOnly: effectiveDiscoveryOnly,
            storageMode: parsedStorageMode,
            blockRetention: parsedBlockRetention,
            pinAnnounceExpiry: pinExpiry,
            reannounceInterval: .seconds(reannounceSeconds),
            evictionInterval: .seconds(evictionSeconds),
            maxFrameSize: effectiveMaxFrameSize,
            minFeeRate: effectiveMinFeeRate,
            isTestnet: effectiveTestnet,
            fullChainPath: chainPath.map { $0.split(separator: "/").map(String.init) },
            minPeerKeyBits: effectiveMinPeerKeyBits,
            coinbaseAddress: coinbaseAddress,
            externalAddress: parsedExternalAddress,
            rpcPublicUrl: rpcPublicUrl,
            relayEnabled: effectiveRelay,
            knownRelays: parsedRelays
        )

        // Per-process child chain bootstrap: if --genesis-hex is provided, decode the
        // genesis block seeded from the parent's deploy response instead of building one.
        // --chain-directory tells us which chain this process owns.
        var prebuiltBlock: Block? = nil
        var genesisConfig: GenesisConfig
        var genesisHexTransactions: [Transaction] = []  // reconstructed from TX body entries
        // bootstrapEntries: CAS entries to store on startup from --genesis-hex
        var bootstrapEntries: [(cid: String, data: Data)] = []
        if let hexStr = genesisHex, !hexStr.isEmpty {
            // Single, size-bounded choke point for untrusted genesis-hex input.
            // Fails closed on oversized / malformed blobs before any large alloc.
            do {
                bootstrapEntries = try GenesisHexBootstrap.parse(hex: hexStr)
            } catch GenesisHexBootstrap.ParseError.tooLarge {
                print("  FATAL: --genesis-hex exceeds \(GenesisHexBootstrap.maxBytes)-byte limit.")
                throw ExitCode.failure
            } catch {
                print("  FATAL: --genesis-hex could not be decoded.")
                throw ExitCode.failure
            }
            // First entry is always the genesis block
            guard let (_, blockData) = bootstrapEntries.first, let block = Block(data: blockData) else {
                print("  FATAL: --genesis-hex first entry is not a valid genesis block.")
                throw ExitCode.failure
            }
            guard block.height == 0, block.parent == nil else {
                print("  FATAL: --genesis-hex block must be height=0 with no parent.")
                throw ExitCode.failure
            }
            // Extract spec from entries (second entry) or from inline spec node
            let dir: String
            if let specNode = block.spec.node {
                // Specs no longer carry a directory; derive it from the CLI option,
                // defaulting to the root directory, and preserve it on the GenesisConfig.
                dir = chainDirectory ?? DEFAULT_ROOT_DIRECTORY
                genesisConfig = GenesisConfig(spec: specNode, timestamp: block.timestamp, target: block.target, directory: dir)
            } else if let (_, specData) = bootstrapEntries.first(where: { $0.cid == block.spec.rawCID }),
                      let specNode = ChainSpec(data: specData) {
                dir = chainDirectory ?? DEFAULT_ROOT_DIRECTORY
                genesisConfig = GenesisConfig(spec: specNode, timestamp: block.timestamp, target: block.target, directory: dir)
            } else if let overrideDir = chainDirectory, !overrideDir.isEmpty {
                dir = overrideDir
                let spec = ChainSpec(maxNumberOfTransactionsPerBlock: 0,
                                     maxStateGrowth: 0, maxBlockSize: 0, premine: 0,
                                     targetBlockTime: 1000, initialReward: 0, halvingInterval: 1,
                                     retargetWindow: 1)
                genesisConfig = GenesisConfig(spec: spec, timestamp: block.timestamp, target: block.target, directory: dir)
            } else {
                print("  FATAL: --genesis-hex missing spec entry; provide --chain-directory <dir>.")
                throw ExitCode.failure
            }
            // Reconstruct genesis TXs from TX body entries (entries after block + spec).
            // Bodies use empty signatures so TXs are deterministically reconstructible.
            let specCID = block.spec.rawCID
            let txBodyCIDs: Set<String> = Set(bootstrapEntries.dropFirst(2).map { $0.cid })
            for (cid, data) in bootstrapEntries where cid != (try VolumeImpl<Block>(node: block).rawCID) && cid != specCID {
                if txBodyCIDs.contains(cid), let body = TransactionBody(data: data) {
                    let computedHeader = try HeaderImpl<TransactionBody>(node: body)
                    if computedHeader.rawCID == cid {
                        let bodyHeader = HeaderImpl<TransactionBody>(rawCID: cid, node: body, encryptionInfo: nil)
                        genesisHexTransactions.append(Transaction(signatures: [:], body: bodyHeader))
                    }
                }
            }
            prebuiltBlock = block
            print("  Genesis:     seeded from --genesis-hex (\(dir), \(String(try VolumeImpl<Block>(node: block).rawCID.prefix(20)))...) txs=\(genesisHexTransactions.count)")
        } else {
            // Testnet and mainnet both ship a frozen genesis (fixed timestamp +
            // pinned expectedBlockHash); no GENESIS_TIMESTAMP env is needed.
            let frozenConfig = effectiveTestnet ? TestnetGenesis.config : NexusGenesis.config
            if usesDevGenesisOverride {
                // DEV/TEST overrides rebuild the genesis config at non-frozen
                // parameters. This shifts the genesis hash, so the frozen-hash gate
                // below is skipped. Not for use on a real network.
                let frozenSpec = frozenConfig.spec
                let spec = ChainSpec(
                    maxNumberOfTransactionsPerBlock: frozenSpec.maxNumberOfTransactionsPerBlock,
                    maxStateGrowth: frozenSpec.maxStateGrowth,
                    maxBlockSize: frozenSpec.maxBlockSize,
                    premine: frozenSpec.premine,
                    targetBlockTime: genesisTargetBlockTime ?? frozenSpec.targetBlockTime,
                    initialReward: frozenSpec.initialReward,
                    halvingInterval: frozenSpec.halvingInterval,
                    retargetWindow: genesisRetargetWindow ?? frozenSpec.retargetWindow,
                    wasmPolicies: frozenSpec.wasmPolicies
                )
                genesisConfig = GenesisConfig(
                    spec: spec,
                    timestamp: genesisTimestamp ?? frozenConfig.timestamp,
                    target: frozenConfig.target,
                    directory: frozenConfig.directory
                )
                print("  Genesis:     DEV override ts=\(genesisConfig.timestamp) targetBlockTime=\(spec.targetBlockTime) retargetWindow=\(spec.retargetWindow) (frozen hash check bypassed)")
            } else {
                genesisConfig = frozenConfig
            }
        }

        let genesisBuilder: LatticeNode.GenesisBuilder?
        if prebuiltBlock != nil {
            genesisBuilder = nil
        } else if effectiveTestnet {
            genesisBuilder = TestnetGenesis.buildGenesisBlock
        } else {
            genesisBuilder = NexusGenesis.buildGenesisBlock
        }
        if prebuiltBlock != nil {
            let localChainPath = chainPath?.split(separator: "/").map(String.init) ?? [genesisConfig.directory]
            do {
                try LatticeNode.validateSubscriptionFrameBudget(
                    chainPath: localChainPath,
                    spec: genesisConfig.spec,
                    maxFrameSize: effectiveMaxFrameSize
                )
            } catch {
                print("  FATAL: \(error)")
                throw ExitCode.failure
            }
        }
        // A supervised child inherits the parent's namespace-independent policy
        // (Sybil identity-key gate, relay fee floor, DNS-seed behavior), using the
        // config-resolved effective values. Ports/genesis/data-dir are per-child
        // and derived at spawn time.
        var childInheritedArgs = ["--min-peer-key-bits", String(effectiveMinPeerKeyBits), "--min-fee-rate", String(effectiveMinFeeRate)]
        if effectiveNoDnsSeeds { childInheritedArgs.append("--no-dns-seeds") }
        // A stateless operator holds no local CAS; the children it supervises/follows
        // must be stateless too, otherwise a followed child silently accrues full
        // on-disk state the parent's stateless posture promised not to keep.
        if effectiveStateless { childInheritedArgs.append("--stateless") }
        // Self-similar recursion: a supervised/followed child is itself a full node that
        // supervises + auto-follows ITS OWN announced children. Inheriting the flag is
        // what lets a deep subtree (Nexus -> Mid -> Stable -> …) self-assemble one level
        // per process — no chain is special. (See autoFollowAnnouncedChildren.)
        if superviseChildren { childInheritedArgs.append("--supervise-children") }
        // Decode this node's spawn-cert chain (base64 JSON), if delivered. A
        // malformed value fails closed (federated) — it never trusts on a parse error.
        var decodedSpawnCertChain: [SpawnCertificate] = []
        if let encoded = spawnCertChain, let raw = Data(base64Encoded: encoded),
           let chain = try? JSONDecoder().decode([SpawnCertificate].self, from: raw) {
            decodedSpawnCertChain = chain
        } else if spawnCertChain != nil {
            print("  WARNING: --spawn-cert-chain could not be decoded; running as a federated node")
        }
        let node = try await LatticeNode(
            config: nodeConfig,
            genesisConfig: genesisConfig,
            genesisBuilder: genesisBuilder,
            prebuiltGenesisBlock: prebuiltBlock,
            prebuiltGenesisTransactions: genesisHexTransactions.isEmpty ? nil : genesisHexTransactions,
            superviseChildren: superviseChildren,
            childRPCBasePort: effectiveRpcPort,
            childInheritedArguments: childInheritedArgs,
            spawnCertChain: decodedSpawnCertChain
        )
        if !bootstrapEntries.isEmpty,
           let network = await node.network(for: genesisConfig.directory) {
            await network.storeBatch(bootstrapEntries.map { ($0.cid, $0.data) })
        }

        // Skip genesis hash verification for child chains bootstrapped from --genesis-hex
        // (their genesis hash is defined by the parent's deploy, not the mainnet constants),
        // and for dev genesis overrides (which intentionally produce a non-pinned
        // genesis).
        if prebuiltBlock == nil && !usesDevGenesisOverride {
            let expectedHash = effectiveTestnet ? TestnetGenesis.expectedBlockHash : NexusGenesis.expectedBlockHash
            let genesisOk = effectiveTestnet ? TestnetGenesis.verifyGenesis(node.genesisResult) : NexusGenesis.verifyGenesis(node.genesisResult)
            guard genesisOk else {
                print("  FATAL: Genesis block hash mismatch!")
                print("  Expected: \(expectedHash ?? "nil")")
                print("  Got:      \(node.genesisResult.blockHash)")
                print("  This binary may be incompatible with the network.")
                throw ExitCode.failure
            }
        }
        print("  Genesis:     verified \(node.genesisResult.blockHash)")
        print("  Genesis ts:  \(genesisConfig.timestamp)")

        if !effectiveDiscoveryOnly {
            await node.restoreDeployedChildChains()
        }
        // #243: bind the RPC control plane BEFORE node.start() (the only place the
        // identity hits the wire, via ivy.start() + the bootstrap dial). RPC is the
        // LOCAL operator interface (loopback, cookie-auth) and reads the already-
        // constructed node object — it never needs a started P2P stack — so binding
        // it here means `chain/info` etc. answer as soon as the node exists, instead
        // of after the P2P handshake/bootstrap-dial latency that node.start() incurs.
        var rpcServer: RPCServer? = nil
        var rpcTask: Task<Void, any Error>? = nil
        if !effectiveDiscoveryOnly, let rpcPort = effectiveRpcPort {
            // cookie auth is unconditional. Admin/state-changing endpoints
            // require a presented-and-validated cookie credential regardless of bind
            // address — loopback is NOT treated as authentication. The cookie is
            // generated by default (Bitcoin Core posture) so a default-launched
            // loopback node is not open to any local process / CSRF-driven browser.
            let cookiePath = dataDirURL.appendingPathComponent(".cookie")
            let cookieAuth = try CookieAuth.generate(at: cookiePath)
            print("  RPC auth:    cookie (\(cookiePath.path))")
            let server = RPCServer(node: node, port: rpcPort, bindAddress: effectiveRpcBind, allowedOrigin: effectiveRpcAllowedOrigin, auth: cookieAuth, trustProxyHeaders: effectiveRpcTrustProxyHeaders)
            rpcServer = server
            rpcTask = Task { try await server.run() }
            print("  RPC server:  http://localhost:\(rpcPort)/api/chain/info")
        }

        // The per-process child already has its genesis state stored by LatticeNode.init
        // via buildGenesis + storeBlockRecursively. No external bootstrap pinning needed.
        try await node.start()

        // Item 2: start the continuous supervised-child reconcile loop. It drives every
        // non-detached deployed child to REGISTERED — adopting a child still alive after
        // a parent crash, recovering a dead one, and force-restarting a wedged one past
        // the health grace — re-evaluating each interval rather than once at startup.
        if superviseChildren, !effectiveDiscoveryOnly {
            await node.startSupervisedReconcileLoop()
        }

        if !effectiveDiscoveryOnly {
            let mempoolLoader = MempoolPersistence(dataDir: dataDirURL)
            let savedTxs = mempoolLoader.load()
            if !savedTxs.isEmpty {
                let nexusDir = NexusGenesis.config.directory
                if let network = await node.network(for: nexusDir) {
                    var restored = 0
                    for serialized in savedTxs {
                        let bodyHeader = HeaderImpl<TransactionBody>(rawCID: serialized.bodyCID)
                        guard let _ = try? await bodyHeader.resolve(fetcher: network.fetcher).node else { continue }
                        let tx = Transaction(signatures: serialized.signatures, body: bodyHeader)
                        switch await node.admitToMempool(transaction: tx, directory: nexusDir) {
                        case .added, .replacedExisting: restored += 1
                        case .rejected: break
                        }
                    }
                    if restored > 0 { print("  Mempool:     \(restored)/\(savedTxs.count) transaction(s) restored from CAS") }
                }
                mempoolLoader.delete()
            }

            let genesisHeight = await node.lattice.nexus.chain.getHighestBlockHeight()
            print("  Chain height: \(genesisHeight)")
        }
        print()

        var backgroundTasks: [Task<Void, Never>] = []
        if effectiveDiscoveryOnly {
            // Seed crawler: scores peers and writes seeds.txt for DNS infrastructure
            if let network = await node.network(for: NexusGenesis.config.directory) {
                let crawler = SeedCrawler(ivy: network.ivy, dataDir: dataDirURL)
                backgroundTasks.append(Task { await crawler.start() })
                print("  Seed crawler: writing \(dataDirURL.path)/seeds.txt")
            }
        } else {
            // Block production runs in the external lattice-miner, which talks to
            // this node over the RPC template/candidate endpoints. The node itself
            // never mines in-process. Each process runs exactly one chain; child
            // chain discovery is handled via --subscribe-p2p, not in-process.
            backgroundTasks.append(startMempoolLoop(node: node))
            backgroundTasks.append(startPinReannounceLoop(node: node, interval: nodeConfig.reannounceInterval))
            backgroundTasks.append(startEvictionLoop(node: node, interval: nodeConfig.evictionInterval))
        }

        // Phase 3: if --subscribe-p2p is set, subscribe to parent chain gossip
        // and extract this chain's blocks from parent blocks as they arrive.
        if let parentP2P = subscribeP2p {
            backgroundTasks.append(startParentChainSubscription(
                node: node,
                parentP2PAddress: parentP2P,
                overrideDirectory: chainDirectory
            ))
            let dir = chainDirectory ?? "default"
            print("  Parent subscription: \(parentP2P) (chain=\(dir))")
        }

        let peerRefreshTask = Task { await node.startPeerRefresh() }

        if effectiveDiscoveryOnly {
            print("  Discovery node running (\(effectiveMaxPeers) max peers). Type 'quit' to stop.")
        } else {
            print("  Node running. Run the external lattice-miner to produce blocks; 'status' for chain info, 'quit' to stop.")
        }
        print()

        let shutdownRequested = ShutdownFlag()

        let signalSources = installSignalHandlers {
            shutdownRequested.set()
        }

        Task.detached {
            while !shutdownRequested.isSet {
                guard let line = readLine(strippingNewline: true) else {
                    await shutdownRequested.wait()
                    return
                }
                let shouldQuit = await handleCommand(line, node: node, state: state)
                if shouldQuit { break }
            }
            shutdownRequested.set()
        }

        await shutdownRequested.wait()
        withExtendedLifetime(signalSources) {}

        print("\n  Shutting down...")
        peerRefreshTask.cancel()
        await rpcServer?.shutdown()
        rpcTask?.cancel()
        // Drain in-flight RPC handlers to COMPLETION before node.stop(). triggerGracefulShutdown
        // (above) stops accepting new connections but returns immediately; without awaiting the
        // task, an already-executing submit-work handler (no cancellation checks on that actor
        // path) can still enter withChainMutation AFTER node.stop()'s gate-drain runs, advancing
        // the in-memory tip past the durable commit and re-introducing the persisted-phantom-tip
        // divergence the drain is meant to prevent. Awaiting here makes "no new mutation starts
        // after shutdown" actually true for the RPC mutation source (bounded: only in-flight
        // handlers remain once new connections are refused).
        try? await rpcTask?.value
        for task in backgroundTasks { task.cancel() }
        for task in backgroundTasks { await task.value }

        if !effectiveDiscoveryOnly {
            let mempoolPersistence = MempoolPersistence(dataDir: dataDirURL)
            let nexusDir = NexusGenesis.config.directory
            if let network = await node.network(for: nexusDir) {
                let txs = await network.nodeMempool.allTransactions()
                if !txs.isEmpty {
                    try? mempoolPersistence.save(transactions: txs)
                    print("  Mempool:     \(txs.count) transaction(s) saved")
                }
            }
        }

        let peers = await node.connectedPeerEndpoints()
        await node.peerStore.save(peers, source: "discovered")
        await node.stop()
        print("  \(peers.count) peer(s) saved. Goodbye.")
    }

}

// MARK: - Helpers

private func configureResources(_ args: NodeArgs) -> NodeResourceConfig {
    if args.autosize {
        print("  Autosize:    ON")
        return NodeResourceConfig.autosize(
            dataDir: args.dataDir,
            maxMemoryGB: args.maxMemoryGB,
            maxDiskGB: args.maxDiskGB
        )
    }
    return NodeResourceConfig(
        memoryBudgetGB: args.memoryGB,
        diskBudgetGB: args.diskGB,
        mempoolBudgetMB: args.mempoolMB,
        miningBatchSize: args.miningBatch
    )
}

private func loadPeers(dataDirURL: URL, bootstrapPeers: [PeerEndpoint], fallbackPeers: [PeerEndpoint] = BootstrapPeers.nexus) async -> [PeerEndpoint] {
    var allPeers = bootstrapPeers
    if allPeers.isEmpty {
        allPeers = fallbackPeers
    }
    let peerStore = PeerStore(dataDir: dataDirURL)
    let savedPeers = await peerStore.load()
    let existingKeys = Set(allPeers.map { $0.publicKey })
    for peer in savedPeers where !existingKeys.contains(peer.publicKey) {
        allPeers.append(peer)
    }
    return allPeers
}

func parsePeer(_ s: String) -> PeerEndpoint? {
    let parts = s.split(separator: "@", maxSplits: 1)
    guard parts.count == 2 else { return nil }
    let pubKey = String(parts[0])
    let hostPort = parts[1].split(separator: ":", maxSplits: 1)
    guard hostPort.count == 2, let port = UInt16(hostPort[1]) else { return nil }
    return PeerEndpoint(publicKey: pubKey, host: String(hostPort[0]), port: port)
}

private final class ShutdownFlag: Sendable {
    private let _value = Mutex(false)

    var isSet: Bool { _value.withLock { $0 } }

    func set() { _value.withLock { $0 = true } }

    func wait() async {
        while !isSet {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}

private func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) -> (DispatchSourceSignal, DispatchSourceSignal) {
    let queue = DispatchQueue(label: "lattice.signal")
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let src1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
    let src2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    src1.setEventHandler(handler: handler)
    src2.setEventHandler(handler: handler)
    src1.resume()
    src2.resume()
    return (src1, src2)
}
