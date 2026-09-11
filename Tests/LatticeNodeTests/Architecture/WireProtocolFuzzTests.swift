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
/// than rejecting one peer's message. The public read router has already
/// shipped one of those, which is the argument for fuzzing the rest.
///
/// Deterministic by construction: seeds are fixed, and a failure reports the
/// generator state it started from, the iteration, and the mutant's bytes, so
/// it replays exactly. `LATTICE_FUZZ_ITERATIONS` raises the budget for a longer
/// soak; the default is sized to stay inside an ordinary unit-test run.
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

    /// Real CIDs from this network, because several validators demand a
    /// canonically encoded one and a CID-shaped string will not do.
    private let cids = [
        "bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq",
        "bafyreibdhxo7e76c3szbi7i7qwzzgbhgliweuz7ewqba4ybk5h7itegjva",
        "bafyreif4a3a4rgpuhapiellfgmycngfyukrbajjuqkvcrslm43py5y6ixu",
        "bafyreifqhvjsjikap3cj5n6piiq7bh56r6evy5l4x76oyzq74lpy3fjw2q",
        "bafyreicblrogxiuxhduc7v6dgdslbptumqmk2mk3zqdizotof4onjhezxy",
    ].sorted()

    /// One valid message per decoder, carrying a round-trip that starts from
    /// the constructed VALUE. Decoding an encoding and re-encoding it cannot
    /// fail — `decoded` already refuses non-canonical bytes — so the property
    /// worth checking is that a value survives encode-then-decode intact.
    private struct Seed {
        let name: String
        let data: Data
        let roundTrip: () throws -> Void
    }

    private func seed<M: NodeJSONMessage & Equatable>(
        _ value: M
    ) throws -> Seed {
        let data = try value.encoded()
        let name = String(describing: M.self)
        return Seed(name: name, data: data, roundTrip: {
            // `try`, not `try?`: a seed that stops decoding as its own type
            // must FAIL, not be skipped as though it were not applicable.
            let back = try M.decoded(data)
            XCTAssertEqual(back, value, "\(name) lost a field on round-trip")
        })
    }

    /// Every decoder has a seed. A decoder without one is fuzzed only by
    /// accident — its validator is unreachable unless a mutation happens to
    /// spell its whole schema — so it would pass while covering nothing.
    private func corpus() throws -> [Seed] {
        [
            try seed(BlockAnnouncementMessage(blockCID: cids[0], height: 42)),
            try seed(TransactionAvailableMessage(volumeRootCID: cids[1])),
            try seed(TransactionInventoryRequestMessage(
                requestID: 23, afterRootCID: cids[0]
            )),
            try seed(TransactionInventoryResponseMessage(
                requestID: 9,
                afterRootCID: nil,
                volumeRootCIDs: Array(cids.prefix(2)),
                hasMore: false
            )),
            try seed(AcceptedLeavesRequestMessage(
                requestID: 7, afterCID: cids[0], snapshotSequence: 3
            )),
            try seed(AcceptedLeavesResponseMessage(
                requestID: 7,
                afterCID: nil,
                snapshotSequence: 3,
                blockCIDs: Array(cids.prefix(2)),
                hasMore: false
            )),
            try seed(ForwardRangeRequestMessage(requestID: 11, afterCID: cids[0])),
            try seed(ForwardRangeResponseMessage(
                requestID: 11,
                afterCID: cids[0],
                blockCIDs: [cids[1]],
                hasMore: false
            )),
            try seed(AncestorRangeRequestMessage(requestID: 13, locator: [cids[1]])),
            try seed(AncestorRangeResponseMessage(
                requestID: 24,
                commonAncestor: cids[0],
                blockCIDs: [cids[1]],
                hasMore: false
            )),
            try seed(ChildGenesisAnchorRequestMessage(requestID: 21)),
            try seed(ChildGenesisAnchorResponseMessage(
                requestID: 22, genesisCID: cids[3]
            )),
            try seed(ReadEndpointRequestMessage(requestID: 26, genesisCID: cids[2])),
            try seed(ReadEndpointResponseMessage(
                requestID: 17,
                genesisCID: cids[2],
                // Empty rather than a guessed URL: the validator demands a
                // string its own normaliser leaves unchanged, and inventing
                // one here would test my guess, not the protocol.
                readURLs: []
            )),
            try seed(PortableAttachmentLocateRequestMessage(
                requestID: 25, childCID: cids[4]
            )),
        ]
    }

    /// JSON number VALUES — digits after a colon — not the first digit run in
    /// the text. Keys are sorted and CIDs are full of digits, so matching the
    /// first run lands inside a CID almost every time and never puts an
    /// extreme into `height`, `requestID` or `snapshotSequence`.
    private static let numberValue = try? NSRegularExpression(
        pattern: #":(-?[0-9]+)"#
    )

    /// Swap one JSON number VALUE for `replacement`, or nil when there is none.
    private func replaceNumberValue(
        in data: Data, with replacement: String, using generator: inout SplitMix64
    ) -> Data? {
        let text = String(decoding: data, as: UTF8.self)
        let whole = NSRange(text.startIndex..., in: text)
        guard let matches = Self.numberValue?.matches(in: text, range: whole),
              !matches.isEmpty else { return nil }
        let chosen = matches[Int.random(in: 0..<matches.count, using: &generator)]
        guard let range = Range(chosen.range(at: 1), in: text) else { return nil }
        return Data(text.replacingCharacters(in: range, with: replacement).utf8)
    }

    /// Mutations chosen for the failure modes Swift actually has: truncation
    /// and splicing for index arithmetic, and number-value replacement for the
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
            let extremes = [
                "999999999999999999999999", "-1", "\(Int64.max)",
                "\(UInt64.max)", "18446744073709551616", "0", "1e400", "-0",
            ]
            let replacement = extremes[
                Int.random(in: 0..<extremes.count, using: &generator)
            ]
            if let replaced = replaceNumberValue(
                in: Data(bytes), with: replacement, using: &generator
            ) {
                bytes = Array(replaced)
            }
        default:
            let start = Int.random(in: 0..<bytes.count, using: &generator)
            let end = Int.random(in: start..<bytes.count, using: &generator)
            bytes.append(contentsOf: bytes[start...end])
        }
        return Data(bytes)
    }

    /// Each decoder, as a probe that reports whether it accepted the input and
    /// asserts the contract whenever it did.
    private typealias Probe = (name: String, run: (Data, String) -> Bool)

    private func probe<M: NodeJSONMessage & Equatable>(_ type: M.Type) -> Probe {
        (String(describing: M.self), { data, provenance in
            guard let value = try? M.decoded(data) else { return false }
            // Accepting bytes it would not itself emit is the canonicity hole
            // the contract exists to close: two encodings of one message mean
            // two identities for one fact.
            guard let reencoded = try? value.encoded() else {
                XCTFail("accepted a message it cannot re-encode (\(provenance))")
                return true
            }
            XCTAssertEqual(
                reencoded, data,
                "accepted a non-canonical encoding (\(provenance))"
            )
            let validates = (try? value.validate()) != nil
            XCTAssertTrue(
                validates,
                "accepted a message that fails its own validator (\(provenance))"
            )
            return true
        })
    }

    private var probes: [Probe] {
        [
            probe(BlockAnnouncementMessage.self),
            probe(TransactionAvailableMessage.self),
            probe(TransactionInventoryRequestMessage.self),
            probe(TransactionInventoryResponseMessage.self),
            probe(AcceptedLeavesRequestMessage.self),
            probe(AcceptedLeavesResponseMessage.self),
            probe(ForwardRangeRequestMessage.self),
            probe(ForwardRangeResponseMessage.self),
            probe(AncestorRangeRequestMessage.self),
            probe(AncestorRangeResponseMessage.self),
            probe(ChildGenesisAnchorRequestMessage.self),
            probe(ChildGenesisAnchorResponseMessage.self),
            probe(ReadEndpointRequestMessage.self),
            probe(ReadEndpointResponseMessage.self),
            probe(PortableAttachmentLocateRequestMessage.self),
        ]
    }

    /// Decode every mutant with every decoder. A message type must never trap,
    /// hang, or accept bytes it would not itself produce — whatever the sender
    /// claimed the type was.
    func testWireDecodersSurviveMutatedInput() throws {
        let seeds = try corpus()
        let probes = self.probes
        var acceptedBy: [String: Int] = [:]

        // Every unmutated seed first. This is what guarantees each decoder is
        // actually exercised: its own seed must reach its validator.
        for seed in seeds {
            for probe in probes where probe.run(seed.data, "unmutated \(seed.name)") {
                acceptedBy[probe.name, default: 0] += 1
            }
        }

        var generator = SplitMix64(state: 0x5EED_1A77_1CE0_0001)
        var rejected = 0
        for iteration in 0..<iterations {
            let seed = seeds[iteration % seeds.count]
            // Captured BEFORE the mutation advances the generator: with the
            // seed name and iteration this recreates the mutant exactly, and
            // the bytes are included so nobody has to.
            let startState = generator.state
            let mutant = mutate(seed.data, using: &generator)
            let provenance = """
                iteration \(iteration), seed \(seed.name), \
                generator state before mutation \(startState), \
                mutant hex \(mutant.map { String(format: "%02x", $0) }.joined())
                """
            for probe in probes {
                if probe.run(mutant, provenance) {
                    acceptedBy[probe.name, default: 0] += 1
                } else {
                    rejected += 1
                }
            }
        }

        // Per decoder, not in aggregate: one busy decoder must not hide one
        // whose validator the run never reached.
        for probe in probes {
            XCTAssertGreaterThan(
                acceptedBy[probe.name, default: 0], 0,
                "\(probe.name) never accepted anything: its validator went unexercised"
            )
        }
        XCTAssertGreaterThan(rejected, 0, "no mutant was ever rejected")
    }

    /// The overflow mutation has to reach number FIELDS. Matching the first
    /// digit run lands inside a CID — they are full of digits and keys sort
    /// before most numbers — so `height` would never see an extreme at all.
    func testNumberMutationLandsOnNumberValuesNotInsideCIDs() throws {
        let cid = cids[0]
        XCTAssertTrue(
            cid.contains(where: \.isNumber),
            "the check is only meaningful against a CID that contains digits"
        )
        let data = try BlockAnnouncementMessage(blockCID: cid, height: 42).encoded()
        var generator = SplitMix64(state: 1)
        for _ in 0..<64 {
            let mutated = try XCTUnwrap(
                replaceNumberValue(in: data, with: "\(UInt64.max)", using: &generator)
            )
            let text = String(decoding: mutated, as: UTF8.self)
            XCTAssertTrue(text.contains(cid), "a CID was altered: \(text)")
            XCTAssertTrue(
                text.contains("\"height\":\(UInt64.max)"),
                "the number field was not the one replaced: \(text)"
            )
        }
    }

    /// The failure message promises a replay. That promise is only true if the
    /// generator state recorded before a mutation regenerates the same bytes.
    func testRecordedStartStateReplaysTheExactMutant() throws {
        for seed in try corpus() {
            var original = SplitMix64(state: 0xC0FF_EE00_DEAD_BEEF)
            for _ in 0..<32 {
                let start = original.state
                let mutant = mutate(seed.data, using: &original)
                var replay = SplitMix64(state: start)
                XCTAssertEqual(
                    mutate(seed.data, using: &replay), mutant,
                    "\(seed.name): a recorded start state did not replay its mutant"
                )
            }
        }
    }

    /// The other direction: anything a node emits, a node must read back
    /// unchanged. A round-trip that loses or alters a field is a divergence
    /// between two honest peers, which no amount of validation catches.
    func testEveryEmittedMessageRoundTrips() throws {
        let seeds = try corpus()
        XCTAssertEqual(seeds.count, probes.count, "every decoder needs a seed")
        for seed in seeds {
            try seed.roundTrip()
        }
    }

    /// Oversize input must be refused by the size bound itself, before the
    /// decoder allocates anything proportional to it. The payload is WELL-
    /// FORMED JSON on purpose: with the bound removed the parser would accept
    /// it and the validator would reject it as merely malformed, so only the
    /// size bound can produce `.oversized`.
    func testOversizedInputIsRefusedByTheSizeBoundNotTheParser() {
        let padding = String(repeating: "a", count: 5 * 1024 * 1024)
        let wellFormed = Data("{\"blockCID\":\"\(padding)\"}".utf8)
        XCTAssertThrowsError(try BlockAnnouncementMessage.decoded(wellFormed)) {
            XCTAssertEqual($0 as? NodeNetworkWireError, .oversized)
        }
    }
}
