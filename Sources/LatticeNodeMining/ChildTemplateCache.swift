import Foundation
import Lattice
import LatticeNodeCore
import Synchronization
import UInt256

/// The block each hosted child level last built for a template, kept so the
/// next template reuses it while nothing it was built from has changed.
///
/// A template is rebuilt whenever any hosted level moves, and every hosted
/// level's block was built again with it. On a node hosting many chains, one
/// chain's move (a share that meets only that chain, say) then paid for every
/// sibling's block too. With this cache a build rebuilds the level that moved
/// and its ancestors, whose child indexes now differ, and reuses every other
/// level's block.
///
/// A reused block keeps the timestamp it was built with. Validity does not
/// tie a child's timestamp to its carrier's (only to its own parent block's),
/// and an older timestamp is never refused; the difficulty schedule reads it
/// as an earlier block and corrects at the level's next block. `maxAge` keeps
/// reused timestamps near the present all the same.
package final class ChildTemplateCache: Sendable {
    /// Everything a level's block is built from, but the time.
    package struct Key: Equatable, Sendable {
        /// The tip the block builds on (the anchored tip below the act-on
        /// tip), and the act-on tip it was anchored from.
        package let tipCID: String
        package let actOnTipCID: String
        /// The parent state the block enters.
        package let enteringCID: String
        /// The level's next-block transactions, in order, by CID.
        package let transactions: [String]
        package let anchor: DifficultyAnchor?
        /// The recipients and minimum works of the whole template.
        package let request: TemplateRequest
        /// The hosted directories below the level.
        package let hosted: [String]
        /// Each child candidate's directory and block, in order.
        package let children: [String]

        package init(
            tipCID: String, actOnTipCID: String, enteringCID: String, transactions: [String],
            anchor: DifficultyAnchor?, request: TemplateRequest, hosted: [String], children: [String]
        ) {
            self.tipCID = tipCID
            self.actOnTipCID = actOnTipCID
            self.enteringCID = enteringCID
            self.transactions = transactions
            self.anchor = anchor
            self.request = request
            self.hosted = hosted
            self.children = children
        }
    }

    package struct Entry: Sendable {
        package let key: Key
        package let builtAt: ContinuousClock.Instant
        package let block: Block
        package let searchWitness: ChildSchedulingWitness?
        package let subtreeThresholds: [UInt256]?

        package init(
            key: Key, builtAt: ContinuousClock.Instant, block: Block,
            searchWitness: ChildSchedulingWitness?, subtreeThresholds: [UInt256]?
        ) {
            self.key = key
            self.builtAt = builtAt
            self.block = block
            self.searchWitness = searchWitness
            self.subtreeThresholds = subtreeThresholds
        }
    }

    package let maxAge: Duration
    private let entries = Mutex<[ChainPath: Entry]>([:])

    package init(maxAge: Duration = .seconds(30)) {
        self.maxAge = maxAge
    }

    /// The level's block for `key`, when it was built from exactly that and
    /// within `maxAge`.
    package func block(at path: ChainPath, for key: Key, now: ContinuousClock.Instant = .now) -> Entry? {
        entries.withLock { entries in
            guard let entry = entries[path], entry.key == key, now - entry.builtAt <= maxAge else { return nil }
            return entry
        }
    }

    /// Keep the level's newest block, replacing the one before: one block
    /// per level, so a level no longer hosted holds at most one.
    package func keep(_ entry: Entry, at path: ChainPath) {
        entries.withLock { $0[path] = entry }
    }
}
