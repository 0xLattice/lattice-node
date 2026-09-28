import Foundation

/// SplitMix64: reproducible, portable, and not `SystemRandomNumberGenerator`.
/// A seeded test's failure is worthless if the input that caused it cannot be
/// recreated, so every seeded test draws from this one generator.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The seed a seeded test starts from: `LATTICE_TEST_SEED` (decimal, or hex
/// with `0x`) when it is set, otherwise the test's own fixed default. An
/// ordinary run is deterministic; a run with another seed explores other
/// inputs and prints the seed that replays it.
struct TestSeed: CustomStringConvertible {
    static let variable = "LATTICE_TEST_SEED"

    struct Malformed: Error, CustomStringConvertible {
        let value: String
        var description: String {
            "\(TestSeed.variable)=\(value) is neither decimal nor 0x-prefixed hex"
        }
    }

    let value: UInt64

    static func resolve(
        default fixed: UInt64,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TestSeed {
        guard let raw = environment[variable] else { return TestSeed(value: fixed) }
        let text = raw.trimmingCharacters(in: .whitespaces)
        let parsed = text.lowercased().hasPrefix("0x")
            ? UInt64(text.dropFirst(2), radix: 16)
            : UInt64(text, radix: 10)
        guard let parsed else { throw Malformed(value: raw) }
        return TestSeed(value: parsed)
    }

    /// The assignment that replays this run: `LATTICE_TEST_SEED=0x…`.
    var description: String {
        "\(Self.variable)=0x\(String(value, radix: 16))"
    }
}
