// Chain-tree evolution: the only two legitimate ways a child exists.
//
// `deploy` runs the full arc against the LOCAL parent process: build the
// self-contained child genesis OFFLINE (empty parentState) → submit ONE signed
// GenesisAction anchor recording its CID in the parent's genesisState → wait for
// the parent to record it → child process active — then records the child in the
// topology. The seed and signed anchor are durable before submission, so an
// interrupted deploy resumes on re-run instead of orphaning a recorded CID.
// `adopt` joins an EXISTING child permissionlessly: the child process
// re-derives its genesis through the authenticated parent link, never from "a
// node that tracks it".

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import Lattice
import LatticeCtlCore
import LatticeNode
import UInt256
import VolumeBroker
import cashew

struct Child: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Deploy a new child chain or adopt an existing one.",
        subcommands: [Deploy.self, Adopt.self]
    )

    struct Deploy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Deploy a new child of a running local parent."
        )

        @OptionGroup var rootOption: RootOption

        @Argument(help: "Child directory name (e.g. Payments).")
        var directory: String

        @Option(name: .long, help: "Parent chain path (default: Nexus).")
        var parent: String = "Nexus"

        @Option(name: .long, help: "ChainSpec JSON file for the child.")
        var spec: String

        @Option(name: .long, help: "Funded key file (lattice-rewards format) signing the anchor transaction.")
        var fund: String

        @Option(name: .long, help: "The funding key's next expected nonce.")
        var nonce: UInt64 = 0

        @Option(name: .long, help: "Anchor transaction fee.")
        var fee: UInt64 = 0

        @Option(name: .long, help: "Credit the child spec's premine to this address in the child genesis.")
        var premineTo: String?

        @Option(name: .long, help: "Wait this many seconds for EXTERNAL mining (a coordinator already running against the parent) to record the anchor, instead of driving local CPU mining rounds. Use on a real-difficulty network where ad-hoc CPU rounds cannot mine a block.")
        var externalMiningWaitSeconds: UInt64 = 0

        func run() async throws {
            let layout = rootOption.layout
            var topology = try Topology.load(root: layout.root).validated()
            guard let parentChain = topology.chains[parent] else {
                throw CtlError("parent \(parent) is not in the tree")
            }
            let childPath = "\(parent)/\(directory)"
            guard topology.chains[childPath] == nil else {
                throw CtlError("\(childPath) is already in the tree")
            }
            let chainSpec = try JSONDecoder().decode(
                ChainSpec.self,
                from: Data(contentsOf: URL(fileURLWithPath: spec))
            )

            // Build the self-contained child genesis OFFLINE: empty parentState,
            // like a root genesis. The parent only RECORDS its CID; it never
            // carries the genesis. The genesisCID is deterministic in the seed
            // (spec + premine + timestamp + max target); the child node rebuilds
            // the identical genesis from the same seed and self-admits it.
            let childComponents = parent.components(separatedBy: "/") + [directory]
            // Once the anchor is submitted the parent may record its CID for
            // good, whether or not this process survives — and the seed (its
            // millisecond timestamp above all) is the only way back to the
            // genesis bytes. So the seed and the exact signed anchor are made
            // durable BEFORE submission, and a re-run for the same child
            // resumes them instead of minting a new genesis.
            let pendingURL = layout.pendingDeploy(for: childPath)
            var resumable: PendingChildDeploy?
            if FileManager.default.fileExists(atPath: pendingURL.path) {
                let loaded = try JSONDecoder().decode(
                    PendingChildDeploy.self,
                    from: Data(contentsOf: pendingURL)
                )
                guard try HeaderImpl(node: loaded.seed.spec).rawCID
                        == HeaderImpl(node: chainSpec).rawCID,
                      loaded.seed.premineTo == premineTo else {
                    throw CtlError("\(childPath) has a pending deploy with a different --spec or --premine-to (\(pendingURL.path)); its anchor may already be on the parent, so re-run with the original arguments to resume it")
                }
                print("resuming pending deploy \(pendingURL.path)")
                resumable = loaded
            }
            let resumed = resumable != nil
            let seed = resumable?.seed ?? ChildGenesisSeed(
                spec: chainSpec,
                premineTo: premineTo,
                timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            )
            let genesisFetcher = CoalescingFetcher(
                CompositeContentSource([MemoryBroker()])
            )
            let genesis = try await ChildGenesisBuilder.build(
                seed: seed,
                chainPath: childComponents,
                fetcher: genesisFetcher
            )
            let genesisCID = try BlockHeader(node: genesis).rawCID

            struct KeyFile: Decodable {
                let privateKey: String
                let publicKey: String
            }
            let key = try JSONDecoder().decode(
                KeyFile.self,
                from: Data(contentsOf: URL(fileURLWithPath: fund))
            )
            let address = CryptoUtils.createAddress(from: key.publicKey)
            let body = TransactionBody(
                accountActions: fee == 0 ? [] : [AccountAction(
                    owner: address, delta: -Int64(fee)
                )],
                actions: [],
                depositActions: [],
                genesisActions: [GenesisAction(
                    directory: directory, blockCID: genesisCID
                )],
                receiptActions: [],
                withdrawalActions: [],
                signers: [address],
                fee: fee,
                nonce: nonce,
                chainPath: [parent].flatMap {
                    $0 == "Nexus" ? ["Nexus"]
                        : $0.components(separatedBy: "/")
                }
            )
            let header = try HeaderImpl(node: body)

            // While --fund, --nonce and --fee still describe the pending
            // anchor it is resubmitted verbatim: a re-signed copy is a rival
            // at the same nonce that the pool refuses. Changed ones re-sign it
            // for the SAME genesis — the only way out of a nonce the key never
            // reaches (pooled as future) or a fee too low to mine. Whichever
            // anchor for this genesis lands, the seed kept here activates it.
            let pending: PendingChildDeploy
            var created: Data?
            if let resumable,
               resumable.anchor.transaction.body.rawCID == header.rawCID {
                pending = resumable
            } else {
                guard let signature = TransactionSigning.sign(
                    bodyHeader: header, privateKeyHex: key.privateKey
                ) else {
                    throw CtlError("anchor signing failed; check the fund key")
                }
                pending = PendingChildDeploy(
                    seed: seed,
                    anchor: SubmitTransactionRequest(transaction: Transaction(
                        signatures: [key.publicKey: signature], body: header
                    ))
                )
                let encoded = try JSONEncoder().encode(pending)
                if resumed {
                    try writeDurably(encoded, to: pendingURL)
                    print("re-signed the pending anchor for the changed --fund, --nonce or --fee")
                } else {
                    // Exclusive: a concurrent deploy of this child may have
                    // written its own seed since the check above.
                    guard try createDurably(encoded, at: pendingURL) else {
                        throw CtlError("another deploy of \(childPath) started at the same time and holds \(pendingURL.path); this run submitted nothing, so re-run to resume that deploy")
                    }
                    created = encoded
                }
            }
            print("genesis \(genesisCID)")
            print("seed \(String(decoding: try JSONEncoder().encode(seed), as: UTF8.self))")
            // Flushed: a killed process never flushes buffered stdout.
            fflush(nil)

            // A resumed anchor may already be recorded (skip submission), or
            // still pooled, or never accepted: resubmitting the identical
            // transaction covers both — the pool already holds it, or takes it.
            var recorded = false
            if resumed {
                recorded = await parentRecordedGenesis(
                    rpc: parentChain.rpc,
                    directory: directory,
                    genesisCID: genesisCID
                )
            }
            if !recorded {
                struct SubmitResponse: Decodable { let transactionCID: String }
                do {
                    let submitted: SubmitResponse = try await post(
                        rpc: parentChain.rpc, path: "v1/transactions",
                        body: pending.anchor
                    )
                    print("anchor \(submitted.transactionCID)")
                    fflush(nil)
                } catch let refusal as CtlError {
                    // The parent answered and refused. A fresh anchor never
                    // left this process, so nothing can ever record it. A
                    // resumed one may have been refused only because it just
                    // landed; otherwise it stays pending for the operator.
                    if let created {
                        // Only if the file is still this run's own seed.
                        removeIfUnchanged(pendingURL, expected: created)
                        throw CtlError("the parent refused the genesis anchor; nothing was recorded: \(refusal)")
                    }
                    guard await parentRecordedGenesis(
                        rpc: parentChain.rpc,
                        directory: directory,
                        genesisCID: genesisCID
                    ) else {
                        throw CtlError("the parent refused the pending genesis anchor (\(refusal)); it stays pending at \(pendingURL.path). Re-run with a corrected --nonce, a higher --fee or another --fund to re-sign it for the same genesis")
                    }
                    recorded = true
                } catch {
                    throw CtlError("submitting the genesis anchor failed (\(error.localizedDescription)) and it may still have reached the parent; it stays pending at \(pendingURL.path), so re-run the same command to resume it")
                }
            }

            // The anchor is now an ordinary mempool transaction: a NORMAL
            // parent block writes `directory -> genesisCID` into the parent's
            // committed genesisState. Nothing else mines it here, so the CLI
            // drives that mining itself — one NORMAL-mode `--once` round per
            // iteration (no `--deployment`: a self-contained genesis is not a
            // deployment subtree) — until the parent has durably recorded the
            // CID. The child is recorded only then.
            //
            // Mine the TREE ROOT, not the immediate parent: a child chain's
            // block is co-mined from the root, whose round cascades carriers
            // down to the immediate parent (where the anchor mempool and the
            // genesisState record live). For a direct child root == parent;
            // for a grandchild they differ, so mining the parent would never
            // advance it. The gate below still checks the immediate parent.
            let rootPath = parent.components(separatedBy: "/")[0]
            guard let rootChain = topology.chains[rootPath] else {
                throw CtlError("the tree has no \(rootPath) root to mine from")
            }
            let worker = try nodeBinary().deletingLastPathComponent()
                .appendingPathComponent("lattice-miner")
            if !recorded, externalMiningWaitSeconds > 0 {
                // The anchor is an ordinary mempool transaction; on a network
                // with real miners the next parent block records it. Poll only.
                let deadline = Date().addingTimeInterval(
                    TimeInterval(externalMiningWaitSeconds)
                )
                while Date() < deadline {
                    if await parentRecordedGenesis(
                        rpc: parentChain.rpc,
                        directory: directory,
                        genesisCID: genesisCID
                    ) {
                        recorded = true
                        break
                    }
                    try await Task.sleep(for: .seconds(10))
                }
            } else if !recorded {
                for _ in 0..<20 {
                    let coordinator = Process()
                    coordinator.executableURL = try nodeBinary()
                        .deletingLastPathComponent()
                        .appendingPathComponent("lattice-mining-coordinator")
                    coordinator.arguments = [
                        "--node", "http://127.0.0.1:\(rootChain.rpc)",
                        "--worker-executable", worker.path,
                        "--workers", "1", "--once",
                    ]
                    // Fresh /dev/null per spawn: corelibs closes the shared
                    // nullDevice singleton's fd after a process exits, so
                    // reusing it across the loop throws EBADF.
                    let devNull = FileHandle(forWritingAtPath: "/dev/null")
                    coordinator.standardOutput = devNull ?? FileHandle.nullDevice
                    coordinator.standardError = devNull ?? FileHandle.nullDevice
                    try coordinator.run()
                    coordinator.waitUntilExit()
                    try? devNull?.close()
                    if await parentRecordedGenesis(
                        rpc: parentChain.rpc,
                        directory: directory,
                        genesisCID: genesisCID
                    ) {
                        recorded = true
                        break
                    }
                    try await Task.sleep(for: .seconds(2))
                }
            }
            guard recorded else {
                throw CtlError("the genesis anchor was not recorded yet; the child was NOT added. It stays pending at \(pendingURL.path): re-run the same command to keep waiting, or re-run with a corrected --nonce or a higher --fee to re-sign the anchor for the same genesis")
            }
            // Seed the child's data directory with the genesis inputs so its node
            // rebuilds the identical self-contained genesis and self-admits it on
            // startup (the parent has already recorded the CID above). This
            // precedes the topology entry: a re-run refuses a child already in
            // the tree, so the tree must never list a child without its seed.
            let childData = layout.chainDirectory(for: childPath)
            try writeDurably(
                JSONEncoder().encode(seed),
                to: childData.appendingPathComponent("child-genesis.json")
            )
            let ports = nextFreePorts(topology)
            topology.chains[childPath] = TopologyChain(
                listen: ports.0, fact: ports.1, rpc: ports.2, peers: nil
            )
            try topology.validated().save(root: layout.root)
            // The child's own directory now carries the seed.
            try? FileManager.default.removeItem(at: pendingURL)
            try spawnChain(childPath, topology: topology, layout: layout)
            try await waitActive(
                childPath, rpc: ports.2, expectedTip: genesisCID
            )
            print("\(childPath): active")
        }
    }

    struct Adopt: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Join an existing child chain through the local parent."
        )

        @OptionGroup var rootOption: RootOption

        @Argument(help: "Absolute child path (e.g. Nexus/Payments).")
        var path: String

        func run() async throws {
            let layout = rootOption.layout
            var topology = try Topology.load(root: layout.root).validated()
            guard topology.chains[path] == nil else {
                throw CtlError("\(path) is already in the tree")
            }
            let ports = nextFreePorts(topology)
            topology.chains[path] = TopologyChain(
                listen: ports.0, fact: ports.1, rpc: ports.2, peers: nil
            )
            _ = try topology.validated()
            try topology.save(root: layout.root)
            try spawnChain(path, topology: topology, layout: layout)
            print("\(path): started; awaiting authenticated genesis from the parent")
        }
    }
}

