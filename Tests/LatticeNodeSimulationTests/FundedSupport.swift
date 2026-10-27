import Lattice
import LatticeNodeCore

/// Every account `transaction` debits, with more than it could ever be
/// debited: for tests of rules other than the pool's budget.
func funded(_ transaction: Transaction) -> [String: UInt64] {
    (transaction.body.node.flatMap(Mempool.debits(of:)) ?? [:]).mapValues { _ in UInt64(Int64.max) }
}

func funded(_ job: PreflightJob) -> [String: UInt64] { funded(job.transaction) }

extension Mempool {
    /// `submit` with every debited account funded.
    @discardableResult
    mutating func submit(_ transaction: Transaction, spec: ChainSpec, addedAt: Int64) throws -> MempoolMutation {
        try submit(transaction, spec: spec, addedAt: addedAt, balances: funded(transaction))
    }
}
