// Chain-tree evolution: the only two legitimate ways a child exists.
//
// `deploy` runs the full arc against the LOCAL parent process: build the
// self-contained child genesis OFFLINE (empty parentState) → submit ONE signed
// GenesisAction anchor recording its CID in the parent's genesisState → wait for
// the parent to record it → child process active — then records the child in the
// topology. `adopt` joins an EXISTING child permissionlessly: the child process
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
            let seed = ChildGenesisSeed(
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
            print("genesis \(genesisCID)")

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
            guard let signature = TransactionSigning.sign(
                bodyHeader: header, privateKeyHex: key.privateKey
            ) else {
                throw CtlError("anchor signing failed; check the fund key")
            }
            struct SubmitResponse: Decodable { let transactionCID: String }
            let submitted: SubmitResponse = try await post(
                rpc: parentChain.rpc, path: "v1/transactions",
                body: SubmitTransactionRequest(transaction: Transaction(
                    signatures: [key.publicKey: signature], body: header
                ))
            )
            print("anchor \(submitted.transactionCID)")

            // The anchor is now an ordinary mempool transaction. Wait for the
            // parent to MINE it into a block, which writes `directory ->
            // genesisCID` into its committed genesisState. An external parent
            // miner advances the block; the child is recorded only once the
            // parent has durably recorded the genesis CID.
            var recorded = false
            for _ in 0..<60 {
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
            guard recorded else {
                throw CtlError("the genesis anchor was not recorded; the child was NOT added — check the parent's mining and the funding key nonce, then retry")
            }
            let ports = nextFreePorts(topology)
            topology.chains[childPath] = TopologyChain(
                listen: ports.0, fact: ports.1, rpc: ports.2, peers: nil
            )
            try topology.validated().save(root: layout.root)
            // Seed the child's data directory with the genesis inputs so its node
            // rebuilds the identical self-contained genesis and self-admits it on
            // startup (the parent has already recorded the CID above).
            let childData = layout.chainDirectory(for: childPath)
            try FileManager.default.createDirectory(
                at: childData, withIntermediateDirectories: true
            )
            try JSONEncoder().encode(seed).write(
                to: childData.appendingPathComponent("child-genesis.json")
            )
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
        throw CtlError("\(path) failed: HTTP \(status)")
    }
    return try JSONDecoder().decode(Response.self, from: data)
}
