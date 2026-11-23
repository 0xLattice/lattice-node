import cashew
import Lattice

extension Block {
    /// The block's transactions in index order, resolved through `fetcher`.
    package func orderedTransactions(fetcher: any Fetcher) async throws -> [Transaction] {
        let transactionsHeader = try await transactions.resolve(
            fetcher: fetcher
        )
        guard let dictionary = transactionsHeader.node else {
            throw NodeAPIError.unresolvedTransactionContent
        }
        let entries = try await dictionary.boundedKeysAndValues(
            limit: dictionary.count,
            fetcher: fetcher
        )
        guard entries.count == dictionary.count else {
            throw NodeAPIError.unresolvedTransactionContent
        }
        let headers = Dictionary(uniqueKeysWithValues: entries)
        var transactions: [Transaction] = []
        for index in 0..<headers.count {
            guard let transactionHeader = headers[String(index)] else {
                throw NodeAPIError.unresolvedTransactionContent
            }
            let resolved = try await transactionHeader.resolve(fetcher: fetcher)
            guard let transaction = resolved.node else {
                throw NodeAPIError.unresolvedTransactionContent
            }
            transactions.append(transaction)
        }
        return transactions
    }
}
