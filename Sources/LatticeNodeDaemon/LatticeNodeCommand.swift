import ArgumentParser
import Crypto
import Foundation
import Hummingbird
import ServiceLifecycle
import Ivy
import Lattice
import LatticeNode
import LatticeNodeCore
import UInt256
import VolumeBroker
import LatticeNodeAPI

@main
struct LatticeNodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-node",
        abstract: "Run one Nexus-rooted hosted tree",
        version: LatticeNodeVersion.current
    )

    @Option(help: "A host root made by `lattice init`: the node runs as <root>/lattice.json and the fragments in <root>/config.d say together (storage, identity, ports, hosted chains...), reads them again on SIGHUP and when a fragment changes through its operator API (PUT /config/fragments/<name>), and applies each change live or at the next restart. Give no other flag with it.")
    var root: String?

    @Option(help: "Hosted-tree storage directory; defaults to ~/.lattice/chains/Nexus")
    var dataDirectory: String?

    @Option(help: "Process identity key file; created with mode 0600 when absent")
    var identityKey: String?

    @Option(name: .customLong("host-chain"), help: "A child chain to host as a level of this storage, e.g. Nexus/Alpha, optionally =<spec.json> to mine its genesis (repeatable; a parent before its children)")
    var hostChain: [String] = []

    @Option(name: .customLong("premine-to"), help: "The account a hosted child's genesis pays its spec's premine to, as chain-path=address, e.g. Nexus/Alpha=<address> (repeatable). The chain must be hosted with a spec (--host-chain path=spec.json); without one, its genesis pays no premine.")
    var premineTo: [String] = []

    @Option(name: .customLong("genesis-transactions"), help: "Signed transactions a hosted child's genesis carries after its premine, as chain-path=file.json, the file a JSON array of what POST /transactions takes (repeatable, one file per chain). The chain must be hosted with a spec; the transactions must be signed by their signers, move no coins, and pass the spec's policies.")
    var genesisTransactions: [String] = []

    @Option(name: .customLong("policy-module"), help: "A WASM policy module a hosted child's spec names by CID (repeatable). Stored at start, so the node can store the genesis it mines from that spec.")
    var policyModule: [String] = []

    @Option(help: "Hosted-tree overlay listen port")
    var listenPort: UInt16 = 4001

    @Option(help: "Loopback HTTP API port")
    var rpcPort: UInt16 = 8080

    @Option(name: .customLong("websocket-port"), help: "Port for peers that cannot open a TCP connection (browsers): overlay sessions over WebSocket at ws://<host>:<port>/ivy on TCP, and STUN on UDP, which is where a browser learns its own address before it connects to another browser. While it listens the node relays between its peers. Open both TCP and UDP. There is no TLS: terminate wss in a proxy in front, and pass UDP on the port browsers dial through to this one. Left out, the node listens on \(WebSocketListener.defaultPort) if it can bind it and starts without if it cannot; given, failing to bind is an error. 0 turns it off.")
    var webSocketPort: UInt16?

    @Option(name: .customLong("websocket-url"), help: "The ws:// or wss:// URL browsers dial for the WebSocket listener, e.g. wss://node.example.org/ivy through a proxy that ends TLS: advertised to peers, and in provider records, as where browsers reach this node. Unset: the node advertises a connected peer's own URL, to be reached by relaying through that peer.")
    var webSocketUrl: String?

    @Option(help: "HTTP bind address; only loopback addresses are accepted")
    var rpcBind = "127.0.0.1"

    @Option(help: "Where the node writes its loopback RPC cookie at every start (mode 0600, a fresh secret each time, removed at exit). Every loopback route but GET/HEAD /health requires it, as Authorization: Basic base64(\"__cookie__:<token>\") (the file's content) or Bearer <token>. Defaults to <data-directory>/.cookie; give each node its own.")
    var rpcCookieFile: String?

    @Option(name: .customLong("rpc-allowed-origin"), help: "A browser origin allowed on the loopback RPC port, exactly as the browser sends it, e.g. chrome-extension://<id> (repeatable). Requests with any other Origin are refused; an allowed origin gets CORS preflight answers and still needs the cookie.")
    var rpcAllowedOrigins: [String] = []

    @Option(name: .customLong("operator-listen"), help: "host:port of an operator listener for clients on other machines, e.g. 10.0.0.5:8090. It serves the loopback API's routes, each request carrying Authorization: Bearer <token> for a token in --operator-tokens allowed that route; the cookie is not accepted there, and nothing sent there may name a file on this node's disk. Plain HTTP: put it on a private network or behind a TLS proxy. Requires --operator-tokens.")
    var operatorListen: String?

    @Option(name: .customLong("operator-tokens"), help: "The --operator-listen tokens: a JSON array of {\"name\", \"sha256\": hex SHA-256 of the token, and \"role\": \"admin\" or \"read\", or \"routes\": [\"PUT /config/fragments/{name}\", ...]}. Created by the first POST /tokens when absent; changed through /tokens while the node runs.")
    var operatorTokens: String?

    @Option(name: .customLong("operator-allowed-origin"), help: "A browser origin allowed on the --operator-listen listener, exactly as the browser sends it, e.g. https://dashboard.example (repeatable). Requests with any other Origin are refused; an allowed origin gets CORS answers and still needs a token.")
    var operatorAllowedOrigins: [String] = []

    @Option(parsing: .upToNextOption, help: "Overlay peer as public-key@host:port. Any peer given here REPLACES the built-in default bootstrap peers; the two are never merged.")
    var peer: [String] = []

    @Option(help: "An extra seed for a hosted child chain, as chain-path=public-key@host:port, e.g. Nexus/testnet=<key>@node.example:4001 (repeatable). Beside what the chain finds through its parent: dialled only while that chain has too few peers after the ones it remembers and its lookup, and remembered like any peer once reached. The chain must be hosted (--host-chain).")
    var chainPeer: [String] = []

    @Option(help: "With fewer current peers than this, a hosted chain dials peers it remembers. Applies to each chain on its own.")
    var peerTarget = 8

    @Option(help: "With fewer current peers than this, a hosted chain dials its seeds: the built-in ones for Nexus, its --chain-peer list for a child. Applies to each chain on its own.")
    var peersBeforeSeeds = 2

    @Flag(help: "Start with no built-in default bootstrap peers. Without --peer this means no bootstrap peers at all; the node then finds peers only through discovery or inbound connections.")
    var noDefaultPeers = false

    @Option(help: "Minimum overlay peer-key work bits")
    var minimumPeerKeyBits = 0

    @Option(help: "Per-netgroup overlay connection cap (both directions). Defaults to the total connection cap (no effective throttle): a low value breaks proxy-fronted nodes where every connection shares one address, and buys little since bad data is rejected on verification and outbound sync slots are separately reserved. For a real per-source admission cost on a public direct-IP node, set --minimum-peer-key-bits (a grinding price) instead of lowering this.")
    var overlayMaxConnectionsPerNetgroup = IvyConfig.defaultMaxConnections

    @Option(help: "Content requests this node serves to peers at once, all combined. Past the limits requests wait rather than being refused, and freed slots are shared by weight, favouring peers that have served this node verified content; a peer with none still advances.")
    var servingMaxConcurrent = 64

    @Option(help: "Bytes of Volumes this node reads or sends to peers at once.")
    var servingMaxInFlightVolumeBytes = IvyConfig.defaultMaxInFlightVolumeBytes

    @Option(help: "Bytes of fetched content this node's fetches hold in memory at once, every hosted chain together: each fetch reserves its worst case (its chain's maxBlockSize, at most 67108864) when it starts and releases it when it ends. Past it, fetches wait in line (the node's own work and the blocks each chain can connect next first); nothing asked for is declined for it. It bounds what fetches reserve, not every copy: a fetch's walk makes transient copies it does not count (about 1 to 1.5 times the body), so it is not a hard limit on the process's memory. A quarter of it more keeps verified content for later reads, the fetched bodies furthest from their chain's next block to connect evicted first. At least 67108864, the bytes one block's fetch may hold.")
    var maxAcquisitionBytes = NodeResourcePolicy.defaultMaximumAcquisitionBytes

    @Option(help: "Which block bodies (a block's own Volume and its transactions') this node keeps beyond the ones it needs to operate: all, or none. It always holds the bodies waiting to execute, each chain's tip, and each genesis block. With none, a body is let go of once another block is the tip, and is no longer served; headers, facts and state stay, so what the node weighs and selects does not change. A node that syncs from genesis needs peers that keep all.")
    var blockBodies = "all"

    @Option(help: "Which state this node keeps: all, the state of every block it executed; recent, the whole current state of each chain and what its last --state-window blocks replaced; or none, what the executions of each chain's tip block read and created (a window of 1), and blocks above the tip until it passes them. Kept state is a cache: execution, a submitted transaction's check and reads all read from peers the state this node does not hold, so recent and none answer the same as all, a read of state they let go of costing a fetch. On recent a node counts the places each node of the state holds and keeps what it counts; a chain with no counts (the first start on recent, a chain newly hosted), or a reorganization deeper than the window, gets a state sync, which reads the current state the node lacks from peers. A network needs nodes on all to serve what the others let go of, and a node that syncs from genesis needs peers that keep all. tip, the earlier name, means recent.")
    var state = "all"

    @Option(help: "Seconds with no newly accepted block on a hosted chain after which the node widens that chain's peer search: Nexus re-dials configured peers without a session, a child chain looks up its providers, and either dials peers it remembers. The node also announces each hosted child chain. Staleness is measured from the verified local tip. Discovery never affects validation or fork choice. 0 disables search.")
    var peerSearchInterval: Double = 600

    @Option(help: "Seconds each provider announcement lasts: each hosted chain's and each pinned Volume's. The node renews them at least every 10 minutes (every --peer-search-interval when shorter), so a lifetime shorter than that leaves gaps in which peers cannot find this node as a provider. At most 86400: peers drop announcements that last longer.")
    var announceLifetime: UInt64 = 1_200

    @Option(help: "Ready blocks of one chain the node executes per job, each the previous one's child, with one commit for them all, as Bitcoin Core connects up to 32 per step. A larger batch commits less often during a sync and holds more executed state in memory until its commit; a crash loses at most the batch being executed, which runs again. At least 1.")
    var connectBatch = NodeConfiguration.defaultConnectBatch

    @Flag(inversion: .prefixedNo, help: "Announce each pinned Volume as a provider record, on pinning and on every renewal. With --no-announce-pins pins are held and served but never announced: for a holder of many Volumes whose readers do not need a record per Volume.")
    var announcePins = true

    @Option(help: "Overlay sessions provider walks may dial to reach the peers closest to what this node announces or looks up. 0 keeps announcements and lookups among already-connected peers: no dials, less reach, and every new session is told again. Reserved outbound sync slots are never used.")
    var providerWalkSessions = IvyConfig.defaultMaxProviderWalkSessions

    @Option(help: "Public read-only HTTP port; binds all interfaces and serves ONLY the bounded GET read routes (the read-replica allowlist, enforced in code). Chain data is public; this exposes no operator or write surface.")
    var publicReadPort: UInt16?

    @Option(help: ArgumentHelp("Ignored: per-client read limits were removed. Accepted so existing configurations keep starting.", visibility: .hidden))
    var publicReadRate: Double?

    @Option(help: ArgumentHelp("Ignored: per-client read limits were removed. Accepted so existing configurations keep starting.", visibility: .hidden))
    var publicReadExpensiveRate: Double?

    @Option(help: "Listener-wide arrival-rate ceiling for the public read port, in requests per second. 0 disables it; with --public-submit-rate 0 too, there is no rate limiting at all.")
    var publicReadMaxRate = PublicReadRateLimits.defaultListenerRate

    @Option(help: "Volumes the public read port reads from peers at once for readers when this node does not hold them. Each is checked against its CID, served, and not kept; readers asking for the same Volume share one read, and past this many a reader waits, first come first served, for a place (up to 30 s, then 503). At most as many run as fit, at 64 MiB each, in half of --serving-max-in-flight-volume-bytes (and at least one), so the node's own sync keeps the other half. 0: the port serves only the Volumes this node holds.")
    var publicReadFetches = 4

    @Option(help: "This host's public read URL (absolute https:// or http://, e.g. https://reads.example.org), declared for EVERY level it hosts: peers asking for a hosted level's read endpoint get it, and each hosted child chain is announced so a node hosting its parent can list it at /api/chain/endpoints. Unset: nothing is declared or announced.")
    var publicReadUrl: String?

    @Flag(help: "Also accept POST /transactions on the public read port (operator choice; default off). Same body and answer as the loopback route, body capped, its own listener rate budget (--public-submit-rate); a public submit is never journaled and is admitted under the pool's ordinary capacity rules, with no local priority. Declared beside --public-read-url to peers. Requires --public-read-port.")
    var publicSubmit = false

    @Option(help: "Listener-wide arrival-rate ceiling for public POST /transactions, in requests per second, separate from the read budget. 0 disables it.")
    var publicSubmitRate = PublicReadRateLimits.defaultSubmitRate

    @Option(help: "The smallest fee (a transaction's balance excess) this node admits to its pool, at every hosted level. Node relay policy, never consensus: blocks carrying cheaper transactions stay valid. Reported as minRelayFee by GET /api/chain/info. 0 admits any fee, and pool space is then free to hold.")
    var minRelayFee: UInt64 = 1

    @Option(name: .customLong("finality-window"), help: "Node-local finality, in blocks: headers and work more than this many blocks below a chain's best tip are declined — never stored, never blamed. A fork from a block that deep can never connect, which keeps out the blocks an easy schedule makes nearly free: a fork d blocks deep is at most 2^(d / halfLife) cheaper than the tip, so a few half-lives is enough. The cost is this node's own: it will not follow a reorganization deeper than the window, even a heavier one, until its operator intervenes. A bare number sets every hosted chain; chain-path=blocks sets one chain, e.g. Nexus/Alpha=500, and 0 turns it off there (repeatable). Without it, everything is kept. A child chain's window should be at least its parent's: a parent reorganization can reorganize the child.")
    var finalityWindow: [String] = []

    @Option(name: .customLong("state-window"), help: "With --state recent, how many of a chain's blocks, counting its tip, have what they replaced kept beside the whole current state: a reorganization that deep is undone without a fetch, and a deeper one gets a state sync. A bare number sets every hosted chain; chain-path=blocks sets one chain, e.g. Nexus/Alpha=500 (repeatable). At least 1. Default 64.")
    var stateWindow: [String] = []

    @Option(help: "Self-described publicly reachable host for overlay announcements (NAT/proxy-fronted nodes announce an unreachable observed address otherwise). Host only; the overlay listen port applies.")
    var externalAddress: String?

    mutating func run() async throws {
        guard let root else {
            try await start(owner: nil)
            return
        }
        // Caught from the start: a SIGHUP before the node can reload is kept
        // for when it can, not the end of the process.
        Hangups.shared.install()
        // Only `--root` (and its value) on the command line: everything else
        // comes from lattice.json and config.d.
        let given = CommandLine.arguments.dropFirst()
        guard given.allSatisfy({ !$0.hasPrefix("-") || $0 == "--root" || $0.hasPrefix("--root=") }) else {
            throw configurationFault("--root takes every setting from lattice.json and config.d; give no other flag with it")
        }
        let layout = HostLayout(root: root)
        let merged: MergedConfig
        do {
            merged = try MergedConfig.load(root: layout.root)
        } catch {
            throw configurationFault("\(layout.root.path): \(error). The node starts only from a configuration that checks.")
        }
        if Topology.holdsRetiredMining(root: layout.root) {
            logLine("warning: \(Topology.retiredMiningWarning)")
        }
        try performRequestedWipe(layout)
        for note in merged.inert { logLine("configuration: \(note)") }
        let topology = merged.topology
        var command: LatticeNodeCommand
        do {
            command = try LatticeNodeCommand.parse(topology.nodeArguments(layout: layout))
        } catch {
            throw configurationFault(LatticeNodeCommand.message(for: error))
        }
        try await command.start(owner: NodeOwner(layout: layout, merged: merged))
    }

    /// A configuration the node cannot start from: said, then the exit status
    /// that tells a process manager so (78, sysexits' EX_CONFIG).
    private func configurationFault(_ reason: String) -> ExitCode {
        logLine("lattice-node: \(reason)")
        return ExitCode(exitConfigurationError)
    }

    /// Runs the node with these flags; `owner` is the host root and the
    /// configuration it was started from, when it runs under `--root`.
    mutating func start(owner: NodeOwner?) async throws {
        if let openFiles = OpenFileLimit.raise() { logLine("lattice-node: open files allowed: \(openFiles)") }
        let processStartTime = Date()
        let address = ChainAddress([ChainAddress.nexus])!
        // A fault in lattice.json (`--root`) is the configuration's: 78. One
        // in the flags is the command line's: 64, as ArgumentParser exits.
        let isOwned = owner != nil
        func fault(_ reason: String) -> Error {
            isOwned ? configurationFault(reason) : ValidationError(reason)
        }
        let plan: StartPlan
        do { plan = try self.plan() } catch { throw fault("\(error)") }
        let storage = try storageURL(for: address)
        let keyURL = identityKey.map { URL(fileURLWithPath: $0) }
            ?? storage.appendingPathComponent("storage.key")
        let privateKeyHex = try loadOrCreateIdentity(at: keyURL)
        // An operator peer source is authoritative: a supplied list replaces
        // the built-in defaults, and --no-default-peers expresses the empty
        // one. Only "nothing configured at all" falls back to the defaults.
        let configuredPeers = plan.explicitPeers.isEmpty && !noDefaultPeers ? nil : plan.explicitPeers
        if DefaultBootstrapPeers.forbidden(
            configured: configuredPeers,
            environment: ProcessInfo.processInfo.environment
        ) {
            throw fault(
                "\(DefaultBootstrapPeers.forbidEnvironmentKey)=1: pass --peer or --no-default-peers"
            )
        }
        // The operator's own peers are configured: dialled from the start and
        // kept. With none configured, the built-in peers are seeds: tried
        // only while the node has too few peers after the ones it remembers.
        let seedPeers = configuredPeers == nil
            ? DefaultBootstrapPeers.resolved(chainPath: address.components, configured: nil)
            : []
        // Behind the seeds by name, the same seeds at fixed addresses.
        let fixedSeedPeers = seedPeers.isEmpty ? [] : DefaultBootstrapPeers.nexusFixed
        let overlayPeers = configuredPeers ?? []
        let hosted = plan.hosted
        let webSocket = plan.webSocket, blockBodies = plan.blockBodies, state = plan.state
        let publicReadLimits = plan.publicReadLimits, operatorListener = plan.operatorListener
        let configuration: NodeConfiguration
        do {
            configuration = try NodeConfiguration(
                chainPath: address.components,
                storagePath: storage,
                privateKeyHex: privateKeyHex,
                listenPort: listenPort,
                rpcPort: rpcPort,
                webSocket: webSocket,
                bootstrapPeers: overlayPeers,
                seedPeers: seedPeers,
                fixedSeedPeers: fixedSeedPeers,
                childSeedPeers: hosted.seedPeers,
                peerTarget: peerTarget,
                peersBeforeSeeds: peersBeforeSeeds,
                minPeerKeyBits: minimumPeerKeyBits,
                overlayMaxConnectionsPerNetgroup: overlayMaxConnectionsPerNetgroup,
                contentServing: ContentServingLimits(
                    maxConcurrent: servingMaxConcurrent,
                    maxInFlightVolumeBytes: servingMaxInFlightVolumeBytes
                ),
                externalAddress: externalAddress,
                peerSearchInterval: peerSearchInterval,
                announceLifetime: announceLifetime,
                announcePins: announcePins,
                providerWalkSessions: providerWalkSessions,
                resourcePolicy: NodeResourcePolicy(maximumAcquisitionBytes: maxAcquisitionBytes),
                blockBodies: blockBodies,
                state: state,
                hostedChildren: hosted.children,
                childSpecs: hosted.specs,
                childPremineRecipients: hosted.premineRecipients,
                childGenesisTransactions: hosted.genesisTransactions,
                policyModules: hosted.policyModules,
                publicReadURL: publicReadUrl,
                webSocketURL: webSocketUrl,
                publicSubmit: publicSubmit,
                minRelayFee: minRelayFee,
                finality: plan.finality,
                stateWindows: plan.stateWindows,
                connectBatch: connectBatch
            )
        } catch {
            throw fault("\(error)")
        }
        let cookieFile = rpcCookieFile.map { URL(fileURLWithPath: $0) }
            ?? storage.appendingPathComponent(".cookie")
        try await runNodeRuntime(
            configuration: configuration,
            cookieFile: cookieFile,
            operatorListener: operatorListener,
            owner: owner,
            publicReadLimits: publicReadLimits,
            processStartTime: processStartTime
        )
    }

    /// What a start makes of its flags, checked without touching storage,
    /// identity or ports: what `start` runs from, and what a configuration
    /// change or restart is checked against before it is taken.
    struct StartPlan {
        let webSocket: WebSocketListener
        let operatorListener: OperatorListener?
        let blockBodies: BlockBodies
        let state: StateRetention
        let publicReadLimits: PublicReadRateLimits
        let explicitPeers: [PeerEndpoint]
        let finality: FinalityWindows
        let stateWindows: FinalityWindows
        let hosted: HostedChildren
    }

    func plan() throws -> StartPlan {
        guard ["127.0.0.1", "::1", "localhost"].contains(rpcBind.lowercased()) else {
            throw ValidationError("the operator HTTP API may bind only to loopback")
        }
        if let publicReadPort {
            guard publicReadPort != rpcPort else {
                throw ValidationError("--public-read-port must differ from --rpc-port")
            }
        }
        let webSocket: WebSocketListener
        switch webSocketPort {
        case 0:
            webSocket = .off
        case let port?:
            guard port != publicReadPort else {
                throw ValidationError("--websocket-port must differ from --public-read-port")
            }
            webSocket = .required(port)
        case nil:
            webSocket = publicReadPort == WebSocketListener.defaultPort
                ? .off : .ifAvailable(WebSocketListener.defaultPort)
        }
        guard webSocketUrl == nil || webSocket != .off else {
            throw ValidationError("--websocket-url needs the WebSocket listener: it names where browsers reach it")
        }
        guard (operatorListen == nil) == (operatorTokens == nil) else {
            throw ValidationError("--operator-listen and --operator-tokens go together")
        }
        guard operatorAllowedOrigins.isEmpty || operatorListen != nil else {
            throw ValidationError("--operator-allowed-origin requires --operator-listen")
        }
        let operatorListener = try operatorListen.map { listen -> OperatorListener in
            guard let (host, port) = Topology.hostPort(listen), Topology.isAddressLiteral(host) else {
                throw ValidationError("--operator-listen must be address:port, the address an IPv4 or IPv6 literal ([::1]:8090) or localhost")
            }
            guard port != rpcPort, port != publicReadPort, port != listenPort, port != webSocketPort else {
                throw ValidationError("--operator-listen must use a port of its own")
            }
            return OperatorListener(
                host: host, port: Int(port),
                tokens: try TokenStore(file: URL(fileURLWithPath: operatorTokens!)),
                allowedOrigins: Set(operatorAllowedOrigins)
            )
        }
        if publicSubmit, publicReadPort == nil {
            throw ValidationError("--public-submit requires --public-read-port")
        }
        guard publicReadFetches >= 0 else {
            throw ValidationError("--public-read-fetches must be nonnegative")
        }
        let sessionBytes = NodeResourcePolicy.default.maximumAcquisitionStorageBytes
        guard maxAcquisitionBytes >= sessionBytes else {
            throw ValidationError("--max-acquisition-bytes must be at least \(sessionBytes), the bytes one block's fetch may hold")
        }
        guard connectBatch >= 1 else {
            throw ValidationError("--connect-batch must be at least 1")
        }
        guard let blockBodies = BlockBodies(rawValue: blockBodies) else {
            throw ValidationError("--block-bodies is all or none")
        }
        guard let state = StateRetention(named: state) else {
            throw ValidationError("--state is all, recent or none")
        }
        guard stateWindow.isEmpty || state == .recent else {
            throw ValidationError("--state-window applies to --state recent only")
        }
        if publicReadRate != nil { print("warning: --public-read-rate is ignored (per-client read limits were removed)") }
        if publicReadExpensiveRate != nil { print("warning: --public-read-expensive-rate is ignored (per-client read limits were removed)") }
        let publicReadLimits = try PublicReadRateLimits.validated(
            listenerRate: publicReadMaxRate,
            submitRate: publicSubmitRate
        )

        let explicitPeers = try peer.map(parsePeerEndpoint)
        let hosted = try HostedChildren(
            hostChain: hostChain, premineTo: premineTo, genesisTransactions: genesisTransactions,
            chainPeer: chainPeer, policyModule: policyModule
        )
        return StartPlan(
            webSocket: webSocket, operatorListener: operatorListener, blockBodies: blockBodies, state: state,
            publicReadLimits: publicReadLimits, explicitPeers: explicitPeers,
            finality: try windows(finalityWindow, option: "--finality-window", zeroIsOff: true),
            stateWindows: try windows(stateWindow, option: "--state-window", zeroIsOff: false),
            hosted: hosted
        )
    }

    /// A per-chain window option's values (`--finality-window`,
    /// `--state-window`): a bare number of blocks for every chain, or
    /// chain-path=blocks for one. 0 turns a finality window off, and is no
    /// state window.
    private func windows(_ values: [String], option: String, zeroIsOff: Bool) throws -> FinalityWindows {
        func blocks(_ text: Substring) throws -> UInt64? {
            guard let blocks = UInt64(text), zeroIsOff || blocks > 0 else {
                throw ValidationError(zeroIsOff
                    ? "\(option) takes blocks, or chain-path=blocks"
                    : "\(option) takes at least 1 block, or chain-path=blocks")
            }
            return blocks > 0 ? blocks : nil
        }
        var windows = FinalityWindows()
        var sawDefault = false
        for value in values {
            if let split = value.firstIndex(of: "=") {
                let components = value[..<split].split(separator: "/").map(String.init)
                guard let address = ChainAddress(components) else {
                    throw ValidationError("\(option): \(value[..<split]) is not a chain path")
                }
                guard windows.byChain[address.components] == nil else {
                    throw ValidationError("\(option) names \(value[..<split]) twice")
                }
                windows.byChain[address.components] = .some(try blocks(value[value.index(after: split)...]))
            } else {
                guard !sawDefault else { throw ValidationError("\(option) has two defaults") }
                sawDefault = true
                windows.all = try blocks(value[...])
            }
        }
        return windows
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

/// The child chains `--host-chain`, `--premine-to`, `--genesis-transactions`,
/// `--chain-peer` and `--policy-module` name: read the same at start and when
/// its configuration changes on a running node (`OperatorConfig`). Each
/// spec file is read once, so the paths and specs agree.
struct HostedChildren {
    var children: [[String]] = []
    var specs: [[String]: ChainSpec] = [:]
    var premineRecipients: [[String]: String] = [:]
    var genesisTransactions: [[String]: [Transaction]] = [:]
    var seedPeers: [[String]: [PeerEndpoint]] = [:]
    var policyModules: [Data] = []

    init(
        hostChain: [String], premineTo: [String], genesisTransactions genesisFiles: [String] = [],
        chainPeer: [String], policyModule: [String]
    ) throws {
        policyModules = try policyModule.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        for entry in hostChain {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard let first = parts.first else {
                throw ValidationError("--host-chain must name a chain path")
            }
            let path = first.split(separator: "/").map(String.init)
            children.append(path)
            guard parts.count == 2 else { continue }
            guard specs[path] == nil else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: parts[1]))
            specs[path] = try JSONDecoder().decode(ChainSpec.self, from: data)
        }
        for entry in chainPeer {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw ValidationError("--chain-peer must use chain-path=public-key@host:port")
            }
            let path = parts[0].split(separator: "/").map(String.init)
            guard children.contains(path) else {
                throw ValidationError("--chain-peer names \(parts[0]), which is not a hosted chain")
            }
            seedPeers[path, default: []].append(try parsePeerEndpoint(parts[1]))
        }
        for entry in premineTo {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else {
                throw ValidationError("--premine-to must use chain-path=address")
            }
            let path = parts[0].split(separator: "/").map(String.init)
            guard let spec = specs[path] else {
                throw ValidationError("--premine-to names \(parts[0]), which is not a hosted chain with a spec")
            }
            do {
                try NodeRuntime.checkPremine(spec: spec, to: parts[1], on: path, modules: policyModules)
            } catch {
                throw ValidationError("--premine-to \(entry): \(error)")
            }
            premineRecipients[path] = parts[1]
        }
        for entry in genesisFiles {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].isEmpty else {
                throw ValidationError("--genesis-transactions must use chain-path=file.json")
            }
            let path = parts[0].split(separator: "/").map(String.init)
            guard let spec = specs[path] else {
                throw ValidationError("--genesis-transactions names \(parts[0]), which is not a hosted chain with a spec")
            }
            guard genesisTransactions[path] == nil else {
                throw ValidationError("--genesis-transactions names \(parts[0]) twice")
            }
            let transactions: [Transaction]
            do {
                transactions = try JSONDecoder().decode(
                    [SubmitTransactionRequest].self, from: Data(contentsOf: URL(fileURLWithPath: parts[1]))
                ).map(\.transaction)
                try NodeRuntime.checkPremine(
                    spec: spec, to: premineRecipients[path], transactions: transactions, on: path, modules: policyModules
                )
            } catch {
                throw ValidationError("--genesis-transactions \(entry): \(error)")
            }
            genesisTransactions[path] = transactions
        }
    }
}

