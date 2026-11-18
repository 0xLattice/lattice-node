import LatticeNodeSim
import XCTest
@testable import LatticeNode

/// The body order the loop keeps as windows move: after every step, each
/// window block's nearest distance in any window, as merging every window
/// again would give, and the blocks it reports are exactly the ones whose
/// order changed. Blocks are shared between windows, so a nearest distance
/// grows and leaves.
final class BodyOrderTests: XCTestCase {
    func testTheOrderMovedWithTheWindowsIsTheMergeOfEveryWindow() {
        for seed in UInt64(0)..<50 {
            var rng = SplitMix64(state: 0xB0D7 + seed)
            let blocks = (0..<12).map { "block\($0)" }
            var windows: [Int: [String: Int]] = [:]
            var order: [String: Int] = [:]
            for step in 0..<200 {
                var moved: [(old: [String: Int], new: [String: Int])] = []
                for level in 0..<4 where rng.chance(0.5) {
                    var window: [String: Int] = [:]
                    if rng.draw(0...4) > 0 {
                        for block in blocks where rng.draw(0...2) == 0 {
                            window[block] = rng.draw(0...5)
                        }
                    }
                    moved.append((windows[level] ?? [:], window))
                    windows[level] = window.isEmpty ? nil : window
                }
                let before = order
                let reordered = NodeRuntime.Loop.reorder(&order, moved: moved, windows: Array(windows.values))
                let merged = windows.values.reduce(into: [String: Int]()) { $0.merge($1) { min($0, $1) } }
                XCTAssertEqual(order, merged, "seed \(seed) step \(step)")
                XCTAssertEqual(reordered, Set(blocks.filter { before[$0] != merged[$0] }), "seed \(seed) step \(step)")
                if order != merged { return }
            }
        }
    }
}
