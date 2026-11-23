import Foundation

/// SplitMix64: reproducible, portable, and not `SystemRandomNumberGenerator`.
/// A seeded test's failure is worthless if the input that caused it cannot be
/// recreated, so every seeded test draws from this one generator.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    public var state: UInt64

    public init(state: UInt64) {
        self.state = state
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    // Draws by explicit arithmetic on `next()`, never the standard library's
    // `random(in:using:)`, whose algorithm may change between Swift versions:
    // a seed must replay the same run on every toolchain.

    /// A value in `range` (modulo draw; the bias is irrelevant here).
    public mutating func draw(_ range: ClosedRange<Int64>) -> Int64 {
        let span = UInt64(bitPattern: range.upperBound &- range.lowerBound) &+ 1
        let offset = span == 0 ? next() : next() % span
        return range.lowerBound &+ Int64(bitPattern: offset)
    }

    public mutating func draw(_ range: ClosedRange<Int>) -> Int {
        Int(draw(Int64(range.lowerBound)...Int64(range.upperBound)))
    }

    /// A uniform value in [0, 1) from the top 53 bits.
    public mutating func unit() -> Double {
        Double(next() >> 11) * 0x1p-53
    }

    /// True with probability `probability`.
    public mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }
}

/// The seed a seeded test starts from: `LATTICE_TEST_SEED` (decimal, or hex
/// with `0x`) when it is set, otherwise the test's own fixed default. An
/// ordinary run is deterministic; a run with another seed explores other
/// inputs and prints the seed that replays it.
public struct TestSeed: CustomStringConvertible, Sendable {
    public static let variable = "LATTICE_TEST_SEED"

    public struct Malformed: Error, CustomStringConvertible {
        public let value: String
        public var description: String {
            "\(TestSeed.variable)=\(value) is neither decimal nor 0x-prefixed hex"
        }
    }

    public let value: UInt64

    public init(value: UInt64) {
        self.value = value
    }

    public static func resolve(
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
    public var description: String {
        "\(Self.variable)=0x\(String(value, radix: 16))"
    }
}

/// How many iterations a seeded test runs: `variable` (a positive decimal
/// integer) when it is set, otherwise the test's own default. A malformed
/// value fails the test naming the variable instead of silently running the
/// default, so a soak that asked for more work never passes on less.
public enum TestBudget {
    public struct Malformed: Error, CustomStringConvertible {
        public let variable: String
        public let value: String
        public var description: String {
            "\(variable)=\(value) is not a positive decimal integer"
        }
    }

    public static func resolve(
        _ variable: String,
        default fixed: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Int {
        guard let raw = environment[variable] else { return fixed }
        guard let parsed = Int(raw.trimmingCharacters(in: .whitespaces), radix: 10),
              parsed > 0 else {
            throw Malformed(variable: variable, value: raw)
        }
        return parsed
    }
}
