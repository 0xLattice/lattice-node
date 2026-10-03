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

        @Option(help: "Target block time, milliseconds.")
        var blockTime: UInt64 = 10_000

        @Option(help: "Initial block reward.")
        var reward: UInt64 = 1_000

        @Option(help: "Premine to the genesis's reward recipient.")
        var premine: UInt64 = 0

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
            try topology.save(root: layout.root)
            let restarted = try await withSpawnLock(layout) { try await restartHostIfRunningLocked(layout) }
            print("\(path): spec \(file.path); genesis mined from it in the next template that carries it")
            if restarted { print("restarted the host to run \(path)") }
        }
    }
}
