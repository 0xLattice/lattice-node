import Lattice
import cashew

extension Mempool {
    /// The balance on `state` of each account `body` debits, for the pool's
    /// budget (`submit(_:spec:addedAt:balances:)`). An account it holds no
    /// entry for has none. Nil when the state cannot be read.
    public static func balances(
        debitedBy body: TransactionBody,
        on state: LatticeState,
        fetcher: any Fetcher
    ) async -> [String: UInt64]? {
        guard let debits = debits(of: body) else { return nil }
        if debits.isEmpty { return [:] }
        let paths = Dictionary(uniqueKeysWithValues: debits.keys.map { ([$0], ResolutionStrategy.targeted) })
        guard let accounts = try? await state.accountState.resolve(paths: paths, fetcher: fetcher) else { return nil }
        var balances: [String: UInt64] = [:]
        for account in debits.keys {
            balances[account] = accounts.node.flatMap { try? $0.get(key: account) } ?? 0
        }
        return balances
    }
}
