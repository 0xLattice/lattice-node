import ArgumentParser
import Foundation
import Lattice
import LatticeCtlCore
import LatticeNode
import LatticeNodeAPI

/// The chain's latest block, as its RPC reads it now.
func latestBlock(rpc: NodeRPC, chain: String) async throws -> ExplorerLatestBlock {
    var request = try rpc.request("api/block/latest", chain: chain)
    request.timeoutInterval = 10
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw CtlError("latest block lookup failed")
    }
    return try JSONDecoder().decode(ExplorerLatestBlock.self, from: data)
}

/// Child chains this host runs as levels of its one process.
struct Child: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create, host and commit child chains.",
        subcommands: [Create.self, Host.self, Commit.self]
    )

    /// Host a child chain that already exists: the running host syncs it
    /// from its peers and carries it in its templates from now on.
    struct Host: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Host an existing child chain; it is synced from its peers."
        )

        @OptionGroup var rootOption: RootOption

        @Argument(help: "The child chain's path, e.g. Nexus/Alpha.")
        var path: String

        func run() async throws {
            let layout = rootOption.layout
            var topology = try Topology.load(root: layout.root)
            guard !(topology.hostedChains ?? []).contains(path) else {
                throw CtlError("\(path) is already hosted")
            }
            topology.hostedChains = (topology.hostedChains ?? []) + [path]
            _ = try topology.validated()
            try topology.save(root: layout.root)
            let updated = try await withSpawnLock(layout) { try await updateHostIfRunningLocked(layout) }
            print("\(path): hosted; synced from its peers")
            if updated { print("the host now runs \(path)") }
        }
    }

    /// Merged mining by another chain's miners: the hosted child's next
    /// block C is built here on the parent's tip state P, committed on the
    /// parent (`child/X` = `C@P`, `tx commit-child`), and pushed until a
    /// parent block carrying it weighs it. A commit whose P the parent's tip
    /// has moved past can never be carried: C is built again on the new tip.
    struct Commit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build a hosted child chain's next block, commit it on its parent, and push it until it is weighed."
        )

        @OptionGroup var rootOption: RootOption

        @Argument(help: "The hosted child chain's path, e.g. Nexus/Alpha.")
        var path: String

        @Option(name: .long, help: "Key file (from `lattice key generate`) that signs and pays the commit on the parent and is paid the child block's reward.")
        var key: String

        @Option(name: .long, help: "The commit's fee; defaults to the parent's relay floor (minRelayFee).")
        var fee: UInt64?

        func run() async throws {
            let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.count > 1, let directory = components.last else {
                throw CtlError("\(path) is not a child chain's path")
            }
            let parent = components.dropLast().joined(separator: "/")
            let layout = rootOption.layout
            let rpc = NodeRPC(try Topology.load(root: layout.root).validated(), layout)
            var tx = try TxOptions.parse(
                ["--chain", parent, "--key", key] + (rootOption.root.map { ["--root", $0] } ?? [])
                    + (fee.map { ["--fee", String($0)] } ?? [])
            )
            let signer = try tx.signer()
            // One nonce for every commit: a rebuilt commit replaces a stale
            // one still pooled, never queues behind it.
            let nonce = try await nextNonce(rpc: rpc, address: signer.address, chain: parent)
            tx.nonce = nonce
            var built: (block: BuildChildBlockResponse, tip: String)?
            while true {
                guard let current = built else {
                    let tip = try await latestBlock(rpc: rpc, chain: parent).hash
                    let next: BuildChildBlockResponse = try await post(
                        rpc: rpc, path: "child-blocks/build",
                        body: BuildChildBlockRequest(chainPath: components, recipient: signer.address)
                    )
                    print("built \(next.blockCID) on \(parent) state \(next.parentState)")
                    try await commit(next, directory: directory, tx: tx, signer: signer)
                    built = (next, tip)
                    continue
                }
                let pushed: SubmitChildBlockResponse = try await post(rpc: rpc, path: "child-blocks", body: current.block.submit)
                print("\(pushed.blockCID): \(pushed.status.rawValue)")
                if pushed.status == .tree { return }
                // Stale: the parent's tip moved past the one C was built on,
                // and the commit was not carried there (its nonce is unspent).
                if pushed.status == .dropped,
                   try await latestBlock(rpc: rpc, chain: parent).hash != current.tip,
                   try await committedNextNonce(rpc: rpc, address: signer.address, chain: parent) <= nonce {
                    built = nil
                    continue
                }
                try await Task.sleep(for: .seconds(3))
            }
        }

        /// The commit on the parent. One refused as `feeTooLow` conflicts
        /// with the stale commit at the same nonce, still pooled until the
        /// parent's pool drops it: wait for that.
        private func commit(
            _ built: BuildChildBlockResponse, directory: String, tx: TxOptions, signer: TxOptions.Signer
        ) async throws {
            let action = Tx.CommitChild.action(
                directory: directory, block: built.blockCID, parentState: built.parentState, previous: built.previous
            )
            while true {
                do {
                    return try await tx.submit(signer: signer, actions: [action])
                } catch let error as CtlError where "\(error)".contains("feeTooLow") {
                    print("the stale commit is still pooled; waiting")
                    try await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    /// Write a child chain's spec and host it. Its genesis is built from the
    /// spec in the next template that carries it, committing that carrier's
    /// entering parent state, and weighs by the grind that mines it: no
    /// deploy record and no authorization on the parent.
    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write a child chain's spec and host it; its genesis is mined by merged mining."
        )

        @OptionGroup var rootOption: RootOption

        @Argument(help: "The child chain's path, e.g. Nexus/Alpha (its parent is Nexus or a hosted child; a nested genesis is mined once its parent has executed a block).")
        var path: String

        @Option(help: "A ChainSpec JSON file (every field, maxBlockSize and wasmPolicies included); flags below build one otherwise.")
        var spec: String?

        @Option(help: "A WASM policy module the spec names by CID (repeatable; one for every module in the spec's wasmPolicies). Kept beside the spec and stored by the host, which could not otherwise store the genesis.")
        var policyModule: [String] = []

        @Option(help: "Target block time, milliseconds.")
        var blockTime: UInt64 = 10_000

        @Option(help: "Initial block reward.")
        var reward: UInt64 = 1_000

        @Option(help: "Premine: blocks of the reward schedule the genesis pays to --premine-to.")
        var premine: UInt64 = 0

        @Option(help: "The account the genesis pays the spec's premine to. Required when the spec has a premine.")
        var premineTo: String?

        @Option(help: "Signed transactions the genesis carries after its premine: a JSON array of what POST /transactions takes, e.g. the names the chain's creator holds from the start. Each must be signed by its signers, move no coins, and pass the spec's policies.")
        var genesisTransactions: String?

        func run() async throws {
            let layout = rootOption.layout
            var topology = try Topology.load(root: layout.root)
            let chainSpec: ChainSpec
            if let spec {
                chainSpec = try JSONDecoder().decode(ChainSpec.self, from: Data(contentsOf: URL(fileURLWithPath: spec)))
            } else {
                chainSpec = ChainSpec(
                    maxNumberOfTransactionsPerBlock: 1_000, maxStateGrowth: 1_000_000, premine: premine,
                    targetBlockTime: blockTime, initialReward: reward, halvingInterval: 1_000_000, halfLife: 100
                )
            }
            // The spec names each module by CID; the host stores a genesis
            // only with every one of them in hand.
            var modules: [String: Data] = [:]
            for file in policyModule {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
                let cid = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: bytes)).rawCID
                let policies = chainSpec.wasmPolicies.filter { $0.moduleCID == cid }
                guard !policies.isEmpty else {
                    throw CtlError("\(file) is module \(cid), which the spec's wasmPolicies do not name")
                }
                for policy in policies {
                    do {
                        try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: bytes)
                    } catch {
                        throw CtlError("\(file) is not a valid module for policy \(policy.entrypoint): \(error)")
                    }
                }
                modules[cid] = bytes
            }
            if let missing = chainSpec.wasmPolicies.map(\.moduleCID).first(where: { modules[$0] == nil }) {
                throw CtlError("the spec names policy module \(missing); give its file with --policy-module")
            }
            // A premine is paid only to an account the creator names.
            let premineAmount = chainSpec.premineAmount()
            if premineAmount > 0 && (premineTo ?? "").isEmpty {
                throw CtlError("the spec has a premine of \(chainSpec.premine) blocks; name the account it goes to with --premine-to")
            }
            if premineAmount == 0 && premineTo != nil {
                throw CtlError("--premine-to names an account, but the spec pays no premine")
            }
            var genesis: (bytes: Data, transactions: [Transaction])?
            if let genesisTransactions {
                let bytes = try Data(contentsOf: URL(fileURLWithPath: genesisTransactions))
                do {
                    genesis = (bytes, try JSONDecoder().decode([SubmitTransactionRequest].self, from: bytes).map(\.transaction))
                } catch {
                    throw CtlError("--genesis-transactions: \(genesisTransactions) is not a JSON array of transactions: \(error)")
                }
            }
            do {
                try NodeRuntime.checkPremine(
                    spec: chainSpec, to: premineTo, transactions: genesis?.transactions ?? [],
                    on: path.split(separator: "/").map(String.init), modules: Array(modules.values)
                )
            } catch {
                throw CtlError(genesis == nil ? "--premine-to: \(error)" : "the genesis: \(error)")
            }
            // A chain is created once: its spec fixes its genesis.
            guard !(topology.hostedChains ?? []).contains(path),
                  !FileManager.default.fileExists(atPath: layout.childSpec(for: path).path) else {
                throw CtlError("\(path) already exists; a child chain is created once")
            }
            topology.hostedChains = (topology.hostedChains ?? []) + [path]
            _ = try topology.validated()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let file = layout.childSpec(for: path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // The recipient first: the spec marks the chain created, so a spec
            // never stands without the recipient its genesis pays.
            if let premineTo {
                try Data(premineTo.utf8).write(to: layout.premineRecipient(for: path), options: .atomic)
            }
            if let genesis {
                try genesis.bytes.write(to: layout.genesisTransactions(for: path), options: .atomic)
            }
            try encoder.encode(chainSpec).write(to: file, options: .atomic)
            if !modules.isEmpty {
                let directory = layout.policyModules(for: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (cid, bytes) in modules {
                    try bytes.write(to: directory.appendingPathComponent(cid + ".wasm"), options: .atomic)
                }
            }
            try topology.save(root: layout.root)
            let updated = try await withSpawnLock(layout) { try await updateHostIfRunningLocked(layout) }
            print("\(path): spec \(file.path); genesis mined from it in the next template that carries it")
            if updated { print("the host now runs \(path)") }
        }
    }
}
