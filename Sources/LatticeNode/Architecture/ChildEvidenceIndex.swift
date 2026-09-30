import Foundation
import Lattice
import cashew

/// This chain's index of the child-block proofs it admitted with a work
/// contribution: `childCID → ProofSet`, where a ProofSet is
/// `rootCID (grind ID) → ChildEvidenceVolume`. Every outer trie node and every
/// ProofSet is its own Volume, so the index is served, fetched and retained
/// with the ordinary Volume exchange. The root is independent of insertion
/// order: equal sets have equal roots, so one root compare tells two nodes
/// whether they differ, and a walk that skips equal subtrees finds where.
enum ChildEvidenceIndex {
    typealias ProofVolume = VolumeImpl<ChildEvidenceVolume.Manifest>
    typealias ProofSet = MerkleDictionaryImpl<ProofVolume>
    typealias ProofSetVolume = VolumeImpl<ProofSet>
    typealias Trie = VolumeMerkleDictionaryImpl<ProofSetVolume>
    typealias Root = VolumeImpl<Trie>
    typealias Branch = VolumeRadixHeaderImpl<ProofSetVolume>

    /// One proof: child block `childCID`, secured by the grind `rootCID`,
    /// carried by the `ChildEvidenceVolume` `attachmentCID`.
    struct Entry: Hashable, Sendable {
        let childCID: String
        let rootCID: String
        let attachmentCID: String
    }

    /// A new root and the Volumes that changed to make it: `added` are the
    /// new root's path Volumes the base lacked, `released` the base's path
    /// Volumes the new root no longer references.
    struct Update: Sendable, Equatable {
        let baseRoot: String?
        let root: String
        let added: [String]
        let released: [String]
    }

    enum IndexError: Error, Equatable {
        case malformed
    }

    /// Inserts `entries` into the index at `baseRoot` (nil: empty), storing
    /// only the Volumes on the changed paths. Nil when every entry is already
    /// present.
    static func inserting(
        _ entries: [Entry],
        into baseRoot: String?,
        fetcher: any Fetcher,
        storer: any VolumeStorer
    ) async throws -> Update? {
        let keys = Array(Set(entries.map(\.childCID))).sorted()
        guard !keys.isEmpty else { return nil }
        let base = try await resolvePaths(baseRoot, keys: keys, fetcher: fetcher)
        var trie = base
        var changed = false
        for entry in entries.sorted(by: {
            ($0.childCID, $0.rootCID) < ($1.childCID, $1.rootCID)
        }) {
            let existing = try trie.get(key: entry.childCID)
            var set = try await resolvedSet(existing, fetcher: fetcher)
                ?? ProofSet(children: [:], count: 0)
            guard try set.get(key: entry.rootCID) == nil else { continue }
            set = try set.inserting(
                key: entry.rootCID,
                value: ProofVolume(
                    rawCID: entry.attachmentCID,
                    node: nil,
                    encryptionInfo: nil
                )
            )
            let setVolume = try ProofSetVolume(node: set)
            trie = existing == nil
                ? try trie.inserting(key: entry.childCID, value: setVolume)
                : try trie.mutating(key: entry.childCID, value: setVolume)
            changed = true
        }
        guard changed else { return nil }
        let root = try Root(node: trie)
        // Only the loaded Volumes can have changed: the inserted keys' paths,
        // and a sibling a radix split re-prefixed. Every other Volume is an
        // unloaded reference shared with the base.
        let loaded = loadedVolumes(trie, root: root)
        let baseLoaded = Set(baseRoot.map {
            loadedVolumes(base, root: Root(rawCID: $0, node: base, encryptionInfo: nil))
                .map(\.rawCID)
        } ?? [])
        for volume in loaded where !baseLoaded.contains(volume.rawCID) {
            try await volume.store(storer: storer)
        }
        let current = Set(loaded.map(\.rawCID))
        return Update(
            baseRoot: baseRoot,
            root: root.rawCID,
            added: current.subtracting(baseLoaded).sorted(),
            released: baseLoaded.subtracting(current).sorted()
        )
    }

