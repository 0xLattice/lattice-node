import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

struct IssuedChildEvidence: Sendable {
    let edgeCID: String
    let attachmentCID: String
    let edge: DirectChildEdge
    let proof: ChildBlockProof
}

/// Evidence verified by Lattice that the node must commit with the admission
/// batch that made it issuable. The proof package is optional for Nexus, where
/// the carrier is its own root.
struct ImportCarrierEvidence: Sendable {
    let proof: ChildBlockProof
    let childCID: String
    /// The proof contributes work to the child (Lattice's
    /// `verifySecuringWork` returned a contribution): only such proofs
    /// enter the child-evidence index.
    let weighs: Bool

    init(
        proof: ChildBlockProof,
        childCID: String,
        weighs: Bool = false
    ) {
        self.proof = proof
        self.childCID = childCID
        self.weighs = weighs
    }
}

/// Hierarchy facts produced by Lattice at the same boundary as an accepted
/// admission. They remain separate from chain facts because replay does not
/// need them, but NodeStore commits both in one SQLite transaction.
struct ImportHierarchyArtifacts: Sendable {
    /// The admitted block that issues these facts.
    let blockCID: String
    let carrierEvidence: ImportCarrierEvidence?
}

struct PreparedImportCarrierEvidence {
    let edge: DirectChildEdge
    let rootCID: String
    let proofAttachment: ChildEvidenceVolume
    let weighs: Bool
}

/// `child_evidence_root`: the root of this chain's child-evidence index.
struct ChildEvidenceRootRow: NodeStoreRecord {
    static let table = "child_evidence_root"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var rootCID: String { get throws { try row.text("root_cid") } }
}

/// `child_evidence_pins_dirty`: present while an index update's pins may
/// be out of step with the committed root.
struct ChildEvidencePinsDirtyRow: NodeStoreRecord {
    static let table = "child_evidence_pins_dirty"
    private let row: Row

    init(_ row: Row) { self.row = row }
}

struct PreparedImportHierarchyArtifacts {
    let blockCID: String
    let carrierEvidence: PreparedImportCarrierEvidence?
}

enum IssuedChildProofScope: String, Sendable {
    case incomingCarrier = "incoming_carrier"
}

/// `issued_child_edges`: one content-derived direct-child edge. Every CID
/// column is canonical by construction (`DirectChildEdge.validated()`).
struct IssuedChildEdgeRow: NodeStoreRecord {
    static let table = "issued_child_edges"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var edgeCID: String { get throws { try row.cid("edge_cid") } }
    var parentCarrierCID: String { get throws { try row.cid("parent_carrier_cid") } }
    var directory: String { get throws { try row.text("directory") } }
    var childCID: String { get throws { try row.cid("child_cid") } }
}

/// `issued_child_proofs`: one attachment proving an edge under one root.
struct IssuedChildProofRow: NodeStoreRecord {
    static let table = "issued_child_proofs"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var scope: IssuedChildProofScope {
        get throws {
            guard let scope = IssuedChildProofScope(rawValue: try row.text("scope")) else {
                throw NodeStoreError.malformedRow(table: Self.table, column: "scope")
            }
            return scope
        }
    }
    var rootCID: String { get throws { try row.cid("root_cid") } }
    var attachmentCID: String { get throws { try row.cid("attachment_cid") } }
    /// The edge the boot audit LEFT JOINs onto the proof (projected as
    /// `edge_cid`): nil when the proof has no edge.
    var joinedEdgeCID: String? { get throws { try row.optionalText("edge_cid") } }
}

/// `issued_child_proofs AS p INNER JOIN issued_child_edges AS e` (see
/// `NodeStore.proofEdgeJoinSQL`): the proof's columns and its edge's, as
/// each statement projects them.
struct ProofEdgeJoinRow: NodeStoreRecord {
    static let table = "issued_child_proofs⋈issued_child_edges"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var edgeCID: String { get throws { try row.cid("edge_cid") } }
    var rootCID: String { get throws { try row.cid("root_cid") } }
    var attachmentCID: String { get throws { try row.cid("attachment_cid") } }
    var childCID: String { get throws { try row.cid("child_cid") } }
    var directory: String { get throws { try row.text("directory") } }
    var parentCarrierCID: String { get throws { try row.cid("parent_carrier_cid") } }
}

