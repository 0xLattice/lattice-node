import Foundation
import Crypto
import Lattice
import cashew

struct StateRetainedRootAdvanceFailed: Error, CustomStringConvertible {
    let directory: String
    let reason: String
    var description: String { "\(directory): state retained-root advance failed: \(reason)" }
}

extension LatticeNode {
    private static let stateRetainedRootMergeChunkSize = 128

    static func stateRetainedRootOperationID(
        scope: String,
        tipHeight: UInt64,
        tipHash: String,
        roots: [String]
    ) -> String {
        let payload = try! JSONEncoder().encode(roots.sorted())
        let digest = Data(SHA256.hash(data: payload))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(scope):\(tipHeight):\(tipHash):\(digest)"
    }

    static func stateRetainedRootMergeOperationID(
        scope: String,
        tipHeight: UInt64,
        tipHash: String,
        roots: [String]
    ) -> String {
        let payload = try! JSONEncoder().encode(roots.sorted())
        let digest = Data(SHA256.hash(data: payload))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(scope):merge:\(tipHeight):\(tipHash):\(digest)"
    }

    func stateRetainedRootScope(network: ChainNetwork) -> String {
        ChainNetwork.stateRetainedRootScope(ownerNamespace: network.ownerNamespace)
    }

    static func mergeRetainedRoots(primary: [String], preserving existing: [String]) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for root in primary + existing where !root.isEmpty {
            guard seen.insert(root).inserted else { continue }
            roots.append(root)
        }
        return roots
    }

    static func retainedStateRootHeights(
        tipHeight: UInt64,
        storageMode: StorageMode = .stateful,
        blockRetention: BlockRetention,
        retentionDepth: UInt64
    ) -> [UInt64] {
        let start: UInt64
        let stateRetention = storageMode == .historical ? BlockRetention.historical : blockRetention
        switch stateRetention {
        case .tip:
            start = tipHeight
        case .retention:
            guard retentionDepth > 0 else {
                return [tipHeight]
            }
            if tipHeight > retentionDepth {
                let floor = tipHeight - retentionDepth + 1
                guard floor <= tipHeight else { return [] }
                start = floor
            } else {
                start = 0
            }
        case .historical:
            start = 0
        }
        return Array(start...tipHeight)
    }

    func retainedStateRootHeights(tipHeight: UInt64) -> [UInt64] {
        Self.retainedStateRootHeights(
            tipHeight: tipHeight,
            storageMode: config.storageMode,
            blockRetention: config.blockRetention,
            retentionDepth: config.retentionDepth
        )
    }

    func retainedCanonicalStateRoots(
        directory: String,
        network: ChainNetwork,
        tipHeight: UInt64,
        materializedBlocks: [UInt64: Block] = [:]
    ) async throws -> [String] {
        let heights = retainedStateRootHeights(tipHeight: tipHeight)
        guard !heights.isEmpty else { return [] }
        let fetcher = network.canonicalContentFetcher()
        var roots: [String] = []
        var seen = Set<String>()
        for height in heights {
            let root: String
            if let block = materializedBlocks[height] {
                root = block.postState.rawCID
            } else {
                // Read the chain/store DIRECTLY, not via getBlockHash(atIndex:):
                // that public accessor fail-closes on isChainUnavailable, which
                // is TRUE for the duration of any deep sync (gap > shallow
                // threshold) — but THIS read is the deep sync's own publish
                // path. Routing it through the external-consumer gate self-
                // deadlocks every deep catch-up: the sync can never publish
                // because the sync is running. The gate exists to blank reads
                // for external consumers mid-sync, not to starve the publisher.
                var directHash: String? = nil
                if let chainState = await chain(for: directory) {
                    directHash = await chainState.getMainChainBlockHash(atIndex: height)
                }
                if directHash == nil {
                    directHash = stateStores[chainKey(forDirectory: directory)]?.getBlockHash(atHeight: height)
                }
                guard let blockHash = directHash else {
                    throw StateRetainedRootAdvanceFailed(directory: directory, reason: "missing canonical block hash at height \(height)")
                }
                guard let block = try await VolumeImpl<Block>(rawCID: blockHash).resolve(fetcher: fetcher).node else {
                    throw StateRetainedRootAdvanceFailed(directory: directory, reason: "missing canonical block \(String(blockHash.prefix(16))) at height \(height)")
                }
                root = block.postState.rawCID
            }
            guard !root.isEmpty, seen.insert(root).inserted else { continue }
            roots.append(root)
        }
        return roots
    }

    func historicalStateRetainedRootMergeRoots(
        directory: String,
        network: ChainNetwork,
        tipHeight: UInt64,
        materializedBlocks: [UInt64: Block]
    ) async throws -> [String] {
        if !materializedBlocks.isEmpty {
            var roots: [String] = []
            var seen = Set<String>()
            for height in materializedBlocks.keys.sorted() where height <= tipHeight {
                guard let block = materializedBlocks[height] else { continue }
                let root = block.postState.rawCID
                guard !root.isEmpty, seen.insert(root).inserted else { continue }
                roots.append(root)
            }
            if !roots.isEmpty { return roots }
        }
        return try await retainedCanonicalStateRoots(
            directory: directory,
            network: network,
            tipHeight: tipHeight
        )
    }

    func mergeStateRetainedRoots(
        directory: String,
        network: ChainNetwork,
        tipHeight: UInt64,
        tipHash: String,
        roots: [String]
    ) async throws {
        guard stateRetentionViaRetainedRoots else { return }
        guard config.storageMode != .stateless else { return }
        let roots = Self.mergeRetainedRoots(primary: roots, preserving: [])
        guard !roots.isEmpty else { return }
        let scope = stateRetainedRootScope(network: network)
        var index = 0
        while index < roots.count {
            let end = min(index + Self.stateRetainedRootMergeChunkSize, roots.count)
            let chunk = Array(roots[index..<end])
            let operationID = Self.stateRetainedRootMergeOperationID(
                scope: scope,
                tipHeight: tipHeight,
                tipHash: tipHash,
                roots: chunk
            )
            try await network.mergeRetainedRootsDurably(scope: scope, roots: chunk, operationID: operationID)
            index = end
        }
    }

    func usesHistoricalStateRetainedRootMerge() -> Bool {
        config.storageMode == .historical || config.blockRetention == .historical
    }

    func advanceStateRetainedRoots(
        directory: String,
        network: ChainNetwork,
        tipHeight: UInt64,
        tipHash: String,
        materializedBlocks: [UInt64: Block] = [:],
        preserveExistingRoots: Bool = false
    ) async throws {
        guard stateRetentionViaRetainedRoots else { return }
        guard config.storageMode != .stateless else { return }
        if usesHistoricalStateRetainedRootMerge() {
            let roots = try await historicalStateRetainedRootMergeRoots(
                directory: directory,
                network: network,
                tipHeight: tipHeight,
                materializedBlocks: materializedBlocks
            )
            try await mergeStateRetainedRoots(
                directory: directory,
                network: network,
                tipHeight: tipHeight,
                tipHash: tipHash,
                roots: roots
            )
            return
        }
        var roots = try await retainedCanonicalStateRoots(
            directory: directory,
            network: network,
            tipHeight: tipHeight,
            materializedBlocks: materializedBlocks
        )
        let scope = stateRetainedRootScope(network: network)
        if preserveExistingRoots {
            roots = Self.mergeRetainedRoots(
                primary: roots,
                preserving: try await network.retainedRootsDurablyRequired(scope: scope)
            )
        }
        let operationID = Self.stateRetainedRootOperationID(
            scope: scope,
            tipHeight: tipHeight,
            tipHash: tipHash,
            roots: roots
        )
        try await network.advanceRetainedRootsDurably(scope: scope, roots: roots, operationID: operationID)
    }

    func advanceStateRetainedRootsIfCanonicalTip(
        block: Block,
        blockHash: String,
        network: ChainNetwork,
        directory: String
    ) async throws {
        guard await chain(for: directory)?.getMainChainTip() == blockHash else { return }
        try await advanceStateRetainedRoots(
            directory: directory,
            network: network,
            tipHeight: block.height,
            tipHash: blockHash,
            materializedBlocks: [block.height: block]
        )
    }

    func advanceStateRetainedRootsFromCurrentTip(directory: String, network: ChainNetwork) async {
        guard stateRetentionViaRetainedRoots else { return }
        guard let chain = await chain(for: directory) else { return }
        let tipHeight = await chain.getHighestBlockHeight()
        let tipHash = await chain.getMainChainTip()
        do {
            try await advanceStateRetainedRoots(
                directory: directory,
                network: network,
                tipHeight: tipHeight,
                tipHash: tipHash
            )
        } catch {
            NodeLogger("gc").error("\(directory): failed to advance startup state retained roots: \(error)")
            await markChainStorageDegraded(directory: directory, reason: "failed to advance startup state retained roots")
        }
    }
}