    /// The proofs the index at `root` holds for each of `keys`:
    /// `childCID → rootCID → attachmentCID`. Absent keys are omitted.
    static func entries(
        for keys: [String],
        root: String,
        fetcher: any Fetcher
    ) async throws -> [String: [String: String]] {
        guard !keys.isEmpty else { return [:] }
        let trie = try await resolvePaths(root, keys: keys, fetcher: fetcher)
        var result: [String: [String: String]] = [:]
        for key in Set(keys).sorted() {
            guard let set = try await resolvedSet(
                try trie.get(key: key),
                fetcher: fetcher
            ) else { continue }
            result[key] = try set.allKeysAndValues().mapValues(\.rawCID)
        }
        return result
    }

    /// The entries the index at `peerRoot` holds that the index at
    /// `localRoot` lacks: for every `wanted` key, and for every key the
    /// local index holds. Subtrees whose CIDs match are skipped, and keys
    /// only the peer holds are never descended into; where the two radix
    /// shapes compress differently, the walk aligns their labels.
    static func missingEntries(
        peerRoot: String,
        localRoot: String?,
        wanted: [String],
        peer: any Fetcher,
        local: any Fetcher
    ) async throws -> [Entry] {
        var differing: [(key: String, peer: ProofSetVolume, local: ProofSetVolume)] = []
        if let localRoot, localRoot != peerRoot {
            let peerTrie = try await node(Root(
                rawCID: peerRoot, node: nil, encryptionInfo: nil
            ), fetcher: peer)
            let localTrie = try await node(Root(
                rawCID: localRoot, node: nil, encryptionInfo: nil
            ), fetcher: local)
            for (character, localBranch) in localTrie.children.sorted(by: {
                $0.key < $1.key
            }) {
                guard let peerBranch = peerTrie.children[character],
                      peerBranch.rawCID != localBranch.rawCID else { continue }
                let peerNode = try await node(peerBranch, fetcher: peer)
                let localNode = try await node(localBranch, fetcher: local)
                try await compare(
                    peerNode, peerNode.prefix[...],
                    localNode, localNode.prefix[...],
                    path: "",
                    peer: peer, local: local,
                    differing: &differing
                )
            }
        }
        var missing: [Entry] = []
        for leaf in differing {
            guard let peerSet = try await resolvedSet(leaf.peer, fetcher: peer)
            else { continue }
            let held = Set(try await resolvedSet(leaf.local, fetcher: local)?
                .allKeys() ?? [])
            for (rootCID, proof) in try peerSet.allKeysAndValues()
            where !held.contains(rootCID) {
                missing.append(Entry(
                    childCID: leaf.key,
                    rootCID: rootCID,
                    attachmentCID: proof.rawCID
                ))
            }
        }
        let keys = Array(Set(wanted)).sorted()
        let peerEntries = try await entries(for: keys, root: peerRoot, fetcher: peer)
        var localEntries: [String: [String: String]] = [:]
        if let localRoot {
            localEntries = try await entries(for: keys, root: localRoot, fetcher: local)
        }
        for key in keys {
            for (rootCID, attachmentCID) in peerEntries[key] ?? [:]
            where localEntries[key]?[rootCID] == nil {
                missing.append(Entry(
                    childCID: key,
                    rootCID: rootCID,
                    attachmentCID: attachmentCID
                ))
            }
        }
        return Array(Set(missing)).sorted {
            ($0.childCID, $0.rootCID) < ($1.childCID, $1.rootCID)
        }
    }

    /// What a fetched proof Volume is worth for `entry`.
    enum Verdict {
        /// The Volume carries this package for `entry`.
        case valid(ChildValidationPackage)
        /// Refused by this node's own policy (the witness-size limit):
        /// never the peer's fault.
        case skipped
        /// The bytes do not carry a proof `entry` names, or the held child
        /// shows the proof contributes no work: an honest index holds none.
        case invalid
    }