extension NodeStore {
    /// The join every evidence read shares: `p` is `issued_child_proofs`,
    /// `e` its `issued_child_edges` row. Rows read through it are
    /// `ProofEdgeJoinRow`s.
    static let proofEdgeJoinSQL =
        "FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid"

    func incomingParentCarrierBlockCIDs(
        forChildBlockCID childBlockCID: String
    ) throws -> Set<String> {
        guard CIDIdentity.isCanonical(childBlockCID) else {
            throw NodeStoreError.corrupt("invalid incoming child block")
        }
        let rows = try database.rows(
            IssuedChildEdgeRow.self,
            "SELECT edge.parent_carrier_cid FROM issued_child_edges AS edge WHERE edge.child_cid = ?1 AND EXISTS (SELECT 1 FROM issued_child_proofs AS proof WHERE proof.scope = ?2 AND proof.edge_cid = edge.edge_cid) ORDER BY edge.parent_carrier_cid",
            params: [
                .text(childBlockCID),
                .text(IssuedChildProofScope.incomingCarrier.rawValue),
            ]
        )
        return Set(try rows.map { try $0.parentCarrierCID })
    }

    func prepareHierarchyArtifacts(
        _ artifacts: ImportHierarchyArtifacts?,
        carrierCIDs: Set<String>
    ) async throws -> PreparedImportHierarchyArtifacts? {
        guard let artifacts else { return nil }
        let blockCID = artifacts.blockCID
        guard !blockCID.isEmpty, carrierCIDs.contains(blockCID) else {
            throw NodeStoreError.invalidConfiguration(
                "issued hierarchy artifacts are outside their admission batch"
            )
        }
        // Nexus is its own root: its blocks never carry parent evidence.
        if chainPath.count == 1, artifacts.carrierEvidence != nil {
            throw NodeStoreError.invalidConfiguration(
                "Nexus blocks carry no parent evidence"
            )
        }

        let carrierEvidence: PreparedImportCarrierEvidence?
        if let evidence = artifacts.carrierEvidence {
            carrierEvidence = try await prepareCarrierEvidence(
                evidence,
                expectedChildCIDs: Set([blockCID]),
                expectedRootCID: nil
            )
        } else {
            carrierEvidence = nil
        }

        return PreparedImportHierarchyArtifacts(
            blockCID: blockCID,
            carrierEvidence: carrierEvidence
        )
    }

    func prepareCarrierEvidence(
        _ evidence: ImportCarrierEvidence,
        expectedChildCIDs: Set<String>,
        expectedRootCID: String?
    ) async throws -> PreparedImportCarrierEvidence {
        let childCID = evidence.childCID
        guard expectedChildCIDs.contains(childCID),
              expectedRootCID.map({ $0 == evidence.proof.rootCID }) ?? true,
              let edge = await DirectChildEdge.derive(from: evidence.proof),
              edge.childCID == childCID,
              let directory = evidence.proof.directoryPath.last,
              edge.directory == directory else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        guard edge.edgeCID != nil else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let portableEnvelopePayload = try ChildValidationPackageEnvelope(
            proof: evidence.proof
        ).encode()
        let proofAttachment = try ChildEvidenceVolume(
            envelopeBytes: portableEnvelopePayload,
            childCID: childCID
        )
        return PreparedImportCarrierEvidence(
            edge: edge,
            rootCID: evidence.proof.rootCID,
            proofAttachment: proofAttachment,
            weighs: evidence.weighs
        )
    }

    /// Pin owner of the child-evidence index's current Volumes.
    var childEvidenceOwner: String { blockRetentionScope + ":child-evidence" }