private func storageComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed)!
}

func loadOrCreateIdentity(at url: URL) throws -> String {
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

func parsePeerEndpoint(_ value: String) throws -> PeerEndpoint {
    let parsed = try parseEndpoint(value)
    return PeerEndpoint(publicKey: parsed.key, host: parsed.host, port: parsed.port)
}

private func parseEndpoint(_ value: String) throws -> (key: String, host: String, port: UInt16) {
    guard let parsed = Topology.peerEndpoint(value) else {
        throw ValidationError("endpoint must use public-key@host:port")
    }
    return parsed
}
/// SIGHUP, caught from the process's start (`install`): one that comes
/// before the node can act on it is kept, and acted on once it can.
final class Hangups: @unchecked Sendable {
    static let shared = Hangups()

    private let lock = NSLock()
    private var source: DispatchSourceSignal?
    private var action: (@Sendable () -> Void)?
    private var missed = false

    func install() {
        lock.withLock {
            guard source == nil else { return }
            signal(SIGHUP, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGHUP)
            source.setEventHandler { [self] in hangUp() }
            source.resume()
            self.source = source
        }
    }

    /// What a SIGHUP does from now on; run at once for one already caught.
    func onHangup(_ action: @escaping @Sendable () -> Void) {
        let caught = lock.withLock { () -> Bool in
            self.action = action
            defer { missed = false }
            return missed
        }
        if caught { action() }
    }

    /// What a caught SIGHUP does (the signal source calls it).
    func hangUp() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            if self.action == nil { missed = true }
            return self.action
        }
        action?()
    }
}
