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
    blockRetentionScope: String = "test:blocks",
    broker suppliedBroker: (any RetainedRootMergeBroker)? = nil
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
        blockRetentionScope: blockRetentionScope,
        issuedRecoveryRetentionScope: "test:issued-hierarchy",
        contextualCandidateOwner: contextualCandidateOwner
    )
}