    /// The root of this chain's child-evidence index; nil while it is empty.
    func childEvidenceRoot() throws -> String? {
        let rows = try database.rows(
            ChildEvidenceRootRow.self,
            "SELECT root_cid FROM child_evidence_root WHERE singleton = 1"
        )
        guard let row = rows.first else { return nil }
        let root = try row.rootCID
        guard CIDIdentity.isCanonical(root) else {
            throw NodeStoreError.corrupt("malformed child-evidence root")
        }
        return root
    }

    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts — broker writes, outside any database transaction.
    /// Stores and pins the index Volumes that inserting the weighing
    /// `evidence` changes. The caller commits the returned root with the
    /// evidence rows (`persistChildEvidenceRoot`), then releases the
    /// replaced Volumes (`finishChildEvidenceIndex`), or drops the new pins
    /// if the commit fails (`abandonChildEvidenceIndex`).
    func prepareChildEvidenceIndex(
        _ evidence: [PreparedImportCarrierEvidence]
    ) async throws -> ChildEvidenceIndex.Update? {
        try await prepareChildEvidenceIndex(entries: evidence.filter(\.weighs).map {
            ChildEvidenceIndex.Entry(
                childCID: $0.edge.childCID,
                rootCID: $0.rootCID,
                attachmentCID: $0.proofAttachment.rawCID
            )
        })
    }

    func prepareChildEvidenceIndex(
        entries: [ChildEvidenceIndex.Entry]
    ) async throws -> ChildEvidenceIndex.Update? {
        guard !entries.isEmpty, var update = try await ChildEvidenceIndex.inserting(
            entries,
            into: try childEvidenceRoot(),
            fetcher: recoveryVolumeBroker,
            storer: recoveryVolumeBroker
        ) else { return nil }
        // Set until the replaced pins are released: a crash in between, or
        // a pin or unpin that throws, leaves the pins to boot's reconcile.
        // Only the update that found it clear may clear it.
        update.markerWasSet = try childEvidencePinsDirty()
        try setChildEvidencePinsDirty(true)
        if !update.added.isEmpty {
            try await recoveryVolumeBroker.retain(update.added,
                owner: childEvidenceOwner
            )
        }
        return update
    }

    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts — caller holds the transaction.
    func persistChildEvidenceRoot(_ update: ChildEvidenceIndex.Update) throws {
        // Admissions are serial, so the root cannot move between prepare and
        // commit; if it did, committing would drop the other admission's
        // entries.
        guard try childEvidenceRoot() == update.baseRoot else {
            throw NodeStoreError.corrupt("child-evidence root moved under an admission")
        }
        try database.execute(
            "INSERT INTO child_evidence_root (singleton, root_cid) VALUES (1, ?1) ON CONFLICT(singleton) DO UPDATE SET root_cid = excluded.root_cid",
            params: [.text(update.root)]
        )
    }

    /// After the commit: the replaced Volumes lose their pin and are
    /// reclaimed by ordinary eviction. A peer still walking the old root
    /// finds them unavailable and re-reads the current root. A pin this
    /// fails to drop is healed at boot (`BootRecovery`).
    func finishChildEvidenceIndex(_ update: ChildEvidenceIndex.Update?) async {
        guard let update else { return }
        await releaseChildEvidencePins(update.released, markerWasSet: update.markerWasSet)
    }

    /// The commit failed: the new Volumes lose the pin `prepare` gave them.
    func abandonChildEvidenceIndex(_ update: ChildEvidenceIndex.Update?) async {
        guard let update else { return }
        await releaseChildEvidencePins(update.added, markerWasSet: update.markerWasSet)
    }

    /// Unpins `roots`, then clears the dirty marker if this update set it.
    /// On a failure, or a marker an earlier update left set, it stays set
    /// and boot reconciles the pins.
    private func releaseChildEvidencePins(_ roots: [String], markerWasSet: Bool) async {
        do {
            if !roots.isEmpty {
                try await recoveryVolumeBroker.release(Set(roots), owner: childEvidenceOwner)
            }
            if !markerWasSet { try setChildEvidencePinsDirty(false) }
        } catch {}
    }

    /// Whether an index update may have left the child-evidence pins out of
    /// step with the committed root (a crash between pin and release).
    func childEvidencePinsDirty() throws -> Bool {
        !(try database.rows(
            ChildEvidencePinsDirtyRow.self,
            "SELECT singleton FROM child_evidence_pins_dirty"
        )).isEmpty
    }

