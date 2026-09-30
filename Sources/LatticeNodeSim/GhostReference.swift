import Lattice
import UInt256

/// A small, independent GHOST: descend from genesis to the child whose
/// subtree carries the most work, ties to the smaller CID, never into an
/// excluded root. Subtree work counts every block (excluded ones too — work
/// weighs, validity selects) and each grind once, at its strongest.
public struct GhostReference: Sendable {
    public let genesis: String
    private(set) var children: [String: [String]] = [:]
    private(set) var grinds: [String: [String: UInt256]] = [:]
    public var excluded: Set<String> = []

    public init(genesis: String) {
        self.genesis = genesis
    }

    public mutating func add(_ block: String, parent: String?, work: UInt256) {
        add(block, parent: parent, grinds: [block: work])
    }

    /// A block and every grind credited to it (attributed runs included).
    public mutating func add(_ block: String, parent: String?, grinds blockGrinds: [String: UInt256]) {
        if let parent, grinds[block] == nil {
            children[parent, default: []].append(block)
        }
        grinds[block, default: [:]].merge(blockGrinds) { max($0, $1) }
    }

    /// Every block's subtree work, grind-deduplicated.
    public func subtreeWork() -> [String: UInt256] {
        var totals: [String: UInt256] = [:]
        func visit(_ block: String) -> [String: UInt256] {
            var merged = grinds[block] ?? [:]
            for child in children[block] ?? [] {
                merged.merge(visit(child)) { max($0, $1) }
            }
            totals[block] = merged.values.reduce(UInt256.zero, +)
            return merged
        }
        _ = visit(genesis)
        return totals
    }

    /// The selected tip and the path to it.
    public func descent() -> (head: String, path: [String]) {
        let work = subtreeWork()
        var path = [genesis]
        var current = genesis
        while true {
            var selected: String?
            for child in children[current] ?? [] where !excluded.contains(child) {
                guard let incumbent = selected else {
                    selected = child
                    continue
                }
                let challenger = work[child] ?? .zero
                let holder = work[incumbent] ?? .zero
                if challenger > holder
                    || (challenger == holder && forkChoicePrefersBlock(child, over: incumbent)) {
                    selected = child
                }
            }
            guard let next = selected else { return (current, path) }
            path.append(next)
            current = next
        }
    }

    public var head: String { descent().head }
}
