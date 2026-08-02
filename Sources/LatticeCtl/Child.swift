// Chain-tree evolution: the only two legitimate ways a child exists.
//
// `deploy` runs the full arc against the LOCAL parent process: intent →
// signed GenesisAction anchor → one deployment-mode mining round → child
// process active — then records the child in the topology. `adopt` joins an
// EXISTING child permissionlessly: the child process re-derives its genesis
// through the authenticated parent link, never from "a node that tracks it".

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import Lattice
import LatticeCtlCore
import LatticeNode
import UInt256
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

            var genesisTransactions: [Transaction] = []
            if let premineTo {
                let premineBody = TransactionBody(
                    accountActions: [AccountAction(
                        owner: premineTo,
                        delta: Int64(chainSpec.premineAmount())
                    )],
                    actions: [],
                    depositActions: [],
                    genesisActions: [],
                    receiptActions: [],
                    withdrawalActions: [],
                    signers: [],
                    fee: 0,
                    nonce: 0,
                    chainPath: [parent, directory].joined(separator: "/")
                        .components(separatedBy: "/")
                )
                genesisTransactions.append(Transaction(
                    signatures: [:],
                    body: try HeaderImpl(node: premineBody)
                ))
            }
            let intent: ChildDeployIntentResponse = try await post(
                rpc: parentChain.rpc, path: "v1/children/intents",
                body: ChildDeployIntentRequest(
                    directory: directory,
                    spec: chainSpec,
                    genesisTransactions: genesisTransactions,
                    target: .max,
                    timestamp: Int64(Date().timeIntervalSince1970 * 1000)
                )
            )
            print("genesis \(intent.genesisCID)")

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
                    directory: directory, blockCID: intent.genesisCID
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

            // Deployment templates are the only ones that include genesis
            // actions. NOTE: the drain+height gate assumes no concurrent
            // parent miner (deploy-before-mine on one host); with outside
            // traffic, gate on the anchor CID landing in a block instead.
            // Success is "the anchor left the parent mempool and a
            // block landed", never "a mining round exited cleanly" — only
            // then is the child recorded and spawned.
            let worker = try nodeBinary().deletingLastPathComponent()
                .appendingPathComponent("lattice-miner")
            // Templates come only from the tree root: a deployment round
            // there cascades carriers down to the immediate parent, which is
            // where the anchor and the mempool/height gate live.
            guard let rootChain = topology.chains["Nexus"] else {
                throw CtlError("the tree has no Nexus root to mine from")
            }
            let heightBefore = await health(
                rpc: parentChain.rpc
            )?["height"] as? Int ?? 0
            var anchored = false
            for _ in 0..<20 {
                let coordinator = Process()
                coordinator.executableURL = try nodeBinary()
                    .deletingLastPathComponent()
                    .appendingPathComponent("lattice-mining-coordinator")
                coordinator.arguments = [
                    "--node", "http://127.0.0.1:\(rootChain.rpc)",
                    "--worker-executable", worker.path,
                    "--workers", "1", "--once", "--deployment",
                ]
                // Fresh /dev/null per spawn: corelibs closes the shared
                // nullDevice singleton's fd after a process exits, so
                // reusing it across the 20-round loop throws EBADF.
                let devNull = FileHandle(forWritingAtPath: "/dev/null")
                coordinator.standardOutput = devNull ?? FileHandle.nullDevice
                coordinator.standardError = devNull ?? FileHandle.nullDevice
                try coordinator.run()
                coordinator.waitUntilExit()
                try? devNull?.close()
                if let health = await health(rpc: parentChain.rpc),
                   health["mempoolCount"] as? Int == 0,
                   (health["height"] as? Int ?? 0) > heightBefore {
                    anchored = true
                    break
                }
                try await Task.sleep(for: .seconds(2))
            }
            guard anchored else {
                throw CtlError("the genesis anchor was not mined; the child was NOT added — check the parent's mining and the funding key nonce, then retry")
            }
            let ports = nextFreePorts(topology)
            topology.chains[childPath] = TopologyChain(
                listen: ports.0, fact: ports.1, rpc: ports.2, peers: nil
            )
            try topology.validated().save(root: layout.root)
            try spawnChain(childPath, topology: topology, layout: layout)
            try await waitActive(
                childPath, rpc: ports.2, expectedTip: intent.genesisCID
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
