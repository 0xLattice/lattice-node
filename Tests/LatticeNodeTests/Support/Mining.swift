import Lattice
import LatticeMinerCore
import UInt256
import XCTest
@testable import LatticeNode

// Deterministic nonce search for tests. Under the absolute (ASERT) schedule
// every block after the anchor commits a target a little below the maximum
// once the harness runs ahead of `targetBlockTime`, so "submit nonce 0" is a
// coin flip with a ~0.6% tail: a fixed nonce only provably solves a block
// whose target is the maximum (block 1, and block 2 -- the anchor's own
// `nextTarget` is its target). Everything deeper searches.
//
// `BlockBuilder.mine` restarts at nonce 0 and drops the block's own nonce, so
// callers that need "the first solution at or above N" scan here instead.

/// Nonce scan over the consensus PoW preimage midstate: the first nonce at or
/// above `start` whose hash the predicate accepts. Same inputs, same nonce.
func firstNonce(
    of block: Block,
    from start: UInt64 = 0,
    maxAttempts: UInt64 = 1 << 24,
    file: StaticString = #filePath,
    line: UInt = #line,
    where accepts: (UInt256) -> Bool
) -> UInt64 {
    let midstate = ProofOfWork.midstate(for: block)
    var nonce = start
    // Bounded on purpose. A predicate can be UNSATISFIABLE rather than merely
    // unlikely -- searching for a hash strictly above a target that is the
    // maximum can never succeed, because no hash exceeds the maximum -- and an
    // unbounded scan turns that into a hang instead of a failure. One such
    // search spun for over two hours before it was noticed.
    while nonce - start < maxAttempts {
        if accepts(ProofOfWork.hash(midstate: midstate, nonce: nonce)) {
            return nonce
        }
        nonce += 1
    }
    XCTFail(
        "no nonce satisfied the predicate in \(maxAttempts) attempts; "
            + "the search is probably unsatisfiable (target \(block.target.toHexString()))",
        file: file, line: line
    )
    return start
}

/// `block` carrying the first nonce at or above `start` whose proof-of-work
/// hash meets `target`.
func solveNonce(
    for block: Block,
    target: UInt256,
    startingAt start: UInt64 = 0,
    file: StaticString = #filePath,
    line: UInt = #line
) -> Block {
    block.replacingNonce(
        firstNonce(of: block, from: start, file: file, line: line) { $0 <= target }
    )
}

/// The first nonce at or above `start` that mines an issued template's own
/// block: its hash meets both the search target and the block's committed
/// target. With child candidates and no binding filter the search target is
/// the EASIEST threshold, so a hash clearing it alone can be a carrier
/// (`accepted == false`); the parent's target is what this node canonicalizes.
func solvedNonce(
    for template: MiningTemplateResponse,
    startingAt start: UInt64 = 0,
    file: StaticString = #filePath,
    line: UInt = #line
) -> UInt64 {
    let target = min(template.searchTarget, template.block.target)
    return firstNonce(of: template.block, from: start, file: file, line: line) {
        $0 <= target
    }
}

extension Block {
    func replacingNonce(_ nonce: UInt64) -> Block {
        Block(
            version: version,
            parent: parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: parentState,
            prevState: prevState,
            postState: postState,
            children: children,
            height: height,
            timestamp: timestamp,
            rewardRecipient: rewardRecipient,
            nonce: nonce
        )
    }
}
