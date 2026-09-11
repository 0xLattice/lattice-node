import Foundation
import XCTest
@testable import LatticeNode

/// Fuzzing the one surface an attacker controls completely: the bytes on the
/// wire, before anything has been authenticated.
///
/// Every node message decodes through the same contract — a size bound, a JSON
/// decode, `validate()`, then a canonical re-encode check. That contract is
/// only worth what it does on input nobody sanitised, and Swift's failure mode
/// for bad input is a TRAP, not a thrown error: an out-of-range index, an
/// overflowing conversion, or a force-unwrap takes the whole node down rather
/// than rejecting one peer's message. This repo has already shipped one of
/// those (an `offset=Int.max` on a read route was an uncatchable arithmetic
/// trap), which is the argument for fuzzing the rest.
///
/// Deterministic by construction: seeds are fixed and printed, so a failure
/// replays exactly rather than being a story about a run nobody still has.
/// `LATTICE_FUZZ_ITERATIONS` raises the budget for a longer soak; the default
/// is sized to stay inside an ordinary unit-test run.
final class WireProtocolFuzzTests: XCTestCase {

    /// Reproducible, portable, and not `SystemRandomNumberGenerator`: a fuzz
    /// failure is worthless if the input that caused it cannot be recreated.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private var iterations: Int {
        ProcessInfo.processInfo.environment["LATTICE_FUZZ_ITERATIONS"]
            .flatMap(Int.init) ?? 400
    }

    /// Real CIDs from this network, because some validators demand a
    /// canonically encoded one and a CID-shaped string will not do. Seeding
    /// with what the wire actually carries puts the fuzzer past the cheap
    /// rejections and into the checks worth attacking.
    private let cids = [
        "bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq",
        "bafyreibdhxo7e76c3szbi7i7qwzzgbhgliweuz7ewqba4ybk5h7itegjva",
        "bafyreif4a3a4rgpuhapiellfgmycngfyukrbajjuqkvcrslm43py5y6ixu",
        "bafyreifqhvjsjikap3cj5n6piiq7bh56r6evy5l4x76oyzq74lpy3fjw2q",
        "bafyreicblrogxiuxhduc7v6dgdslbptumqmk2mk3zqdizotof4onjhezxy",
    ].sorted()

    /// One valid message per wire type, as the seed corpus. Mutating a VALID
    /// encoding is what reaches the deep checks; random bytes almost always
    /// die at the JSON parse and test nothing but the parser.
    private func corpus() -> [(String, Data)] {
        var seeds: [(String, Data)] = []
        func add(_ name: String, _ encode: () throws -> Data) {
            do { seeds.append((name, try encode())) } catch {
                XCTFail("seed \(name) must be valid: \(error)")
            }
        }
        add("BlockAnnouncement") {
            try BlockAnnouncementMessage(
                blockCID: self.cids[0], height: 42
            ).encoded()
        }
        add("TransactionAvailable") {
            try TransactionAvailableMessage(
                volumeRootCID: self.cids[1]
            ).encoded()
        }
        add("AcceptedLeavesRequest") {
            try AcceptedLeavesRequestMessage(
                requestID: 7, afterCID: self.cids[0], snapshotSequence: 3
            ).encoded()
        }
        add("AcceptedLeavesResponse") {
            try AcceptedLeavesResponseMessage(
                requestID: 7,
                afterCID: nil,
                snapshotSequence: 3,
                blockCIDs: Array(self.cids.prefix(2)),
                hasMore: false
            ).encoded()
        }
        add("TransactionInventoryResponse") {
            try TransactionInventoryResponseMessage(
                requestID: 9,
                afterRootCID: nil,
                volumeRootCIDs: Array(self.cids.prefix(2)),
                hasMore: false
            ).encoded()
        }
        add("ForwardRangeRequest") {
            try ForwardRangeRequestMessage(
                requestID: 11, afterCID: self.cids[0]
            ).encoded()
        }
        add("ForwardRangeResponse") {
            try ForwardRangeResponseMessage(
                requestID: 11,
                afterCID: self.cids[0],
                blockCIDs: [self.cids[1]],
                hasMore: false
            ).encoded()
        }
        add("AncestorRangeRequest") {
            try AncestorRangeRequestMessage(
                requestID: 13, locator: [self.cids[1]]
            ).encoded()
        }
        add("ReadEndpointResponse") {
            try ReadEndpointResponseMessage(
                requestID: 17,
                genesisCID: self.cids[2],
                // Empty rather than a guessed URL: the validator demands a
                // string its own normaliser leaves unchanged, and inventing
                // one here would test my guess, not the protocol.
                readURLs: []
            ).encoded()
        }
        return seeds
    }

    /// Mutations chosen for the failure modes Swift actually has: truncation
    /// and splicing for index arithmetic, and digit-run replacement for the
    /// overflow/precision class that a bit flip almost never reaches, because
    /// `Int64.max + 1` has to be *spelled out* to be hit.
    private func mutate(
        _ data: Data, using generator: inout SplitMix64
    ) -> Data {
        var bytes = Array(data)
        guard !bytes.isEmpty else { return data }
        switch Int.random(in: 0..<7, using: &generator) {
        case 0:
            let index = Int.random(in: 0..<bytes.count, using: &generator)
            bytes[index] ^= UInt8(1 << Int.random(in: 0..<8, using: &generator))
        case 1:
            bytes.remove(at: Int.random(in: 0..<bytes.count, using: &generator))
        case 2:
            bytes.insert(
                UInt8.random(in: 0...255, using: &generator),
                at: Int.random(in: 0...bytes.count, using: &generator)
            )
        case 3:
            bytes = Array(
                bytes.prefix(Int.random(in: 0..<bytes.count, using: &generator))
            )
        case 4:
            let from = Int.random(in: 0..<bytes.count, using: &generator)
            let to = Int.random(in: 0..<bytes.count, using: &generator)
            bytes.swapAt(from, to)
        case 5:
            // Numeric extremes, spelled out where a number already is.
            let text = String(decoding: bytes, as: UTF8.self)
            let extremes = [
                "999999999999999999999999", "-1", "\(Int64.max)",
                "\(UInt64.max)", "0", "1e400", "-0",
            ]
            let replacement = extremes[
                Int.random(in: 0..<extremes.count, using: &generator)
            ]
            if let range = text.range(
                of: "[0-9]+", options: .regularExpression
            ) {
                bytes = Array(
                    text.replacingCharacters(in: range, with: replacement).utf8
                )
            }
        default:
            let start = Int.random(in: 0..<bytes.count, using: &generator)
            let end = Int.random(in: start..<bytes.count, using: &generator)
            bytes.append(contentsOf: bytes[start...end])
        }
        return Data(bytes)
    }

    /// Decode every mutant with every decoder. A message type must never trap,
    /// hang, or accept bytes it would not itself produce — whatever the sender
    /// claimed the type was.
    func testWireDecodersSurviveMutatedInput() throws {
        let seeds = corpus()
        XCTAssertFalse(seeds.isEmpty)
        var generator = SplitMix64(state: 0x5EED_1A77_1CE0_0001)
        var accepted = 0
        var rejected = 0

        for iteration in 0..<iterations {
            let (seedName, seed) = seeds[iteration % seeds.count]
            let mutant = mutate(seed, using: &generator)
            // The seed is the whole point: any failure below replays from it.
            let provenance = "seed \(seedName), generator state \(generator.state)"
            let outcomes = decodeWithEveryType(mutant, provenance: provenance)
            accepted += outcomes.accepted
            rejected += outcomes.rejected
        }

        // Not an assertion about the protocol, a check that the fuzzer is
        // actually working: all-rejected would mean the mutants never got past
        // the parser and the run proved nothing.
        XCTAssertGreaterThan(
            accepted, 0,
            "no mutant was ever accepted: the corpus is not reaching the validators"
        )
        XCTAssertGreaterThan(rejected, 0, "no mutant was ever rejected")
    }

    /// Every decoder, against one input. Returns how many accepted and
    /// rejected so the caller can tell a working fuzzer from a stuck one.
    private func decodeWithEveryType(
        _ data: Data, provenance: String
    ) -> (accepted: Int, rejected: Int) {
        var accepted = 0
        var rejected = 0
        func attempt<M: NodeJSONMessage & Equatable>(_ type: M.Type) {
            guard let value = try? M.decoded(data) else {
                rejected += 1
                return
            }
            accepted += 1
            // Accepting bytes it would not itself emit is the canonicity hole
            // the contract exists to close: two encodings of one message mean
            // two identities for one fact.
            guard let reencoded = try? value.encoded() else {
                XCTFail("accepted a message it cannot re-encode (\(provenance))")
                return
            }
            XCTAssertEqual(
                reencoded, data,
                "accepted a non-canonical encoding (\(provenance))"
            )
            XCTAssertNoThrow(
                try value.validate(),
                "accepted a message that fails its own validator (\(provenance))"
            )
        }
        attempt(BlockAnnouncementMessage.self)
        attempt(TransactionAvailableMessage.self)
        attempt(TransactionInventoryRequestMessage.self)
        attempt(TransactionInventoryResponseMessage.self)
        attempt(AcceptedLeavesRequestMessage.self)
        attempt(AcceptedLeavesResponseMessage.self)
        attempt(ForwardRangeRequestMessage.self)
        attempt(ForwardRangeResponseMessage.self)
        attempt(AncestorRangeRequestMessage.self)
        attempt(AncestorRangeResponseMessage.self)
        attempt(ChildGenesisAnchorRequestMessage.self)
        attempt(ChildGenesisAnchorResponseMessage.self)
        attempt(ReadEndpointRequestMessage.self)
        attempt(ReadEndpointResponseMessage.self)
        attempt(PortableAttachmentLocateRequestMessage.self)
        return (accepted, rejected)
    }

    /// The other direction: anything a node emits, a node must read back
    /// unchanged. A round-trip that loses or alters a field is a divergence
    /// between two honest peers, which no amount of validation catches.
    func testEveryEmittedMessageRoundTrips() throws {
        for (name, encoded) in corpus() {
            func check<M: NodeJSONMessage & Equatable>(_ type: M.Type) throws {
                guard let value = try? M.decoded(encoded) else { return }
                let again = try value.encoded()
                XCTAssertEqual(again, encoded, "\(name) lost bytes on re-encode")
                let decodedAgain = try M.decoded(again)
                XCTAssertEqual(
                    decodedAgain, value, "\(name) lost a field on round-trip"
                )
            }
            try check(BlockAnnouncementMessage.self)
            try check(TransactionAvailableMessage.self)
            try check(AcceptedLeavesRequestMessage.self)
            try check(AcceptedLeavesResponseMessage.self)
            try check(TransactionInventoryResponseMessage.self)
            try check(ForwardRangeRequestMessage.self)
            try check(ForwardRangeResponseMessage.self)
            try check(AncestorRangeRequestMessage.self)
            try check(ReadEndpointResponseMessage.self)
        }
    }

    /// Oversize input must be refused by the size bound, before the decoder
    /// allocates anything proportional to it.
    func testOversizedInputIsRefusedWithoutDecoding() throws {
        let huge = Data(repeating: UInt8(ascii: "{"), count: 4 * 1024 * 1024)
        XCTAssertThrowsError(try BlockAnnouncementMessage.decoded(huge))
        XCTAssertThrowsError(try AcceptedLeavesResponseMessage.decoded(huge))
    }
}
