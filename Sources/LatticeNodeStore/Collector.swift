import Foundation
import Lattice

extension Store {
    /// Mark-and-sweep content collection. The roots are what the live log
    /// names — every level's blocks (their headers link their bodies, states,
    /// specs and child indexes), each grind root, each level's genesis — the
    /// mempool, and `keeping`: content the caller holds in flight that no
    /// durable row names yet (a fetched body awaiting its verdict, an
    /// evidence index root). Everything reachable from a root by content
    /// links is kept; the rest is deleted. A dropped or replaced level's
    /// earlier rows are no roots.
    ///
    /// Weighed facts are never collected: only content is.
    @discardableResult
    public func collectGarbage(keeping: Set<String> = []) throws -> Int {
        try locked {
            var roots = keeping
            var levels: [String: Set<String>] = [:]
            try db.each("SELECT chain, kind, cid, fact FROM log ORDER BY seq") { row in
                let chain = row.text(0)
                switch LogKind(rawValue: row.text(1)) {
                case .level:
                    levels[chain] = [row.text(2)]
                case .drop:
                    levels[chain] = nil
                case .block, .work, .run:
                    levels[chain, default: []].insert(row.text(2))
                    for fact in try Self.decode(row.blob(3) ?? Data()).facts {
                        if case .work(let work) = fact { levels[chain, default: []].insert(work.contribution.id) }
                    }
                case .validation, .exclusion, nil:
                    break
                }
            }
            for cids in levels.values { roots.formUnion(cids) }
            try db.each("SELECT cid FROM mempool") { roots.insert($0.text(0)) }

            try db.script("CREATE TEMP TABLE IF NOT EXISTS gc_mark(cid TEXT PRIMARY KEY); DELETE FROM gc_mark;")
            var pending = Array(roots)
            while let cid = pending.popLast() {
                try db.run("INSERT OR IGNORE INTO gc_mark(cid) VALUES(?)", [.text(cid)])
                guard db.changes == 1,
                      let bytes = try db.first("SELECT bytes FROM content WHERE cid = ?", [.text(cid)], { $0.blob(0) }),
                      let bytes else { continue }
                guard let links = Links.of(bytes) else { throw StoreError.untraceable(cid) }
                pending += links
            }
            return try db.transaction {
                try db.run("DELETE FROM content WHERE cid NOT IN (SELECT cid FROM gc_mark)")
                return db.changes
            }
        }
    }
}

/// The links in one content node: cashew encodes every link as a DAG-CBOR
/// map `{rawCID: <cid>, encryptionInfo?}`, so every text value under a
/// `rawCID` key is a link. A value that merely looks like one only keeps
/// extra content; no link can be missed.
enum Links {
    /// nil when `bytes` is not CBOR (an encrypted or foreign node).
    static func of(_ bytes: Data) -> [String]? {
        var reader = Reader(bytes: [UInt8](bytes))
        var links: [String] = []
        do {
            _ = try reader.item(&links)
        } catch {
            return nil
        }
        return reader.offset == reader.bytes.count ? links : nil
    }

    private struct Malformed: Error {}

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        /// Read one item; return its text when it is a text string.
        mutating func item(_ links: inout [String], depth: Int = 0) throws -> String? {
            guard depth < 512 else { throw Malformed() }
            let (major, argument) = try head()
            switch major {
            case 0, 1:
                return nil
            case 2:
                try skip(argument)
                return nil
            case 3:
                let start = offset
                try skip(argument)
                return String(decoding: bytes[start..<offset], as: UTF8.self)
            case 4:
                for _ in 0..<argument { _ = try item(&links, depth: depth + 1) }
                return nil
            case 5:
                for _ in 0..<argument {
                    let key = try item(&links, depth: depth + 1)
                    let value = try item(&links, depth: depth + 1)
                    if key == "rawCID", let value { links.append(value) }
                }
                return nil
            case 6:
                _ = try item(&links, depth: depth + 1)
                return nil
            default:
                return nil
            }
        }

        private mutating func head() throws -> (UInt8, UInt64) {
            guard offset < bytes.count else { throw Malformed() }
            let initial = bytes[offset]
            offset += 1
            let major = initial >> 5
            let info = initial & 0x1F
            switch info {
            case 0..<24:
                return (major, UInt64(info))
            case 24, 25, 26, 27:
                let width = 1 << Int(info - 24)
                guard offset + width <= bytes.count else { throw Malformed() }
                var value: UInt64 = 0
                for byte in bytes[offset..<offset + width] { value = value << 8 | UInt64(byte) }
                offset += width
                // A float or simple value carries its bits, not a length.
                return (major, major == 7 ? 0 : value)
            default:
                // Indefinite lengths and reserved values are not DAG-CBOR.
                throw Malformed()
            }
        }

        private mutating func skip(_ count: UInt64) throws {
            guard count <= UInt64(bytes.count - offset) else { throw Malformed() }
            offset += Int(count)
        }
    }
}