    func setChildEvidencePinsDirty(_ dirty: Bool) throws {
        try database.execute(dirty
            ? "INSERT OR IGNORE INTO child_evidence_pins_dirty (singleton) VALUES (1)"
            : "DELETE FROM child_evidence_pins_dirty")
    }

    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts — caller holds the transaction.
    func persistHierarchyArtifacts(
        _ artifacts: PreparedImportHierarchyArtifacts
    ) throws {
        if let evidence = artifacts.carrierEvidence {
            try persistCarrierEvidence(evidence)
        }
    }

    /// Owner: ImportJournal.stage / EvidenceIndex.persistHierarchyArtifacts — caller holds the transaction.
    func persistCarrierEvidence(
        _ evidence: PreparedImportCarrierEvidence
    ) throws {
        guard let edgeCID = evidence.edge.edgeCID else {
            throw NodeStoreError.invalidIssuedChildProof(evidence.edge.childCID)
        }
        try persistIssuedChildEdgeRow(evidence.edge)
        try persistIssuedChildProofRow(
            scope: .incomingCarrier,
            edgeCID: edgeCID,
            rootCID: evidence.rootCID,
            attachmentCID: evidence.proofAttachment.rawCID
        )
    }

    func persistIssuedHierarchyArtifacts(
        _ artifacts: ImportHierarchyArtifacts
    ) async throws {
        let blockCID = artifacts.blockCID
        guard let prepared = try await prepareHierarchyArtifacts(
            artifacts,
            carrierCIDs: [blockCID]
        ) else {
            throw NodeStoreError.corrupt("missing issued hierarchy artifacts")
        }
        let recoveryRoots = try await storeRecoveryEvidence(
            [prepared.carrierEvidence].compactMap { $0 }
        )
        try await mergeRecoveryPruningProtection(
            scope: issuedRecoveryRetentionScope,
            roots: recoveryRoots
        )
        let indexUpdate = try await prepareChildEvidenceIndex(
            [prepared.carrierEvidence].compactMap { $0 }
        )
        do {
            try database.transaction {
                try persistHierarchyArtifacts(prepared)
                if let indexUpdate {
                    try persistChildEvidenceRoot(indexUpdate)
                }
            }
        } catch {
            await abandonChildEvidenceIndex(indexUpdate)
            throw error
        }
        await finishChildEvidenceIndex(indexUpdate)
    }

    private func persistIssuedChildEdgeRow(_ edge: DirectChildEdge) throws {
        guard let edgeCID = edge.edgeCID else {
            throw NodeStoreError.invalidIssuedChildProof(edge.childCID)
        }
        let byIdentity = try database.row(
            IssuedChildEdgeRow.self,
            "SELECT parent_carrier_cid, directory, child_cid FROM issued_child_edges WHERE edge_cid = ?1",
            params: [.text(edgeCID)]
        )
        let byTuple = try database.rows(
            IssuedChildEdgeRow.self,
            "SELECT edge_cid FROM issued_child_edges WHERE parent_carrier_cid = ?1 AND directory = ?2 AND child_cid = ?3",
            params: [
                .text(edge.parentCarrierCID), .text(edge.directory),
                .text(edge.childCID),
            ]
        )
        if let row = byIdentity {
            guard try row.parentCarrierCID == edge.parentCarrierCID,
                  try row.directory == edge.directory,
                  try row.childCID == edge.childCID,
                  try byTuple.first?.edgeCID == edgeCID else {
                throw NodeStoreError.conflictingIssuedChildProof
            }
            return
        }
        guard byTuple.isEmpty else {
            throw NodeStoreError.conflictingIssuedChildProof
        }
        try database.execute(
            "INSERT INTO issued_child_edges (edge_cid, parent_carrier_cid, directory, child_cid) VALUES (?1, ?2, ?3, ?4)",
            params: [
                .text(edgeCID), .text(edge.parentCarrierCID),
                .text(edge.directory), .text(edge.childCID),
            ]
        )
    }

