import Foundation
import Hummingbird
import HummingbirdTesting
import Lattice
import LatticeMinerCore
import UInt256
import XCTest
@testable import LatticeNode
import LatticeNodeAPI

// Deterministic nonce search for tests. Under the absolute (ASERT) schedule
// every block after the anchor commits a target a little below the maximum
// once the harness runs ahead of `targetBlockTime`, so "submit nonce 0" is a
// coin flip with a ~0.6% tail: a fixed nonce only provably solves a block
// whose target is the maximum (block 1, and block 2 -- the anchor's own
// `nextTarget` is its target). Everything deeper searches.
//
// A scan from nonce 0 drops the block's own nonce, so callers that need "the
// first solution at or above N" scan here instead.

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

/// Mines exactly one block atop the current tip through the template/work
/// routes, solving the issued template, and returns the new tip's CID.
func mineOneBlock(client: some TestClientProtocol) async throws -> String {
    var template: MiningTemplateResponse?
    try await client.execute(
        uri: "/mining/templates",
        method: .post,
        headers: [.authorization: testOperatorAuthorization, .contentType: "application/json"],
        body: ByteBuffer(bytes: try JSONEncoder().encode(MiningTemplateRequest()))
    ) { response in
        template = try JSONDecoder().decode(
            MiningTemplateResponse.self,
            from: Data(response.body.readableBytesView)
        )
    }
    let issued = try XCTUnwrap(template)
    var tipCID: String?
    try await client.execute(
        uri: "/mining/work",
        method: .post,
        headers: [.authorization: testOperatorAuthorization, .contentType: "application/json"],
        body: ByteBuffer(bytes: try JSONEncoder().encode(
            SubmitWorkRequest(workID: issued.workID, nonce: solvedNonce(for: issued))
        ))
    ) { response in
        let submitted = try JSONDecoder().decode(
            SubmitWorkResponse.self,
            from: Data(response.body.readableBytesView)
        )
        XCTAssertTrue(submitted.accepted)
        tipCID = submitted.tipCID
    }
    return try XCTUnwrap(tipCID)
}

/// A WASM policy module that gives `verdict` for every transaction, or traps
/// (`unreachable`) without one: the memory, allocator and transaction
/// entrypoint the policy ABI requires.
func policyModule(verdict: UInt8?) -> Data {
    func section(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { [id, UInt8(body.count)] + body }
    func export(_ name: String, kind: UInt8, index: UInt8) -> [UInt8] {
        [UInt8(name.utf8.count)] + Array(name.utf8) + [kind, index]
    }
    var exports: [UInt8] = [0x03]
    exports += export("memory", kind: 2, index: 0)
    exports += export("lattice_alloc", kind: 0, index: 0)
    exports += export("lattice_validate_transaction", kind: 0, index: 1)
    var module: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
    // (i32) -> i32 and (i32, i32) -> i32
    module += section(1, [0x02, 0x60, 0x01, 0x7f, 0x01, 0x7f, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f])
    module += section(3, [0x02, 0x00, 0x01])
    module += section(5, [0x01, 0x00, 0x01])
    module += section(7, exports)
    // lattice_alloc returns 1024; the entrypoint returns the verdict.
    let validate: [UInt8] = verdict.map { [0x04, 0x00, 0x41, $0, 0x0b] } ?? [0x03, 0x00, 0x00, 0x0b]
    module += section(10, [0x02, 0x05, 0x00, 0x41, 0x80, 0x08, 0x0b] + validate)
    return Data(module)
}