    /// Judges a fetched proof Volume for `entry`: the Volume is
    /// `entry.attachmentCID` bound to `entry.childCID`, its envelope decodes
    /// within the protocol cap, and its proof is the grind `entry.rootCID`
    /// for that child. `weighs` is nil when the child is not held, so only
    /// a held block's proof is judged on its work. Depends on the bytes
    /// (and the held child) alone, except the local size limit.
    nonisolated static func verdict(
        _ serialized: SerializedVolume?,
        entry: Entry,
        maximumEncodedSize: Int,
        weighs: @Sendable (ChildBlockProof, String) async -> Bool?
    ) async -> Verdict {
        guard let serialized,
              serialized.root == entry.attachmentCID,
              let volume = try? ChildEvidenceVolume(
                serialized: serialized,
                childCID: entry.childCID
              ),
              let envelope = try? ChildValidationPackageEnvelope.decode(
                volume.envelopeBytes
              ),
              let package = try? envelope.makeValidationPackage(),
              package.proof.rootCID == entry.rootCID,
              let edge = await DirectChildEdge.derive(from: package.proof),
              edge.childCID == entry.childCID else {
            return .invalid
        }
        guard volume.envelopeBytes.count <= maximumEncodedSize else {
            return .skipped
        }
        guard await weighs(package.proof, entry.childCID) != false else {
            return .invalid
        }
        return .valid(package)
    }

    /// What one sync pass against a peer's root produced: the proofs that
    /// verified, and whether the pass stopped on a failure (the tries or a
    /// proof did not resolve or did not verify). `localFailure`: this node
    /// could not read its own index, which is never the peer's fault.
    struct Collected: Sendable {
        var verified: [(entry: Entry, package: ChildValidationPackage)] = []
        var failed = false
        var localFailure = false
    }

    private actor FetchFailures {
        private(set) var occurred = false
        func record() { occurred = true }
    }

    private struct TrackedFetcher: Fetcher {
        let base: any Fetcher
        let failures: FetchFailures

        func fetch(rawCid: String) async throws -> Data {
            do {
                return try await base.fetch(rawCid: rawCid)
            } catch {
                await failures.record()
                throw error
            }
        }
    }

    /// Fetches and verifies every entry `missingEntries` finds, stopping at
    /// the first failure; a proof this node's own policy refuses is skipped.
    /// A `wanted` block is not held yet: one proof for it is enough this
    /// pass, and the rest arrive by the walk once it is admitted and indexed.
    /// Blame is the caller's: it depends on whether the fetch was complete.
    static func collect(
        peerRoot: String,
        localRoot: String?,
        wanted: [String],
        peer: any Fetcher,
        local: any Fetcher,
        maximumEncodedSize: Int,
        weighs: @Sendable (ChildBlockProof, String) async -> Bool?
    ) async -> Collected {
        var collected = Collected()
        let localFailures = FetchFailures()
        let missing: [Entry]
        do {
            missing = try await missingEntries(
                peerRoot: peerRoot,
                localRoot: localRoot,
                wanted: wanted,
                peer: peer,
                local: TrackedFetcher(base: local, failures: localFailures)
            )
        } catch {
            collected.failed = true
            collected.localFailure = await localFailures.occurred
            return collected
        }
        let wantedKeys = Set(wanted)
        var found = Set<String>()
        for entry in missing {
            if wantedKeys.contains(entry.childCID), found.contains(entry.childCID) {
                continue
            }
            let data = try? await peer.fetch(rawCid: entry.attachmentCID)
            switch await verdict(
                data.map {
                    SerializedVolume(
                        root: entry.attachmentCID,
                        entries: [entry.attachmentCID: $0]
                    )
                },
                entry: entry,
                maximumEncodedSize: maximumEncodedSize,
                weighs: weighs
            ) {
            case .valid(let package):
                collected.verified.append((entry, package))
                found.insert(entry.childCID)
            case .skipped:
                continue
            case .invalid:
                collected.failed = true
                return collected
            }
        }
        return collected
    }

    /// Every Volume of the index at `root` (the root, each outer node, each
    /// ProofSet): what this node pins for its current root.
    static func volumes(root: String, fetcher: any Fetcher) async throws -> [String] {
        var volumes = [root]
        let trie = try await node(
            Root(rawCID: root, node: nil, encryptionInfo: nil),
            fetcher: fetcher
        )
        var pending = Array(trie.children.values)
        while let branch = pending.popLast() {
            volumes.append(branch.rawCID)
            let resolved = try await node(branch, fetcher: fetcher)
            if let value = resolved.value { volumes.append(value.rawCID) }
            pending.append(contentsOf: resolved.children.values)
        }
        return volumes
    }

