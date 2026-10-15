import ArgumentParser
import Foundation
import Lattice
import LatticeCtlCore
import LatticeNode

/// Child chains this host runs as levels of its one process.
struct Child: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create and host child chains.",
        subcommands: [Create.self]
    )

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
            if chainSpec.premine > 0 && (premineTo ?? "").isEmpty {
                throw CtlError("the spec has a premine of \(chainSpec.premine) blocks; name the account it goes to with --premine-to")
            }
            do {
                _ = try NodeRuntime.premine(spec: chainSpec, to: premineTo, on: path.split(separator: "/").map(String.init))
            } catch {
                throw CtlError("--premine-to: \(error)")
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
            try encoder.encode(chainSpec).write(to: file, options: .atomic)
            if let premineTo, chainSpec.premine > 0 {
                try Data(premineTo.utf8).write(to: layout.premineRecipient(for: path), options: .atomic)
            }
            if !modules.isEmpty {
                let directory = layout.policyModules(for: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (cid, bytes) in modules {
                    try bytes.write(to: directory.appendingPathComponent(cid + ".wasm"), options: .atomic)
                }
            }
            try topology.save(root: layout.root)
            let restarted = try await withSpawnLock(layout) { try await restartHostIfRunningLocked(layout) }
            print("\(path): spec \(file.path); genesis mined from it in the next template that carries it")
            if restarted { print("restarted the host to run \(path)") }
        }
    }
}