/// What a deploy cannot re-derive once its anchor may be on the parent: the
/// genesis seed, and the exact signed anchor — resubmitted verbatim, so a
/// resumed deploy is the same transaction rather than a same-nonce rival the
/// pool refuses.
struct PendingChildDeploy: Codable {
    let seed: ChildGenesisSeed
    let anchor: SubmitTransactionRequest
}

/// Free means free on this HOST, not merely absent from the file: another
/// root's tree (or a lingering process) may hold a port the topology has
/// never heard of, and a child that cannot bind dies at launch while health
/// probes silently hit the squatter.
func nextFreePorts(_ topology: Topology) -> (UInt16, UInt16, UInt16) {
    let used = topology.chains.values.flatMap { [$0.listen, $0.fact, $0.rpc] }
    var base: UInt16 = 4101
    while used.contains(base) || used.contains(base + 1)
        || used.contains(base + 2)
        || !portIsBindable(base) || !portIsBindable(base + 1)
        || !portIsBindable(base + 2) {
        base += 100
    }
    return (base, base + 1, base + 2)
}

func portIsBindable(_ port: UInt16) -> Bool {
    #if canImport(Darwin)
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Foundation.bind(
                descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    } == 0
}

/// True once the parent has committed `directory -> genesisCID` into its
/// genesisState, exposed through the `api/chain/children` explorer listing.
func parentRecordedGenesis(
    rpc: UInt16, directory: String, genesisCID: String
) async -> Bool {
    guard let url = URL(
        string: "http://127.0.0.1:\(rpc)/api/chain/children?limit=100"
    ) else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    // The listing is `max-age=3`: a cached "not yet" must not answer the
    // re-check right after a refused resubmission.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let listing = try? JSONDecoder().decode(
              ExplorerChainChildren.self, from: data
          ) else {
        return false
    }
    return listing.children.contains {
        $0.chainPath.last == directory && $0.genesisHash == genesisCID
    }
}

func waitActive(
    _ path: String, rpc: UInt16, expectedTip: String
) async throws {
    for _ in 0..<120 {
        if let health = await health(rpc: rpc),
           health["phase"] as? String == "active" {
            return
        }
        try await Task.sleep(for: .seconds(1))
    }
    throw CtlError("\(path) did not reach active; check its log")
}

func post<Body: Encodable, Response: Decodable>(
    rpc: UInt16, path: String, body: Body
) async throws -> Response {
    guard let url = URL(string: "http://127.0.0.1:\(rpc)/\(path)") else {
        throw CtlError("bad RPC URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode) else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let detail = String(decoding: data.prefix(512), as: UTF8.self)
        throw CtlError("\(path) failed: HTTP \(status) \(detail)")
    }
    return try JSONDecoder().decode(Response.self, from: data)
}
