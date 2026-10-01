import LatticeNodeSim
import XCTest

/// The generator and seed convention every seeded test replays through
/// (`Support/SeededGenerator.swift`). A drifted constant would silently
/// change every fuzz corpus and seeded sequence, so the output is pinned to
/// SplitMix64's published values rather than to itself.
/// Plain `XCTAssert` only (`XCTContext` is unavailable on corelibs XCTest).
final class SafetyNetSeededGeneratorTests: XCTestCase {

    func testSplitMix64MatchesItsReferenceSequence() {
        var generator = SplitMix64(state: 0)
        XCTAssertEqual(generator.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(generator.next(), 0x6E78_9E6A_A1B9_65F4)
        XCTAssertEqual(generator.next(), 0x06C4_5D18_8009_454F)
    }

    func testTheSameSeedReplaysTheSameDraws() {
        var first = SplitMix64(state: 0x5EED)
        var second = SplitMix64(state: 0x5EED)
        var other = SplitMix64(state: 0x5EEE)
        let draws = (0..<16).map { _ in Int.random(in: 0..<1_000, using: &first) }
        XCTAssertEqual(draws, (0..<16).map { _ in Int.random(in: 0..<1_000, using: &second) })
        XCTAssertNotEqual(draws, (0..<16).map { _ in Int.random(in: 0..<1_000, using: &other) })
    }

    func testSeedDefaultsUnlessTheVariableIsSet() throws {
        XCTAssertEqual(try TestSeed.resolve(default: 7, environment: [:]).value, 7)
        XCTAssertEqual(
            try TestSeed.resolve(default: 7, environment: [TestSeed.variable: "42"]).value,
            42
        )
        XCTAssertEqual(
            try TestSeed.resolve(default: 7, environment: [TestSeed.variable: "0x2A"]).value,
            42
        )
        XCTAssertEqual(
            try TestSeed.resolve(default: 7, environment: [TestSeed.variable: " 0x2a "]).value,
            42
        )
        XCTAssertEqual(
            try TestSeed.resolve(default: 7, environment: [TestSeed.variable: "0X2A"]).value,
            42
        )
        for maximum in ["18446744073709551615", "0xffffffffffffffff"] {
            XCTAssertEqual(
                try TestSeed.resolve(default: 7, environment: [TestSeed.variable: maximum]).value,
                .max
            )
        }
    }

    func testAMalformedSeedFailsNamingTheVariable() {
        // `ff` is refused, not read as hex: only the `0x` prefix means hex.
        for bad in ["", "0x", "ff", "forty-two", "0xZZ", "-1", "18446744073709551616"] {
            XCTAssertThrowsError(
                try TestSeed.resolve(default: 7, environment: [TestSeed.variable: bad]),
                "\(bad) was accepted"
            ) { error in
                XCTAssertTrue("\(error)".contains(TestSeed.variable), "\(error)")
            }
        }
    }

    func testABudgetDefaultsUnlessTheVariableIsSet() throws {
        XCTAssertEqual(try TestBudget.resolve("BUDGET", default: 7, environment: [:]), 7)
        XCTAssertEqual(
            try TestBudget.resolve("BUDGET", default: 7, environment: ["BUDGET": " 42 "]),
            42
        )
    }

    func testAMalformedBudgetFailsNamingTheVariable() {
        for bad in ["", "0", "-3", "4O", "0x10", "1e3", "99999999999999999999"] {
            XCTAssertThrowsError(
                try TestBudget.resolve("BUDGET", default: 7, environment: ["BUDGET": bad]),
                "\(bad) was accepted"
            ) { error in
                XCTAssertTrue("\(error)".contains("BUDGET="), "\(error)")
            }
        }
    }

    func testASeedPrintsTheAssignmentThatReplaysIt() throws {
        let seed = try TestSeed.resolve(default: 0x5EED_1A77_1CE0_0001, environment: [:])
        XCTAssertEqual("\(seed)", "LATTICE_TEST_SEED=0x5eed1a771ce00001")
        let replayed = try TestSeed.resolve(
            default: 0,
            environment: [TestSeed.variable: String("\(seed)".split(separator: "=")[1])]
        )
        XCTAssertEqual(replayed.value, seed.value)
    }
}
