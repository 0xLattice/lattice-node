import Foundation
import Lattice
import UInt256

/// Exact miner-facing template returned by `POST /v1/mining/templates`.
/// The coordinator keeps canonical block bytes internally because workers are
/// deliberately transport-agnostic nonce searchers.
public struct TemplateResponse: Decodable, Sendable, Equatable {
    public let workID: String
    public let blockHex: String
    public let searchTarget: String
    public let chainPath: [String]
    public let expiresInMilliseconds: UInt64
    public let staleToken: String

    public init(
        workID: String,
        blockHex: String,
        searchTarget: String,
        chainPath: [String] = ["Nexus"],
        expiresInMilliseconds: UInt64 = 30_000,
        staleToken: String? = nil
    ) {
        self.workID = workID
        self.blockHex = blockHex
        self.searchTarget = searchTarget
        self.chainPath = chainPath
        self.expiresInMilliseconds = expiresInMilliseconds
        self.staleToken = staleToken ?? workID
    }

    private enum CodingKeys: String, CodingKey {
        case workID
        case block
        case searchTarget
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
        searchTarget = try container.decode(
            UInt256.self,
            forKey: .searchTarget
        ).toHexString()
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
}
