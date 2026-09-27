import Foundation
import Ivy
import Lattice
import UInt256
import VolumeBroker
import cashew

struct LocalMempoolTransactionRecord: Sendable, Equatable {
    let transactionCID: String
    let addedAt: Int64
}

extension NodeStore {
    func persistLocalMempoolTransaction(
        transactionCID: String,
        addedAt: Int64
    ) throws {
        guard CIDIdentity.isCanonical(transactionCID), addedAt >= 0 else {
            throw NodeStoreError.invalidConfiguration(
                "local mempool transaction reference is malformed"
            )
        }
        try database.execute(
            "INSERT OR IGNORE INTO local_mempool_transactions (transaction_cid, added_at) VALUES (?1, ?2)",
            params: [.text(transactionCID), .int(addedAt)]
        )
    }

    func removeLocalMempoolTransaction(transactionCID: String) throws {
        guard CIDIdentity.isCanonical(transactionCID) else {
            throw NodeStoreError.invalidConfiguration(
                "local mempool transaction CID is malformed"
            )
        }
        try database.execute(
            "DELETE FROM local_mempool_transactions WHERE transaction_cid = ?1",
            params: [.text(transactionCID)]
        )
    }

    func localMempoolTransactions() throws -> [LocalMempoolTransactionRecord] {
        try database.query(
            "SELECT transaction_cid, added_at FROM local_mempool_transactions ORDER BY added_at, transaction_cid"
        ).map { row in
            guard let transactionCID = row["transaction_cid"]?.textValue,
                  let addedAt = row["added_at"]?.intValue,
                  CIDIdentity.isCanonical(transactionCID),
                  addedAt >= 0 else {
                throw NodeStoreError.corrupt(
                    "malformed local mempool transaction reference"
                )
            }
            return LocalMempoolTransactionRecord(
                transactionCID: transactionCID,
                addedAt: addedAt
            )
        }
    }
}