    // MARK: - Trie helpers

    private static func resolvePaths(
        _ root: String?,
        keys: [String],
        fetcher: any Fetcher
    ) async throws -> Trie {
        guard let root else { return Trie(children: [:], count: 0) }
        let resolved = try await Root(
            rawCID: root, node: nil, encryptionInfo: nil
        ).resolve(
            paths: Dictionary(uniqueKeysWithValues: keys.map {
                ([$0], ResolutionStrategy.targeted)
            }),
            fetcher: fetcher
        )
        guard let trie = resolved.node else { throw IndexError.malformed }
        return trie
    }

    private static func node<H: Header>(
        _ header: H,
        fetcher: any Fetcher
    ) async throws -> H.NodeType {
        guard let node = try await header.resolve(fetcher: fetcher).node else {
            throw IndexError.malformed
        }
        return node
    }

    /// A ProofSet with its whole (single-Volume) radix structure loaded.
    private static func resolvedSet(
        _ volume: ProofSetVolume?,
        fetcher: any Fetcher
    ) async throws -> ProofSet? {
        guard let volume else { return nil }
        return try await node(volume, fetcher: fetcher).resolveList(fetcher: fetcher)
    }

    /// Compares two radix nodes whose remaining labels are `peerLabel` and
    /// `localLabel`, both below `path`. Where one label ends first, its
    /// node's child at the other's next character is compared against the
    /// rest of the longer label, so reads follow only the keys both hold.
    private static func compare(
        _ peerNode: Branch.NodeType,
        _ peerLabel: Substring,
        _ localNode: Branch.NodeType,
        _ localLabel: Substring,
        path: String,
        peer: any Fetcher,
        local: any Fetcher,
        differing: inout [(key: String, peer: ProofSetVolume, local: ProofSetVolume)]
    ) async throws {
        let common = zip(peerLabel, localLabel).prefix { $0 == $1 }.count
        // Labels that diverge before either ends: the key sets are disjoint.
        guard common == min(peerLabel.count, localLabel.count) else { return }
        if peerLabel.count > common {
            let rest = peerLabel.dropFirst(common)
            guard let child = localNode.children[rest.first!] else { return }
            let childNode = try await node(child, fetcher: local)
            try await compare(
                peerNode, rest, childNode, childNode.prefix[...],
                path: path + localLabel,
                peer: peer, local: local, differing: &differing
            )
            return
        }
        if localLabel.count > common {
            let rest = localLabel.dropFirst(common)
            guard let child = peerNode.children[rest.first!] else { return }
            let childNode = try await node(child, fetcher: peer)
            try await compare(
                childNode, childNode.prefix[...], localNode, rest,
                path: path + peerLabel,
                peer: peer, local: local, differing: &differing
            )
            return
        }
        let key = path + localLabel
        if let localValue = localNode.value, let peerValue = peerNode.value,
           localValue.rawCID != peerValue.rawCID {
            differing.append((key, peerValue, localValue))
        }
        for (character, localChild) in localNode.children.sorted(by: {
            $0.key < $1.key
        }) {
            guard let peerChild = peerNode.children[character],
                  peerChild.rawCID != localChild.rawCID else { continue }
            let peerChildNode = try await node(peerChild, fetcher: peer)
            let localChildNode = try await node(localChild, fetcher: local)
            try await compare(
                peerChildNode, peerChildNode.prefix[...],
                localChildNode, localChildNode.prefix[...],
                path: key,
                peer: peer, local: local, differing: &differing
            )
        }
    }

    /// The loaded Volumes of a trie: its root, each outer node whose node
    /// is loaded, and each loaded ProofSet.
    private static func loadedVolumes(_ trie: Trie, root: Root) -> [any Volume] {
        var volumes: [any Volume] = [root]
        var pending = Array(trie.children.values)
        while let branch = pending.popLast() {
            guard let node = branch.node else { continue }
            volumes.append(branch)
            if let value = node.value, value.node != nil { volumes.append(value) }
            pending.append(contentsOf: node.children.values)
        }
        return volumes
    }
}
