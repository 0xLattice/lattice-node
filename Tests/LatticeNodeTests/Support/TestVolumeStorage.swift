import Foundation
import VolumeBroker

@testable import LatticeNode

func testNodeStore(
    databasePath: URL,
    nexusGenesisCID: String,
    chainPath: [String],
    spawningParentKey: String = "",
    issuingAuthorityKey: String = String(repeating: "a", count: 64),
    contextualCandidateOwner: String = "test:contextual-candidates",
    broker suppliedBroker: (any RetainedRootMergeBroker)? = nil,
    parentEvidenceInboxCapacity: Int = 64,
    handoffCandidateCapacity: Int = 1_024
) throws -> NodeStore {
    let broker: any RetainedRootMergeBroker
    if let suppliedBroker {
        broker = suppliedBroker
    } else {
        broker = try DiskBroker(
            path: databasePath.deletingLastPathComponent()
                .appendingPathComponent("volumes.db").path
        )
    }
    return try NodeStore(
        databasePath: databasePath,
        nexusGenesisCID: nexusGenesisCID,
        chainPath: chainPath,
        recoveryVolumeBroker: broker,
        blockRetentionScope: "test:blocks",
        issuedRecoveryRetentionScope: "test:issued-hierarchy",
        preparedRecoveryRetentionScope: "test:prepared-hierarchy",
        parentEvidenceInboxCapacity: parentEvidenceInboxCapacity,
        contextualCandidateOwner: contextualCandidateOwner,
        handoffCandidateCapacity: handoffCandidateCapacity
    )
}
