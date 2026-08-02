// The declarative unit `lattice` operates on: one host's chain-process tree.
//
// Lattice runs one process per chain; a child authenticates against its
// immediate parent's fact plane. This file makes that tree a value: each
// entry is one process, parents are derived from chain paths, and every
// verb reconciles against it rather than accumulating flag invocations.

import Foundation
import Lattice
import LatticeNode

public struct TopologyChain: Codable {
    public var listen: UInt16
    public var fact: UInt16
    public var rpc: UInt16
    /// Overlay bootstrap peers as `publicKey@host:port`. Only meaningful
    /// entries for this chain's own path; children of a local parent are
    /// wired to it automatically.
    public var peers: [String]?

    public init(
        listen: UInt16, fact: UInt16, rpc: UInt16, peers: [String]? = nil
    ) {
        self.listen = listen
        self.fact = fact
        self.rpc = rpc
        self.peers = peers
    }
}

public struct TopologyMine: Codable {
    public var chain: String
    /// "cpu" or a path to any contract-conforming worker executable.
    public var worker: String?
    public var workers: Int?
    public var batchSize: UInt64?
    /// A `lattice-rewards emit-batch` file; the cursor lives beside it.
    public var rewards: String?

    public init(
        chain: String, worker: String? = nil, workers: Int? = nil,
        batchSize: UInt64? = nil, rewards: String? = nil
    ) {
        self.chain = chain
        self.worker = worker
        self.workers = workers
        self.batchSize = batchSize
        self.rewards = rewards
    }
}

public struct Topology: Codable {
    /// Chain path key (e.g. "Nexus", "Nexus/Payments") to process settings.
    public var chains: [String: TopologyChain]
    public var mine: TopologyMine?

    public init(
        chains: [String: TopologyChain], mine: TopologyMine? = nil
    ) {
        self.chains = chains
        self.mine = mine
    }

    public static let fileName = "lattice.json"

    public static func load(root: URL) throws -> Topology {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            throw CtlError("no \(fileName) in \(root.path); run `lattice init` first")
        }
        return try JSONDecoder().decode(Topology.self, from: data)
    }

    public func save(root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(
            to: root.appendingPathComponent(Self.fileName),
            options: .atomic
        )
    }

    /// Parent-before-child order, so `up` can wire children to a parent
    /// that is already running.
    public func orderedPaths() -> [String] {
        chains.keys.sorted { $0.components(separatedBy: "/").count
            < $1.components(separatedBy: "/").count || $0 < $1 }
    }

    public func validated() throws -> Topology {
        var ports: Set<UInt16> = []
        for (path, chain) in chains {
            guard let address = ChainAddress(string: path),
                  address.key == path,
                  address.components.allSatisfy({
                      $0 != "." && $0 != ".." && !$0.contains("/")
                  }) else {
                throw CtlError("chain path is not absolute and Nexus-rooted: \(path)")
            }
            if address.components.count > 1 {
                let parent = address.components.dropLast().joined(separator: "/")
                guard chains[parent] != nil else {
                    throw CtlError("\(path) has no local parent \(parent); every child needs its immediate parent in the tree")
                }
            }
            for port in [chain.listen, chain.fact, chain.rpc] {
                guard ports.insert(port).inserted else {
                    throw CtlError("port \(port) is used twice")
                }
            }
        }
        if let mine, chains[mine.chain] == nil {
            throw CtlError("mine.chain \(mine.chain) is not in the tree")
        }
        return self
    }
}

public struct CtlError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Filesystem layout under the data root. Identity keys live OUTSIDE the
/// wipeable chain directories so a flag-day wipe never destroys identity.
public struct HostLayout {
    public let root: URL

    public init(root: String?) {
        self.root = URL(fileURLWithPath: root
            ?? FileManager.default.currentDirectoryPath)
    }

    public func identityKey(for path: String) -> URL {
        root.appendingPathComponent("identity")
            .appendingPathComponent(
                path.replacingOccurrences(of: "/", with: "-") + ".key"
            )
    }

    public func chainDirectory(for path: String) -> URL {
        root.appendingPathComponent("chains").appendingPathComponent(path)
    }

    public func pidFile(for path: String) -> URL {
        root.appendingPathComponent("run").appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "-") + ".pid"
        )
    }

    public func logFile(for path: String) -> URL {
        root.appendingPathComponent("log").appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "-") + ".log"
        )
    }
}