    private func persistIssuedChildProofRow(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String,
        attachmentCID: String
    ) throws {
        let existing = try database.row(
            IssuedChildProofRow.self,
            "SELECT attachment_cid FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 AND root_cid = ?3",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
            ]
        )
        if let row = existing {
            guard try row.attachmentCID == attachmentCID else {
                throw NodeStoreError.conflictingIssuedChildProof
            }
            return
        }
        try database.execute(
            "INSERT INTO issued_child_proofs (scope, edge_cid, root_cid, attachment_cid) VALUES (?1, ?2, ?3, ?4)",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
                .text(attachmentCID),
            ]
        )
    }

    func incomingCarrierEvidence(
        childCID: String,
        directory: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        try await issuedChildEvidence(
            scope: .incomingCarrier,
            childCID: childCID,
            directory: directory,
            rootCID: rootCID
        )
    }

    /// The committing parent blocks of the blocks this chain ACCEPTED with a
    /// carrier proof, distinct, newest first (Lattice §9.10). Durable, so it
    /// is the answer to "whose runs does this chain re-read from its parent
    /// level" after a restart. Joined on `accepted_blocks`: only an accepted
    /// block's carrier evidence is recorded, and the join keeps that explicit.
    func incomingCarriers(limit: Int) throws -> [String] {
        let rows = try database.rows(
            ProofEdgeJoinRow.self,
            "SELECT e.parent_carrier_cid \(Self.proofEdgeJoinSQL) INNER JOIN accepted_blocks AS a ON a.block_cid = e.child_cid WHERE p.scope = ?1 GROUP BY e.parent_carrier_cid ORDER BY MAX(p.rowid) DESC LIMIT ?2",
            params: [.text(IssuedChildProofScope.incomingCarrier.rawValue), .int(Int64(limit))]
        )
        return try rows.map { try $0.parentCarrierCID }
    }

    /// The ACCEPTED block of this chain that `committer` commits, from the
    /// carrier proof verified at that block's admission — the edge was derived
    /// from the sparse proof, never taken from the wire — or nil for a
    /// committer of nothing this chain accepted.
    func incomingCarrierChildBlock(carrier: String) throws -> String? {
        try database.row(
            ProofEdgeJoinRow.self,
            "SELECT e.child_cid \(Self.proofEdgeJoinSQL) INNER JOIN accepted_blocks AS a ON a.block_cid = e.child_cid WHERE p.scope = ?1 AND e.parent_carrier_cid = ?2 LIMIT 1",
            params: [.text(IssuedChildProofScope.incomingCarrier.rawValue), .text(carrier)]
        )?.childCID
    }

    private func issuedChildEvidence(
        scope: IssuedChildProofScope,
        childCID: String,
        directory: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        guard !directory.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "child-proof directory must be nonempty"
            )
        }
        let rows: [ProofEdgeJoinRow]
        if let rootCID {
            rows = try database.rows(
                ProofEdgeJoinRow.self,
                "SELECT p.edge_cid, p.root_cid, p.attachment_cid, e.parent_carrier_cid, e.directory, e.child_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 AND p.root_cid = ?4 LIMIT 1",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                    .text(rootCID),
                ]
            )
        } else {
            rows = try database.rows(
                ProofEdgeJoinRow.self,
                "SELECT p.edge_cid, p.root_cid, p.attachment_cid, e.parent_carrier_cid, e.directory, e.child_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 ORDER BY p.root_cid, p.edge_cid LIMIT 1",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                ]
            )
        }
        guard let row = rows.first else { return nil }
        let edgeCID = try row.edgeCID
        let directory = try row.directory
        let storedRoot = try row.rootCID
        let attachmentCID = try row.attachmentCID
        let parentCarrierCID = try row.parentCarrierCID
        let attachment = try await recoveryVolume(
            attachmentCID: attachmentCID,
            childCID: childCID
        )
        let envelope: ChildValidationPackageEnvelope
        do {
            envelope = try ChildValidationPackageEnvelope.decode(
                attachment.envelopeBytes
            )
        } catch {
            throw NodeStoreError.corrupt("malformed child evidence attachment")
        }
        guard let proof = ChildBlockProof.deserialize(envelope.proofBytes),
              (try? proof.serialize()) == envelope.proofBytes,
              proof.directoryPath.last == directory,
              proof.rootCID == storedRoot,
              try await Self.proves(
                  proof,
                  childCID: childCID,
                  from: chainPath
              ),
              let edge = await DirectChildEdge.derive(from: proof),
              edge.edgeCID == edgeCID,
              edge.parentCarrierCID == parentCarrierCID,
              edge.childCID == childCID,
              edge.directory == directory else {
            throw NodeStoreError.corrupt("malformed locally issued child proof")
        }
        return IssuedChildEvidence(
            edgeCID: edgeCID,
            attachmentCID: attachmentCID,
            edge: edge,
            proof: proof
        )
    }

    func incomingCarrierProofRoots(
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        try await issuedChildProofRoots(
            scope: .incomingCarrier,
            childCID: childCID,
            directory: directory,
            afterRootCID: afterRootCID,
            limit: limit
        )
    }

    private func issuedChildProofRoots(
        scope: IssuedChildProofScope,
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        guard !directory.isEmpty, limit > 0,
              let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "child-proof page limit must be positive"
            )
        }
        let rows: [ProofEdgeJoinRow]
        if let afterRootCID {
            rows = try database.rows(
                ProofEdgeJoinRow.self,
                "SELECT DISTINCT p.root_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 AND p.root_cid > ?4 ORDER BY p.root_cid LIMIT ?5",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                    .text(afterRootCID), .int(sqlLimit),
                ]
            )
        } else {
            rows = try database.rows(
                ProofEdgeJoinRow.self,
                "SELECT DISTINCT p.root_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 ORDER BY p.root_cid LIMIT ?4",
                params: [
                    .text(scope.rawValue), .text(childCID), .text(directory),
                    .int(sqlLimit),
                ]
            )
        }
        return try rows.map { try $0.rootCID }
    }

    /// Checks only the content-addressed root-to-leaf association and path
    /// scope. Consensus work and transition validity remain Lattice's job.
    static func proves(
        _ proof: ChildBlockProof,
        childCID: String,
        from chainPath: [String]
    ) async throws -> Bool {
        let localPath = Array(chainPath.dropFirst())
        let provesSelf = !localPath.isEmpty && proof.directoryPath == localPath
        let provesDirectChild = proof.directoryPath.count == localPath.count + 1
            && proof.directoryPath.starts(with: localPath)
        guard !proof.rootCID.isEmpty,
              provesSelf || provesDirectChild,
              proof.directoryPath.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        return await proof.directHop()?.childCID == childCID
    }

    func auditIssuedChildAttachments() async throws {
        // Startup-bounded attachment audit: shape, edge linkage, and LOCAL
        // COMPLETENESS of every attachment Volume (the broker's SQL
        // completeness predicate) — but never materialization. The issued
        // index grows with every proof issued over the chain's whole life, so
        // fetching and decoding each attachment here made process startup
        // O(history x volume-decode) and wedged long-lived nodes for hours;
        // the full decode-and-bind validation still runs fail-closed at every
        // actual use (`recoveryVolume`).
        let attachments = try database.rows(
            IssuedChildProofRow.self,
            """
            SELECT p.scope, p.root_cid, p.attachment_cid, e.edge_cid
            FROM issued_child_proofs AS p
            LEFT JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid
            ORDER BY p.scope, p.edge_cid, p.root_cid
            """
        )
        for row in attachments {
            _ = try row.scope
            _ = try row.rootCID
            let attachmentCID = try row.attachmentCID
            guard try row.joinedEdgeCID != nil,
                  await recoveryVolumeBroker.hasVolume(root: attachmentCID)
            else {
                throw NodeStoreError.corrupt(
                    "malformed direct-child attachment index"
                )
            }
        }
        let edgeCount = try database.row(
            from: IssuedChildEdgeRow.table,
            "SELECT COUNT(*) AS count FROM issued_child_edges"
        )?.int("count")
        let attachedEdgeCount = try database.row(
            from: IssuedChildProofRow.table,
            "SELECT COUNT(DISTINCT edge_cid) AS count FROM issued_child_proofs"
        )?.int("count")
        guard edgeCount == attachedEdgeCount else {
            throw NodeStoreError.corrupt("orphaned direct-child content")
        }
    }
}
