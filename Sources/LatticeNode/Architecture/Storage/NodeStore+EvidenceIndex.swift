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

    init(
        proof: ChildBlockProof,
        childCID: String
    ) {
        self.proof = proof
        self.childCID = childCID
    }
}

/// Hierarchy facts produced by Lattice at the same boundary as an accepted
/// admission. They remain separate from chain facts because replay does not
/// need them, but NodeStore commits both in one SQLite transaction.
struct ImportHierarchyArtifacts: Sendable {
    let carrierLink: ParentCarrierLink
    let carrierEvidence: ImportCarrierEvidence?
    let parentGenesisLinks: [ParentGenesisLink]
}

struct IssuedChildEvidenceSummary: Codable, Equatable, Hashable, Sendable {
    let ordinal: UInt64
    let childCID: String
    let rootCID: String
    let attachmentCID: String
}

struct ParentEvidenceScanCursor: Equatable, Sendable {
    let sourceID: String?
    let ordinal: UInt64
}

struct ParentEvidenceInboxItem: Sendable {
    let sourceID: String
    let ordinal: UInt64
    let attachment: ChildEvidenceVolume
    let package: AuthenticatedChildPackage
}

struct ChildRootAttachmentSummary: Equatable, Hashable, Sendable {
    let edgeCID: String
    let rootCID: String
    let attachmentCID: String
}

struct PreparedImportCarrierEvidence {
    let edge: DirectChildEdge
    let rootCID: String
    let proofAttachment: ChildEvidenceVolume
}

struct PreparedImportHierarchyArtifacts {
    let carrierLink: ParentCarrierLink
    let carrierLinkPayload: Data
    let carrierEvidence: PreparedImportCarrierEvidence?
    let parentGenesisLinks: [(link: ParentGenesisLink, payload: Data)]
}

private struct PersistedParentFactSource: Codable {
    let carrierLink: ParentCarrierLink
    let parentGenesisLinks: [ParentGenesisLink]
}

private struct IssuedParentFactKey: Hashable {
    let kind: String
    let keyA: String
    let keyB: String
}

enum IssuedChildProofScope: String, Sendable {
    case incomingCarrier = "incoming_carrier"
    case outgoingDirectChild = "outgoing_direct_child"
}

/// `issued_parent_fact_sources`: the JSON source each issued parent fact
/// derives from; decoded by the audit so a decode failure stays `corrupt`.
struct IssuedParentFactSourceRow: NodeStoreRecord {
    static let table = "issued_parent_fact_sources"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var payload: Data { get throws { try row.blob("payload") } }
}

/// `issued_parent_facts`: one locally issued carrier or genesis fact. The
/// keys are opaque text (a genesis key is a length-prefixed composite).
struct IssuedParentFactRow: NodeStoreRecord {
    static let table = "issued_parent_facts"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var kind: String { get throws { try row.text("kind") } }
    var keyA: String { get throws { try row.text("key_a") } }
    var keyB: String { get throws { try row.text("key_b") } }
    var payload: Data { get throws { try row.blob("payload") } }
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
    var ordinal: UInt64? { get throws { try issuedChildProofOrdinal(row) } }
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
    var ordinal: UInt64? { get throws { try issuedChildProofOrdinal(row) } }
    var childCID: String { get throws { try row.cid("child_cid") } }
    var directory: String { get throws { try row.text("directory") } }
    var parentCarrierCID: String { get throws { try row.cid("parent_carrier_cid") } }
}

/// `issued_child_proofs.ordinal`: NULL for an incoming-carrier proof, a
/// positive integer for an outgoing one (the table's CHECK).
private func issuedChildProofOrdinal(_ row: Row) throws -> UInt64? {
    guard let raw = try row.optionalInt("ordinal") else { return nil }
    guard let ordinal = UInt64(exactly: raw), ordinal > 0 else {
        throw NodeStoreError.malformedRow(table: row.table, column: "ordinal")
    }
    return ordinal
}

/// `parent_evidence_scan`: the singleton cursor over the parent's issued
/// evidence; `source_id` is NULL until the first scan.
struct ParentEvidenceScanRow: NodeStoreRecord {
    static let table = "parent_evidence_scan"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var sourceID: String? {
        get throws {
            guard let sourceID = try row.optionalText("source_id") else { return nil }
            guard UUID(uuidString: sourceID) != nil else {
                throw NodeStoreError.malformedRow(table: Self.table, column: "source_id")
            }
            return sourceID
        }
    }
    var ordinal: UInt64 { get throws { try row.uint64("ordinal") } }
}

/// `parent_evidence_inbox`: one relayed parent-evidence entry awaiting an
/// admission decision. `child_cid` and `root_cid` are only ever compared
/// against the attachment's proof, so they stay plain text.
struct ParentEvidenceInboxRow: NodeStoreRecord {
    static let table = "parent_evidence_inbox"
    private let row: Row

    init(_ row: Row) { self.row = row }

    var sourceID: String { get throws { try row.uuid("source_id") } }
    var ordinal: UInt64 {
        get throws {
            let ordinal = try row.uint64("ordinal")
            guard ordinal > 0 else {
                throw NodeStoreError.malformedRow(table: Self.table, column: "ordinal")
            }
            return ordinal
        }
    }
    var childCID: String { get throws { try row.text("child_cid") } }
    var rootCID: String { get throws { try row.text("root_cid") } }
    var attachmentCID: String { get throws { try row.cid("attachment_cid") } }
}

extension NodeStore {
    /// The join every evidence read shares: `p` is `issued_child_proofs`,
    /// `e` its `issued_child_edges` row. Rows read through it are
    /// `ProofEdgeJoinRow`s.
    static let proofEdgeJoinSQL =
        "FROM issued_child_proofs AS p INNER JOIN issued_child_edges AS e ON e.edge_cid = p.edge_cid"

