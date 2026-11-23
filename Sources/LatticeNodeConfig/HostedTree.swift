import LatticeNodeAPI
import Foundation

/// A chain's settings, merged across the layers: its peers (the union), its
/// state and finality windows (the later layer's).
public struct ChainSettings: Sendable, Equatable {
    public var peers: [String]?
    public var stateWindow: UInt64?
    public var finalityWindow: UInt64?

    public init(peers: [String]? = nil, stateWindow: UInt64? = nil, finalityWindow: UInt64? = nil) {
        self.peers = peers
        self.stateWindow = stateWindow
        self.finalityWindow = finalityWindow
    }
}

/// The chains the node hosts: the smallest rooted subtree of the chain tree
/// that holds every chain a layer lists. A child runs only under its parent
/// (its blocks ride in the parent's, and validating it reads the parent's
/// state), so the ancestors of a listed chain are hosted too, implied by it,
/// as apt installs a package's dependencies automatically. A chain stops
/// only once no layer lists it or any chain under it.
public struct HostedTree: Sendable {
    public struct Chain: Sendable, Equatable {
        public let path: String
        /// The layers that list it, in merge order; empty when it is implied
        /// (or Nexus, the root).
        public let listedBy: [String]
        /// When it is implied: the listed chains under it, which keep it.
        public let impliedBy: [String]
        public let settings: ChainSettings
    }

    /// Nexus first, then every hosted child chain after its parent.
    public let chains: [Chain]

    /// The tree that `listedBy` (each listed child chain's layers) makes,
    /// each chain with its `settings`. A setting for a chain not in the tree
    /// is not kept: `self[path]` tells which.
    public init(listedBy: [String: [String]], settings: [String: ChainSettings]) {
        var impliedBy: [String: [String]] = [:]
        for path in listedBy.keys.sorted(by: Self.parentFirst) {
            var ancestor = ChainAddress(string: path)?.parent
            while let next = ancestor, !next.isNexus {
                if listedBy[next.key] == nil { impliedBy[next.key, default: []].append(path) }
                ancestor = next.parent
            }
        }
        let paths = [ChainAddress.nexus] + Set(listedBy.keys).union(impliedBy.keys).sorted(by: Self.parentFirst)
        chains = paths.map {
            Chain(path: $0, listedBy: listedBy[$0] ?? [], impliedBy: impliedBy[$0] ?? [], settings: settings[$0] ?? ChainSettings())
        }
    }

    public subscript(path: String) -> Chain? {
        chains.first { $0.path == path }
    }

    /// The hosted child chains, parent first.
    public var children: [String] {
        chains.dropFirst().map(\.path)
    }

    /// Each hosted child chain as `GET /config` reports it, against the
    /// chains `running` and the reasons in `errors` (a chain that did not
    /// start); then any chain running that the tree no longer holds.
    public func status(running: Set<String>, errors: [String: String]) -> [ConfigStatus.Chain] {
        chains.dropFirst().map {
            ConfigStatus.Chain(
                path: $0.path, from: $0.listedBy, impliedBy: $0.listedBy.isEmpty ? $0.impliedBy : nil,
                actual: running.contains($0.path) ? "hosted" : "notHosted", error: errors[$0.path]
            )
        } + running.subtracting(children).sorted().map {
            ConfigStatus.Chain(path: $0, from: [], actual: "hosted", error: "no layer lists it or a chain under it, and it did not stop")
        }
    }

    private static func parentFirst(_ first: String, _ second: String) -> Bool {
        let depth = { (path: String) in path.split(separator: "/").count }
        return (depth(first), first) < (depth(second), second)
    }
}
