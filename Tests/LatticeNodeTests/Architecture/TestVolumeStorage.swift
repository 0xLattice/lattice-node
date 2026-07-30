import Foundation
import VolumeBroker

@testable import LatticeNode

func testNodeStore(
    databasePath: URL,
    nexusGenesisCID: String,
    chainPath: [String],
    spawningParentKey: String = "",
    issuingAuthorityKey: String = String(repeating: "a", count: 64),
    contextualCandidateOwner: String = "test:contextual-candidates"
) throws -> NodeStore {
    let broker = try DiskBroker(
        path: databasePath.deletingLastPathComponent()
            .appendingPathComponent("volumes.db").path
    )
    return try NodeStore(
        databasePath: databasePath,
        nexusGenesisCID: nexusGenesisCID,
        chainPath: chainPath,
        recoveryVolumeBroker: broker,
        issuedRecoveryRetentionScope: "test:issued-hierarchy",
        preparedRecoveryRetentionScope: "test:prepared-hierarchy",
        contextualCandidateOwner: contextualCandidateOwner
    )
}