    private static func parentGenesisFactKey(
        _ link: ParentGenesisLink
    ) -> String {
        parentGenesisFactKey(
            childGenesisCID: link.childGenesisCID,
            parentStateCID: link.parentStateCID
        )
    }

    private static func parentGenesisFactKey(
        childGenesisCID: String,
        parentStateCID: String
    ) -> String {
        "\(parentStateCID.utf8.count):\(parentStateCID)\(childGenesisCID)"
    }

    /// Durable child-to-parent carrier links used only by this child when it
    /// projects its configured parent's generic securing-work graph.
    func incomingParentCarrierBlocksByChildBlock()
        throws -> [String: Set<String>]
    {
        let rows = try database.rows(
            ProofEdgeJoinRow.self,
            "SELECT DISTINCT e.child_cid, e.parent_carrier_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 ORDER BY e.child_cid, e.parent_carrier_cid",
            params: [.text(IssuedChildProofScope.incomingCarrier.rawValue)]
        )
        var result: [String: Set<String>] = [:]
        for row in rows {
            result[try row.childCID, default: []].insert(try row.parentCarrierCID)
        }
        return result
    }

    /// Resolve only bindings touched by a live parent-work delta. Full graph
    /// materialization remains a restart/reconnect operation.
    func incomingParentCarrierBlocksByChildBlock(
        matching parentBlockCIDs: Set<String>
    ) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for parentBlockCID in parentBlockCIDs.sorted() {
            let rows = try database.rows(
                ProofEdgeJoinRow.self,
                "SELECT DISTINCT e.child_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.parent_carrier_cid = ?2 ORDER BY e.child_cid",
                params: [
                    .text(IssuedChildProofScope.incomingCarrier.rawValue),
                    .text(parentBlockCID),
                ]
            )
            for row in rows {
                result[try row.childCID, default: []].insert(parentBlockCID)
            }
        }
        return result
    }

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
        let link = artifacts.carrierLink
        guard !link.carrierCID.isEmpty,
              !link.rootCID.isEmpty,
              link.parentPath == chainPath,
              carrierCIDs.contains(link.carrierCID) else {
            throw NodeStoreError.invalidConfiguration(
                "issued hierarchy artifacts are outside their admission batch"
            )
        }
        if link.rootCID == link.carrierCID {
            // A self-rooted carrier is a self-contained genesis (the Nexus root
            // OR a self-mined child genesis): it satisfies its own PoW and is
            // authorized by the parent's recorded GenesisAction, never by a
            // carrier proof. It must therefore carry no evidence.
            if artifacts.carrierEvidence != nil {
                throw NodeStoreError.invalidConfiguration(
                    "a self-rooted carrier must not carry parent evidence"
                )
            }
        } else if chainPath.count == 1 {
            throw NodeStoreError.invalidConfiguration(
                "Nexus carrier evidence must be rooted at its carrier"
            )
        } else if artifacts.carrierEvidence == nil {
            throw NodeStoreError.invalidConfiguration(
                "child carrier evidence requires its authenticated parent proof"
            )
        }

        let parentGenesisLinks = try prepareParentGenesisLinks(
            artifacts.parentGenesisLinks
        )

        let carrierEvidence: PreparedImportCarrierEvidence?
        if let evidence = artifacts.carrierEvidence {
            carrierEvidence = try await prepareCarrierEvidence(
                evidence,
                expectedChildCIDs: Set([link.carrierCID]),
                expectedRootCID: link.rootCID
            )
        } else {
            carrierEvidence = nil
        }

        return PreparedImportHierarchyArtifacts(
            carrierLink: link,
            carrierLinkPayload: try Self.encode(link),
            carrierEvidence: carrierEvidence,
            parentGenesisLinks: parentGenesisLinks
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
            proofAttachment: proofAttachment
        )
    }

    private func prepareParentGenesisLinks(
        _ links: [ParentGenesisLink]
    ) throws -> [(link: ParentGenesisLink, payload: Data)] {
        let links = Array(Set(links)).sorted {
            ($0.directory, $0.childGenesisCID, $0.parentStateCID)
                < ($1.directory, $1.childGenesisCID, $1.parentStateCID)
        }
        guard links.allSatisfy({ link in
            link.parentPath == chainPath
                && !link.directory.isEmpty
                && !link.childGenesisCID.isEmpty
                && !link.parentStateCID.isEmpty
        }) else {
            throw NodeStoreError.invalidConfiguration(
                "issued genesis link belongs to a different chain path"
            )
        }
        return try links.map { (link: $0, payload: try Self.encode($0)) }
    }

    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts — caller holds the transaction.
    func persistHierarchyArtifacts(
        _ artifacts: PreparedImportHierarchyArtifacts
    ) throws {
        if let evidence = artifacts.carrierEvidence {
            try persistCarrierEvidence(evidence)
        }
        try persistParentFacts(
            link: artifacts.carrierLink,
            payload: artifacts.carrierLinkPayload,
            parentGenesisLinks: artifacts.parentGenesisLinks
        )
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

    private func persistParentFacts(
        link: ParentCarrierLink,
        payload: Data,
        parentGenesisLinks: [(link: ParentGenesisLink, payload: Data)]
    ) throws {
        let source = PersistedParentFactSource(
            carrierLink: link,
            parentGenesisLinks: parentGenesisLinks.map(\.link)
        )
        try database.execute(
            "INSERT OR IGNORE INTO issued_parent_fact_sources (payload) VALUES (?1)",
            params: [.blob(try Self.encode(source))]
        )
        try persistIssuedParentFact(
            kind: "carrier",
            keyA: link.carrierCID,
            keyB: link.rootCID,
            payload: payload
        )
        for genesis in parentGenesisLinks {
            try persistIssuedParentFact(
                kind: "genesis",
                keyA: genesis.link.directory,
                keyB: Self.parentGenesisFactKey(genesis.link),
                payload: genesis.payload
            )
        }
    }

    func persistIssuedHierarchyArtifacts(
        _ artifacts: ImportHierarchyArtifacts,
        pendingChildProofRoutes: [PendingChildProofRoute] = [],
        pendingChildProofCapacity: Int = 16
    ) async throws {
        let link = artifacts.carrierLink
        if !artifacts.parentGenesisLinks.isEmpty,
           try !hasConnectedAcceptedBlock(link.carrierCID) {
            throw NodeStoreError.invalidConfiguration(
                "genesis authority requires a connected parent block"
            )
        }
        guard pendingChildProofRoutes.allSatisfy({
            $0.carrierCID == link.carrierCID && !$0.directory.isEmpty
        }) else {
            throw NodeStoreError.invalidConfiguration(
                "pending child-proof route belongs to another carrier"
            )
        }
        guard let prepared = try await prepareHierarchyArtifacts(
            artifacts,
            carrierCIDs: [link.carrierCID]
        ) else {
            throw NodeStoreError.corrupt("missing issued hierarchy artifacts")
        }
        let recoveryRoots = try await storeRecoveryEvidence(
            [prepared.carrierEvidence].compactMap { $0 }
        )
        try await mergeRecoveryRetention(
            scope: issuedRecoveryRetentionScope,
            roots: recoveryRoots
        )
        try database.transaction {
            try persistHierarchyArtifacts(prepared)
            if let attachmentCID = prepared.carrierEvidence?
                .proofAttachment.rawCID
            {
                try deleteParentEvidenceInbox(attachmentCID: attachmentCID)
            }
            try persistPendingChildProofRouteRows(
                try pendingRoutesIncludingPreparedProofs(
                    pendingChildProofRoutes,
                    carrierCIDs: [link.carrierCID]
                ),
                capacity: pendingChildProofCapacity
            )
        }
        if prepared.carrierEvidence != nil {
            await reconcileParentEvidenceInboxRetention()
        }
    }

    func issuedParentCarrierLink(
        carrierCID: String,
        rootCID: String
    ) async throws -> ParentCarrierLink? {
        guard let payload = try issuedParentFact(
            kind: "carrier",
            keyA: carrierCID,
            keyB: rootCID
        ) else { return nil }
        let link = try Self.decode(ParentCarrierLink.self, from: payload)
        guard link.parentPath == chainPath,
              link.carrierCID == carrierCID,
              link.rootCID == rootCID else {
            throw NodeStoreError.corrupt("malformed locally issued carrier link")
        }
        return link
    }

    func issuedParentGenesisLink(
        directory: String,
        childGenesisCID: String,
        parentStateCID: String
    ) async throws -> ParentGenesisLink? {
        guard let payload = try issuedParentFact(
            kind: "genesis",
            keyA: directory,
            keyB: Self.parentGenesisFactKey(
                childGenesisCID: childGenesisCID,
                parentStateCID: parentStateCID
            )
        ) else { return nil }
        let link = try Self.decode(ParentGenesisLink.self, from: payload)
        guard link.parentPath == chainPath,
              link.directory == directory,
              link.childGenesisCID == childGenesisCID,
              link.parentStateCID == parentStateCID else {
            throw NodeStoreError.corrupt("malformed locally issued genesis link")
        }
        return link
    }

    /// Persists content-authenticated proof material used to serve a direct
    /// child. Different Nexus roots and directories for the same child are
    /// distinct valid evidence, so the cache is set-valued by
    /// `(childCID, directory, rootCID)`.
    func persistIssuedChildProof(
        _ proof: ChildBlockProof,
        childCID: String,
        isChildGenesis: Bool,
        bootstrapRoots: [String],
        parentCarrierCID: String? = nil,
        rootEnvelope: ChildValidationPackageEnvelope
    ) async throws {
        guard let directory = proof.directoryPath.last,
              isChildGenesis || bootstrapRoots.isEmpty,
              bootstrapRoots.isEmpty || bootstrapRoots.contains(childCID) else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        guard let edge = await DirectChildEdge.derive(from: proof),
              edge.childCID == childCID,
              edge.directory == directory,
              proof.directoryPath
                == Array(chainPath.dropFirst()) + [directory],
              parentCarrierCID.map({ $0 == edge.parentCarrierCID }) ?? true else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        _ = try await validatedProofPayload(
            proof,
            childCID: childCID
        )
        guard let edgeCID = edge.edgeCID else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        guard rootEnvelope.proofBytes == (try? proof.serialize()) else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let proofAttachment = try ChildEvidenceVolume(
            envelopeBytes: try rootEnvelope.encode(),
            childCID: childCID
        )
        try await retainChildGenesisVolumes(
            bootstrapRoots,
            storer: recoveryVolumeBroker
        )
        try await proofAttachment.store(storer: recoveryVolumeBroker)
        let recoveryRoots = bootstrapRoots
            + [proofAttachment.rawCID]
        try await mergeRecoveryRetention(
            scope: issuedRecoveryRetentionScope,
            roots: recoveryRoots
        )
        try database.transaction {
            try persistChildGenesisVolumeRoots(
                childCID: childCID,
                roots: bootstrapRoots
            )
            try persistIssuedChildEdgeRow(edge)
            try persistIssuedChildProofRow(
                scope: .outgoingDirectChild,
                edgeCID: edgeCID,
                rootCID: proof.rootCID,
                attachmentCID: proofAttachment.rawCID
            )
        }
    }

    private func validatedProofPayload(
        _ proof: ChildBlockProof,
        childCID: String,
        exactDirectoryPath: [String]? = nil
    ) async throws -> Data {
        guard !childCID.isEmpty,
              exactDirectoryPath.map({ proof.directoryPath == $0 }) ?? true,
              try await Self.proves(
                proof,
                childCID: childCID,
                from: chainPath
              ) else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        let payload = try proof.serialize()
        guard ChildBlockProof.deserialize(payload) != nil else {
            throw NodeStoreError.invalidIssuedChildProof(childCID)
        }
        return payload
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
            "SELECT attachment_cid, ordinal FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 AND root_cid = ?3",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
            ]
        )
        if let row = existing {
            guard try row.attachmentCID == attachmentCID,
                  try (row.ordinal != nil) == (scope == .outgoingDirectChild) else {
                throw NodeStoreError.conflictingIssuedChildProof
            }
            return
        }
        let ordinal: NodeSQLiteValue
        if scope == .outgoingDirectChild {
            let maximum = try database.row(
                from: IssuedChildProofRow.table,
                "SELECT COALESCE(MAX(ordinal), 0) AS ordinal FROM issued_child_proofs"
            )?.int("ordinal") ?? 0
            guard maximum < Int64.max else {
                throw NodeStoreError.corrupt(
                    "child-evidence ordinal exhausted"
                )
            }
            ordinal = .int(maximum + 1)
        } else {
            ordinal = .null
        }
        try database.execute(
            "INSERT INTO issued_child_proofs (scope, edge_cid, root_cid, attachment_cid, ordinal) VALUES (?1, ?2, ?3, ?4, ?5)",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
                .text(attachmentCID),
                ordinal,
            ]
        )
    }

    func issuedChildEvidence(
        childCID: String,
        directory: String,
        rootCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        try await issuedChildEvidence(
            scope: .outgoingDirectChild,
            childCID: childCID,
            directory: directory,
            rootCID: rootCID
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
    /// is the answer to "whom does this chain ask its parent to re-serve"
    /// after a restart. Joined on `accepted_blocks` deliberately: the relay
    /// evidence table also records carriers of blocks this chain refused —
    /// every merged-mining round whose root missed this chain's target — and
    /// those are not committers of anything here.
    func incomingCarrierCommitters(limit: Int) throws -> [String] {
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
    func incomingCarrierChildBlock(committer: String) throws -> String? {
        try database.row(
            ProofEdgeJoinRow.self,
            "SELECT e.child_cid \(Self.proofEdgeJoinSQL) INNER JOIN accepted_blocks AS a ON a.block_cid = e.child_cid WHERE p.scope = ?1 AND e.parent_carrier_cid = ?2 LIMIT 1",
            params: [.text(IssuedChildProofScope.incomingCarrier.rawValue), .text(committer)]
        )?.childCID
    }

    func issuedChildEvidence(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String
    ) async throws -> IssuedChildEvidence? {
        guard let row = try database.row(
            ProofEdgeJoinRow.self,
            "SELECT e.child_cid, e.directory \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND p.edge_cid = ?2 AND p.root_cid = ?3 LIMIT 1",
            params: [.text(scope.rawValue), .text(edgeCID), .text(rootCID)]
        ) else {
            return nil
        }
        let evidence = try await issuedChildEvidence(
            scope: scope,
            childCID: try row.childCID,
            directory: try row.directory,
            rootCID: rootCID,
            exactEdgeCID: edgeCID
        )
        guard evidence?.edgeCID == edgeCID else {
            throw NodeStoreError.corrupt("malformed child root attachment")
        }
        return evidence
    }

    func issuedChildEvidence(
        scope: IssuedChildProofScope,
        edgeCID: String
    ) async throws -> IssuedChildEvidence? {
        guard let rootCID = try database.row(
            IssuedChildProofRow.self,
            "SELECT root_cid FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 ORDER BY root_cid LIMIT 1",
            params: [.text(scope.rawValue), .text(edgeCID)]
        )?.rootCID else {
            return nil
        }
        return try await issuedChildEvidence(
            scope: scope,
            edgeCID: edgeCID,
            rootCID: rootCID
        )
    }

    private func issuedChildEvidence(
        scope: IssuedChildProofScope,
        childCID: String,
        directory: String,
        rootCID: String? = nil,
        exactEdgeCID: String? = nil
    ) async throws -> IssuedChildEvidence? {
        guard !directory.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "child-proof directory must be nonempty"
            )
        }
        let rows: [ProofEdgeJoinRow]
        if let rootCID, let exactEdgeCID {
            rows = try database.rows(
                ProofEdgeJoinRow.self,
                "SELECT p.edge_cid, p.root_cid, p.attachment_cid, e.parent_carrier_cid, e.directory, e.child_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND p.edge_cid = ?2 AND e.child_cid = ?3 AND e.directory = ?4 AND p.root_cid = ?5 LIMIT 1",
                params: [
                    .text(scope.rawValue), .text(exactEdgeCID),
                    .text(childCID), .text(directory), .text(rootCID),
                ]
            )
        } else if let rootCID {
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

    func issuedChildProofRoots(
        childCID: String,
        directory: String,
        afterRootCID: String?,
        limit: Int
    ) async throws -> [String] {
        try await issuedChildProofRoots(
            scope: .outgoingDirectChild,
            childCID: childCID,
            directory: directory,
            afterRootCID: afterRootCID,
            limit: limit
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

    func issuedChildEvidenceSummaries(
        directory: String,
        afterOrdinal: UInt64,
        throughOrdinal: UInt64,
        limit: Int
    ) async throws -> [IssuedChildEvidenceSummary] {
        guard !directory.isEmpty, limit > 0,
              let sqlLimit = Int64(exactly: limit),
              let after = Int64(exactly: afterOrdinal),
              let through = Int64(exactly: throughOrdinal),
              after <= through else {
            throw NodeStoreError.invalidConfiguration(
                "child-evidence page must be bounded"
            )
        }
        let rows = try database.rows(
            ProofEdgeJoinRow.self,
            "SELECT p.ordinal, e.child_cid, p.root_cid, p.attachment_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.directory = ?2 AND p.ordinal > ?3 AND p.ordinal <= ?4 ORDER BY p.ordinal LIMIT ?5",
            params: [
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(directory), .int(after), .int(through), .int(sqlLimit),
            ]
        )
        return try rows.map { row in
            // An outgoing proof always carries an ordinal (the table's
            // CHECK); one without is an index inconsistency, not a column.
            guard let ordinal = try row.ordinal else {
                throw NodeStoreError.corrupt(
                    "malformed locally issued child-evidence index"
                )
            }
            return IssuedChildEvidenceSummary(
                ordinal: ordinal,
                childCID: try row.childCID,
                rootCID: try row.rootCID,
                attachmentCID: try row.attachmentCID
            )
        }
    }

    func issuedChildEvidenceScanHead(directory: String) throws
        -> (sourceID: String, throughOrdinal: UInt64)
    {
        guard !directory.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "child-evidence directory must be nonempty"
            )
        }
        let sourceID = try syncSourceID()
        guard let through = try database.row(
                from: ProofEdgeJoinRow.table,
                "SELECT COALESCE(MAX(p.ordinal), 0) AS ordinal \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.directory = ?2",
                params: [
                    .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                    .text(directory),
                ]
              )?.uint64("ordinal") else {
            throw NodeStoreError.corrupt(
                "malformed child-evidence scan head"
            )
        }
        return (sourceID, through)
    }

    func issuedChildEvidenceSummary(
        childCID: String,
        directory: String,
        rootCID: String
    ) throws -> (sourceID: String, summary: IssuedChildEvidenceSummary)? {
        guard let row = try database.row(
            ProofEdgeJoinRow.self,
            "SELECT p.ordinal, p.attachment_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.child_cid = ?2 AND e.directory = ?3 AND p.root_cid = ?4 LIMIT 1",
            params: [
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(childCID), .text(directory), .text(rootCID),
            ]
        ), let ordinal = try row.ordinal else {
            return nil
        }
        return (
            try issuedChildEvidenceScanHead(directory: directory).sourceID,
            IssuedChildEvidenceSummary(
                ordinal: ordinal,
                childCID: childCID,
                rootCID: rootCID,
                attachmentCID: try row.attachmentCID
            )
        )
    }

    func childRootAttachmentSummaries(
        scope: IssuedChildProofScope,
        directory: String,
        after: ChildRootAttachmentSummary?,
        limit: Int
    ) async throws -> [ChildRootAttachmentSummary] {
        guard !directory.isEmpty, limit > 0,
              let sqlLimit = Int64(exactly: limit) else {
            throw NodeStoreError.invalidConfiguration(
                "child root-attachment page must be bounded"
            )
        }
        let rows: [ProofEdgeJoinRow]
        if let after {
            rows = try database.rows(
                ProofEdgeJoinRow.self,
                "SELECT p.edge_cid, e.child_cid, p.root_cid, p.attachment_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.directory = ?2 AND (p.edge_cid > ?3 OR (p.edge_cid = ?3 AND p.root_cid > ?4)) ORDER BY p.edge_cid, p.root_cid LIMIT ?5",
                params: [
                    .text(scope.rawValue), .text(directory), .text(after.edgeCID),
                    .text(after.rootCID), .int(sqlLimit),
                ]
            )
        } else {
            rows = try database.rows(
                ProofEdgeJoinRow.self,
                "SELECT p.edge_cid, e.child_cid, p.root_cid, p.attachment_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.directory = ?2 ORDER BY p.edge_cid, p.root_cid LIMIT ?3",
                params: [
                    .text(scope.rawValue), .text(directory), .int(sqlLimit),
                ]
            )
        }
        return try rows.map { row in
            // The child CID is projected and checked with the rest of the
            // row even though the summary does not carry it.
            _ = try row.childCID
            return ChildRootAttachmentSummary(
                edgeCID: try row.edgeCID,
                rootCID: try row.rootCID,
                attachmentCID: try row.attachmentCID
            )
        }
    }

    func parentEvidenceScanCursor() throws -> ParentEvidenceScanCursor {
        let rows = try database.rows(
            ParentEvidenceScanRow.self,
            "SELECT source_id, ordinal FROM parent_evidence_scan WHERE singleton = 1"
        )
        guard rows.count == 1 else {
            throw NodeStoreError.corrupt(
                "malformed parent-evidence scan cursor"
            )
        }
        return ParentEvidenceScanCursor(
            sourceID: try rows[0].sourceID,
            ordinal: try rows[0].ordinal
        )
    }

    /// Returns whether this carrier's evidence was admitted before (then no
    /// inbox entry is kept and there is nothing to admit again).
    @discardableResult
    func storeParentEvidenceInbox(
        sourceID: String,
        ordinal: UInt64,
        attachment: ChildEvidenceVolume,
        package: AuthenticatedChildPackage,
        advanceScan: Bool
    ) async throws -> Bool {
        guard UUID(uuidString: sourceID) != nil,
              ordinal > 0,
              let sqlOrdinal = Int64(exactly: ordinal),
              package.package.proof.rootCID.isEmpty == false,
              let directHop = await package.package.proof.directHop() else {
            throw NodeStoreError.invalidConfiguration(
                "parent-evidence inbox reference is malformed"
            )
        }
        let envelope = try ChildValidationPackageEnvelope(
            package.package
        ).encode()
        guard envelope == attachment.envelopeBytes else {
            throw NodeStoreError.invalidIssuedChildProof(directHop.childCID)
        }
        _ = try await prepareCarrierEvidence(
            ImportCarrierEvidence(
                proof: package.package.proof,
                childCID: directHop.childCID
            ),
            expectedChildCIDs: [directHop.childCID],
            expectedRootCID: package.package.proof.rootCID
        )
        let existing = try database.row(
            ParentEvidenceInboxRow.self,
            "SELECT child_cid, root_cid, attachment_cid FROM parent_evidence_inbox WHERE source_id = ?1 AND ordinal = ?2",
            params: [.text(sourceID), .int(sqlOrdinal)]
        )
        if let row = existing {
            guard try row.childCID == directHop.childCID,
                  try row.rootCID == package.package.proof.rootCID,
                  try row.attachmentCID == attachment.rawCID else {
                throw NodeStoreError.corrupt(
                    "parent-evidence ordinal changed"
                )
            }
        }
        let alreadyAdmitted = try admittedCarrierEvidenceExists(
            attachmentCID: attachment.rawCID,
            childCID: directHop.childCID,
            rootCID: package.package.proof.rootCID
        )
        if !alreadyAdmitted, existing == nil {
            let count = try database.row(
                from: ParentEvidenceInboxRow.table,
                "SELECT COUNT(*) AS count FROM parent_evidence_inbox"
            )?.int("count")
            guard let count, count < Int64(parentEvidenceInboxCapacity) else {
                throw NodeStoreError.parentEvidenceInboxFull
            }
        }
        try await attachment.store(storer: recoveryVolumeBroker)
        if !alreadyAdmitted {
            try await mergeRecoveryRetention(
                scope: parentEvidenceInboxRetentionScope,
                roots: [attachment.rawCID]
            )
        }
        let admittedDuringStore: Bool
        do {
            admittedDuringStore = try database.transaction {
                let transactionalExisting = try database.row(
                    ParentEvidenceInboxRow.self,
                    "SELECT child_cid, root_cid, attachment_cid FROM parent_evidence_inbox WHERE source_id = ?1 AND ordinal = ?2",
                    params: [.text(sourceID), .int(sqlOrdinal)]
                )
                if let row = transactionalExisting {
                    guard try row.childCID == directHop.childCID,
                          try row.rootCID == package.package.proof.rootCID,
                          try row.attachmentCID == attachment.rawCID else {
                        throw NodeStoreError.corrupt(
                            "parent-evidence ordinal changed"
                        )
                    }
                }
                let admitted = try admittedCarrierEvidenceExists(
                    attachmentCID: attachment.rawCID,
                    childCID: directHop.childCID,
                    rootCID: package.package.proof.rootCID
                )
                if admitted {
                    try deleteParentEvidenceInbox(attachmentCID: attachment.rawCID)
                } else if transactionalExisting == nil {
                    let count = try database.row(
                        from: ParentEvidenceInboxRow.table,
                        "SELECT COUNT(*) AS count FROM parent_evidence_inbox"
                    )?.int("count")
                    guard let count, count < Int64(parentEvidenceInboxCapacity) else {
                        throw NodeStoreError.parentEvidenceInboxFull
                    }
                    try database.execute(
                        "INSERT INTO parent_evidence_inbox (source_id, ordinal, child_cid, root_cid, attachment_cid) VALUES (?1, ?2, ?3, ?4, ?5)",
                        params: [
                            .text(sourceID), .int(sqlOrdinal),
                            .text(directHop.childCID),
                            .text(package.package.proof.rootCID),
                            .text(attachment.rawCID),
                        ]
                    )
                }
                _ = try markContextualCandidateHandoff(
                    candidateCID: directHop.childCID
                )
                if advanceScan {
                    try persistParentEvidenceScan(
                        sourceID: sourceID,
                        ordinal: ordinal
                    )
                }
                return admitted
            }
        } catch {
            if !alreadyAdmitted {
                await reconcileParentEvidenceInboxRetention()
            }
            throw error
        }
        if admittedDuringStore {
            await reconcileParentEvidenceInboxRetention()
        }
        return admittedDuringStore
    }

    private func admittedCarrierEvidenceExists(
        attachmentCID: String,
        childCID: String,
        rootCID: String
    ) throws -> Bool {
        try database.query(
            "SELECT 1 \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND p.attachment_cid = ?2 AND e.child_cid = ?3 AND p.root_cid = ?4 LIMIT 1",
            params: [
                .text(IssuedChildProofScope.incomingCarrier.rawValue),
                .text(attachmentCID),
                .text(childCID),
                .text(rootCID),
            ]
        ).isEmpty == false
    }

    private func persistParentEvidenceScan(
        sourceID: String,
        ordinal: UInt64
    ) throws {
        let current = try parentEvidenceScanCursor()
        let nextOrdinal = current.sourceID == sourceID
            ? max(current.ordinal, ordinal)
            : ordinal
        guard let sqlOrdinal = Int64(exactly: nextOrdinal) else {
            throw NodeStoreError.invalidConfiguration(
                "parent-evidence scan cursor is too large"
            )
        }
        try database.execute(
            "UPDATE parent_evidence_scan SET source_id = ?1, ordinal = ?2 WHERE singleton = 1",
            params: [.text(sourceID), .int(sqlOrdinal)]
        )
    }

    /// Owner: ImportJournal.stage / EvidenceIndex.persistIssuedHierarchyArtifacts / EvidenceIndex.storeParentEvidenceInbox — caller holds the transaction.
    func deleteParentEvidenceInbox(attachmentCID: String) throws {
        try database.execute(
            "DELETE FROM parent_evidence_inbox WHERE attachment_cid = ?1",
            params: [.text(attachmentCID)]
        )
    }

    /// Drop the inbox entries for one (block, root) an admission decided
    /// without persisting relay evidence; the persist and stage paths consume
    /// theirs by attachment. Nothing else removes an entry.
    func consumeParentEvidence(childCID: String, rootCID: String) async throws {
        let present = try database.query(
            "SELECT 1 FROM parent_evidence_inbox WHERE child_cid = ?1 AND root_cid = ?2 LIMIT 1",
            params: [.text(childCID), .text(rootCID)]
        )
        guard !present.isEmpty else { return }
        try database.execute(
            "DELETE FROM parent_evidence_inbox WHERE child_cid = ?1 AND root_cid = ?2",
            params: [.text(childCID), .text(rootCID)]
        )
        await reconcileParentEvidenceInboxRetention()
    }

    func parentEvidenceInboxHasCapacity() throws -> Bool {
        let count = try database.row(
            from: ParentEvidenceInboxRow.table,
            "SELECT COUNT(*) AS count FROM parent_evidence_inbox"
        )?.int("count")
        guard let count else {
            throw NodeStoreError.corrupt(
                "parent-evidence inbox count is malformed"
            )
        }
        return count < Int64(parentEvidenceInboxCapacity)
    }

    func parentEvidenceInbox() async throws -> [ParentEvidenceInboxItem] {
        let rows = try database.rows(
            ParentEvidenceInboxRow.self,
            "SELECT source_id, ordinal, child_cid, root_cid, attachment_cid FROM parent_evidence_inbox ORDER BY source_id, ordinal"
        )
        var items: [ParentEvidenceInboxItem] = []
        items.reserveCapacity(rows.count)
        for row in rows {
            let sourceID = try row.sourceID
            let ordinal = try row.ordinal
            let childCID = try row.childCID
            let rootCID = try row.rootCID
            let attachmentCID = try row.attachmentCID
            let attachment = try await recoveryVolume(
                attachmentCID: attachmentCID,
                childCID: childCID
            )
            guard let envelope = try? ChildValidationPackageEnvelope.decode(
                attachment.envelopeBytes
            ), let proof = ChildBlockProof.deserialize(envelope.proofBytes),
               proof.rootCID == rootCID else {
                throw NodeStoreError.corrupt(
                    "malformed parent-evidence inbox attachment"
                )
            }
            let package = AuthenticatedChildPackage(
                package: ChildValidationPackage(proof: proof)
            )
            _ = try await prepareCarrierEvidence(
                ImportCarrierEvidence(
                    proof: proof,
                    childCID: childCID
                ),
                expectedChildCIDs: [childCID],
                expectedRootCID: rootCID
            )
            items.append(ParentEvidenceInboxItem(
                sourceID: sourceID,
                ordinal: ordinal,
                attachment: attachment,
                package: package
            ))
        }
        return items
    }

    func portableEvidenceVolumeCID(
        scope: IssuedChildProofScope,
        edgeCID: String,
        rootCID: String
    ) throws -> String? {
        let rows = try database.rows(
            IssuedChildProofRow.self,
            "SELECT attachment_cid FROM issued_child_proofs WHERE scope = ?1 AND edge_cid = ?2 AND root_cid = ?3",
            params: [
                .text(scope.rawValue), .text(edgeCID), .text(rootCID),
            ]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1 else {
            throw NodeStoreError.corrupt("malformed portable recovery attachment index")
        }
        return try row.attachmentCID
    }

    /// Permanent root-independent hops already published by this parent.
    /// They outlive the bounded pre-publication recovery buffer and can be
    /// recomposed whenever this carrier gains another authenticated root.
    func retainedDirectChildProofs(
        carrierCID: String
    ) async throws -> [PreparedChildProof] {
        let rows = try database.rows(
            ProofEdgeJoinRow.self,
            "SELECT DISTINCT p.edge_cid \(Self.proofEdgeJoinSQL) WHERE p.scope = ?1 AND e.parent_carrier_cid = ?2 ORDER BY p.edge_cid",
            params: [
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(carrierCID),
            ]
        )
        var proofs: [PreparedChildProof] = []
        proofs.reserveCapacity(rows.count)
        for row in rows {
            guard let evidence = try await issuedChildEvidence(
                    scope: .outgoingDirectChild,
                    edgeCID: try row.edgeCID
                  ), let proof = evidence.edge.proof else {
                throw NodeStoreError.corrupt("malformed retained direct-child edge")
            }
            let bootstrapRoots = try childGenesisVolumeRoots(
                childCID: evidence.edge.childCID
            )
            proofs.append(try PreparedChildProof(
                directory: evidence.edge.directory,
                childCID: evidence.edge.childCID,
                isChildGenesis: !bootstrapRoots.isEmpty,
                bootstrapRoots: bootstrapRoots,
                proof: proof
            ))
        }
        return proofs
    }

    /// Durable direct edges can outlive their bounded preparation row. Return
    /// only carriers whose retained edge has a newly learned upstream root
    /// that has not been composed into an outgoing attachment yet.
    func uncomposedDirectChildProofCarrierCIDs(
        parentDirectory: String
    ) async throws -> [String] {
        guard !parentDirectory.isEmpty else { return [] }
        return try database.rows(
            from: IssuedChildEdgeRow.table,
            """
            SELECT DISTINCT outgoing_edge.parent_carrier_cid AS carrier_cid
            FROM issued_child_edges AS outgoing_edge
            INNER JOIN issued_child_proofs AS retained
                ON retained.edge_cid = outgoing_edge.edge_cid
                AND retained.scope = ?1
            INNER JOIN issued_child_edges AS incoming_edge
                ON incoming_edge.child_cid = outgoing_edge.parent_carrier_cid
                AND incoming_edge.directory = ?2
            INNER JOIN issued_child_proofs AS incoming
                ON incoming.edge_cid = incoming_edge.edge_cid
                AND incoming.scope = ?3
            WHERE NOT EXISTS (
                SELECT 1
                FROM issued_child_proofs AS composed
                WHERE composed.scope = ?1
                    AND composed.edge_cid = outgoing_edge.edge_cid
                    AND composed.root_cid = incoming.root_cid
            )
            ORDER BY carrier_cid
            """,
            params: [
                .text(IssuedChildProofScope.outgoingDirectChild.rawValue),
                .text(parentDirectory),
                .text(IssuedChildProofScope.incomingCarrier.rawValue),
            ]
        ).map { try $0.text("carrier_cid") }
    }

    private func persistIssuedParentFact(
        kind: String,
        keyA: String,
        keyB: String,
        payload: Data
    ) throws {
        guard !keyA.isEmpty, !keyB.isEmpty else {
            throw NodeStoreError.invalidConfiguration(
                "issued parent fact keys must be nonempty"
            )
        }
        let existing = try database.row(
            IssuedParentFactRow.self,
            "SELECT payload FROM issued_parent_facts WHERE kind = ?1 AND key_a = ?2 AND key_b = ?3",
            params: [.text(kind), .text(keyA), .text(keyB)]
        )
        if let existing {
            guard try existing.payload == payload else {
                throw NodeStoreError.conflictingIssuedParentFact
            }
            return
        }
        try database.execute(
            "INSERT INTO issued_parent_facts (kind, key_a, key_b, payload) VALUES (?1, ?2, ?3, ?4)",
            params: [
                .text(kind), .text(keyA), .text(keyB), .blob(payload),
            ]
        )
    }

    private func issuedParentFact(
        kind: String,
        keyA: String,
        keyB: String
    ) throws -> Data? {
        try database.row(
            IssuedParentFactRow.self,
            "SELECT payload FROM issued_parent_facts WHERE kind = ?1 AND key_a = ?2 AND key_b = ?3",
            params: [.text(kind), .text(keyA), .text(keyB)]
        )?.payload
    }

    private static func addExpectedParentFact(
        key: IssuedParentFactKey,
        payload: Data,
        to facts: inout [IssuedParentFactKey: Data]
    ) throws {
        if let existing = facts[key], existing != payload {
            throw NodeStoreError.corrupt(
                "parent-fact sources disagree about an immutable fact"
            )
        }
        facts[key] = payload
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

    func auditIssuedParentFacts(connected connectedAcceptedBlocks: Set<String>) throws {
        var expectedParentFacts: [IssuedParentFactKey: Data] = [:]
        for row in try database.rows(
            IssuedParentFactSourceRow.self,
            "SELECT payload FROM issued_parent_fact_sources ORDER BY payload"
        ) {
            let payload = try row.payload
            let source = try Self.decode(
                PersistedParentFactSource.self,
                from: payload
            )
            guard try Self.encode(source) == payload,
                  source.carrierLink.parentPath == chainPath,
                  !source.carrierLink.carrierCID.isEmpty,
                  !source.carrierLink.rootCID.isEmpty,
                  chainPath.count > 1
                    || source.carrierLink.carrierCID
                        == source.carrierLink.rootCID else {
                throw NodeStoreError.corrupt("invalid parent-fact source")
            }
            let sortedGenesis = Array(Set(source.parentGenesisLinks)).sorted {
                ($0.directory, $0.childGenesisCID, $0.parentStateCID)
                    < ($1.directory, $1.childGenesisCID, $1.parentStateCID)
            }
            guard source.parentGenesisLinks == sortedGenesis,
                  source.parentGenesisLinks.allSatisfy({
                      $0.parentPath == chainPath
                          && !$0.directory.isEmpty
                          && !$0.childGenesisCID.isEmpty
                          && !$0.parentStateCID.isEmpty
                  }),
                  source.parentGenesisLinks.isEmpty
                    || connectedAcceptedBlocks.contains(
                        source.carrierLink.carrierCID
                    ) else {
                throw NodeStoreError.corrupt("invalid genesis-fact source")
            }
            try Self.addExpectedParentFact(
                key: IssuedParentFactKey(
                    kind: "carrier",
                    keyA: source.carrierLink.carrierCID,
                    keyB: source.carrierLink.rootCID
                ),
                payload: try Self.encode(source.carrierLink),
                to: &expectedParentFacts
            )
            for link in source.parentGenesisLinks {
                try Self.addExpectedParentFact(
                    key: IssuedParentFactKey(
                        kind: "genesis",
                        keyA: link.directory,
                        keyB: Self.parentGenesisFactKey(link)
                    ),
                    payload: try Self.encode(link),
                    to: &expectedParentFacts
                )
            }
        }
        var actualParentFacts: [IssuedParentFactKey: Data] = [:]
        for row in try database.rows(
            IssuedParentFactRow.self,
            "SELECT kind, key_a, key_b, payload FROM issued_parent_facts"
        ) {
            actualParentFacts[IssuedParentFactKey(
                kind: try row.kind,
                keyA: try row.keyA,
                keyB: try row.keyB
            )] = try row.payload
        }
        guard actualParentFacts == expectedParentFacts else {
            throw NodeStoreError.corrupt(
                "issued parent facts do not match immutable sources"
            )
        }
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
        let outgoingOrdinals = try database.rows(
            IssuedChildProofRow.self,
            "SELECT ordinal FROM issued_child_proofs WHERE scope = ?1 ORDER BY ordinal",
            params: [.text(IssuedChildProofScope.outgoingDirectChild.rawValue)]
        )
        for (offset, row) in outgoingOrdinals.enumerated() {
            guard try row.ordinal == UInt64(offset + 1) else {
                throw NodeStoreError.corrupt(
                    "child-evidence ordinals are not contiguous"
                )
            }
        }
        let invalidIncomingOrdinal = try database.query(
            "SELECT 1 FROM issued_child_proofs WHERE scope != ?1 AND ordinal IS NOT NULL LIMIT 1",
            params: [.text(IssuedChildProofScope.outgoingDirectChild.rawValue)]
        )
        guard invalidIncomingOrdinal.isEmpty else {
            throw NodeStoreError.corrupt(
                "incoming evidence has an outgoing ordinal"
            )
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

    func auditParentEvidence() async throws {
        _ = try parentEvidenceScanCursor()
        _ = try await parentEvidenceInbox()
    }
}
