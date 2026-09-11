import Foundation
import Lattice
import UInt256

/// Exact miner-facing template returned by `POST /v1/mining/templates`.
/// The coordinator keeps canonical block bytes internally because workers are
/// deliberately transport-agnostic nonce searchers.
public struct TemplateResponse: Decodable, Sendable, Equatable {
    public let workID: String
    public let blockHex: String
    /// Consensus PoW preimage prefix (hex), so transport-agnostic workers can
    /// search without parsing block bytes. Empty only for hand-built values
    /// whose blockHex is not a decodable Block.
    public let prefixHex: String
    public let searchTarget: String
    /// Every target this work can clear, easiest first (`searchTarget`
    /// leads). Just `searchTarget` when a node predates the field.
    public let targets: [String]
    public let chainPath: [String]
    public let expiresInMilliseconds: UInt64
    public let staleToken: String

    public init(
        workID: String,
        blockHex: String,
        searchTarget: String,
        targets: [String]? = nil,
        chainPath: [String] = ["Nexus"],
        expiresInMilliseconds: UInt64 = 30_000,
        staleToken: String? = nil
    ) {
        self.workID = workID
        self.blockHex = blockHex
        self.prefixHex = Self.derivePrefixHex(blockHex: blockHex)
        self.searchTarget = searchTarget
        self.targets = targets ?? [searchTarget]
        self.chainPath = chainPath
        self.expiresInMilliseconds = expiresInMilliseconds
        self.staleToken = staleToken ?? workID
    }

    public static func derivePrefixHex(blockHex: String) -> String {
        guard let data = Data(hex: blockHex), let block = Block(data: data) else {
            return ""
        }
        return Block.makeProofOfWorkPreimagePrefix(block: block)
            .map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey {
        case workID
        case block
        case searchTarget
        case targets
        case chainPath
        case expiresInMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workID = try container.decode(String.self, forKey: .workID)
        let block = try container.decode(Block.self, forKey: .block)
        guard let data = block.toData() else {
            throw DecodingError.dataCorruptedError(
                forKey: .block,
                in: container,
                debugDescription: "Block is not canonically serializable"
            )
        }
        blockHex = data.map { String(format: "%02x", $0) }.joined()
        prefixHex = Block.makeProofOfWorkPreimagePrefix(block: block)
            .map { String(format: "%02x", $0) }.joined()
        searchTarget = try container.decode(
            UInt256.self,
            forKey: .searchTarget
        ).toHexString()
        targets = try container.decodeIfPresent(
            [UInt256].self,
            forKey: .targets
        )?.map { $0.toHexString() } ?? [searchTarget]
        chainPath = try container.decode([String].self, forKey: .chainPath)
        expiresInMilliseconds = try container.decode(
            UInt64.self,
            forKey: .expiresInMilliseconds
        )
        staleToken = block.parent?.rawCID ?? workID
    }
}

public enum MinerLoopLogic {
    /// Parse a hex `UInt256` target (as produced by `UInt256.toHexString()`:
    /// four big-endian 64-bit words, most-significant first). Left-pads short
    /// strings and accepts an optional `0x` prefix. Inverse of `toHexString()`.
    public static func parseTarget(_ hex: String) -> UInt256? {
        var s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard !s.isEmpty, s.count <= 64, s.allSatisfy(\.isHexDigit) else { return nil }
        if s.count < 64 { s = String(repeating: "0", count: 64 - s.count) + s }
        var words: [UInt64] = []
        var idx = s.startIndex
        for _ in 0..<4 {
            let end = s.index(idx, offsetBy: 16)
            guard let w = UInt64(s[idx..<end], radix: 16) else { return nil }
            words.append(w)
            idx = end
        }
        return UInt256(words)
    }

    /// Parse a minimum work per block: `2^N` (N < 256) or a decimal integer.
    /// Zero, overflow, and anything else is nil.
    public static func parseMinimumWork(_ text: String) -> UInt256? {
        func isDigits(_ digits: Substring) -> Bool {
            !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
        }
        let work: UInt256?
        if text.hasPrefix("2^") {
            let exponent = text.dropFirst(2)
            guard isDigits(exponent), let shift = Int(exponent), shift < 256 else {
                return nil
            }
            work = UInt256(1) << shift
        } else {
            guard isDigits(Substring(text)) else { return nil }
            work = UInt256(text)
        }
        guard let work, work > .zero else { return nil }
        return work
    }

    /// The `minimumWork` field of `POST /v1/mining/templates` for `--min-work`
    /// entries of the form `<chain path>=<work>` (e.g. `Nexus/Payments=2^32`).
    /// Nil when any entry is malformed or names a chain twice.
    public static func minimumWorkField(_ entries: [String]) -> [[String: Any]]? {
        var seen: Set<String> = []
        var field: [[String: Any]] = []
        for entry in entries {
            let parts = entry.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  let work = parseMinimumWork(String(parts[1])) else {
                return nil
            }
            let chainPath = parts[0]
                .split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            guard chainPath.first == "Nexus",
                  !chainPath.contains(where: \.isEmpty),
                  seen.insert(String(parts[0])).inserted else {
                return nil
            }
            field.append([
                "chainPath": chainPath,
                "work": work.toPrefixedHexString(),
            ])
        }
        return field
    }
}
