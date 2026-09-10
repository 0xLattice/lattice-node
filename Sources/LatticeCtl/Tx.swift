// Transactions: author, sign, and submit ordinary transactions for a chain
// in the tree. Signing uses a `lattice-rewards` key file and never leaves this
// host; submission goes to that chain's loopback RPC, which validates it
// against current state before it enters the pool. Four shapes cover the
// protocol's action types: a plain transfer, and the three legs of a
// parent/child value exchange (deposit on the child, receipt on the parent,
// withdrawal on the child).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import Lattice
import LatticeCtlCore
import LatticeNode
import cashew

struct Tx: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Sign and submit a transaction on a chain in the tree.",
        subcommands: [Send.self, Deposit.self, Receipt.self, Withdraw.self]
    )

    struct Send: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Transfer value between accounts on one chain."
        )

        @OptionGroup var tx: TxOptions

        @Option(name: .long, help: "Recipient address.")
        var to: String

        @Option(name: .long, help: "Amount to transfer.")
        var amount: UInt64

        func run() async throws {
            let signer = try tx.signer()
            try requireAddress(to, "--to")
            let delta = try amountDelta(amount)
            try await tx.submit(
                signer: signer,
                accountActions: [
                    AccountAction(owner: signer.address, delta: -delta),
                    AccountAction(owner: to, delta: delta),
                ]
            )
        }
    }

    struct Deposit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Lock value on this child chain, demanding payment on its parent."
        )

        @OptionGroup var tx: TxOptions
        @OptionGroup var swap: SwapOptions

        @Option(name: .long, help: "Amount locked on this chain (amountDeposited).")
        var lock: UInt64

        func run() async throws {
            let signer = try tx.signer()
            let locked = try amountDelta(lock)
            try await tx.submit(
                signer: signer,
                accountActions: [
                    AccountAction(owner: signer.address, delta: -locked),
                ],
                depositActions: [DepositAction(
                    nonce: UInt128(swap.swapNonce),
                    demander: signer.address,
                    amountDemanded: swap.demand,
                    amountDeposited: lock
                )]
            )
        }
    }

    struct Receipt: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pay a child-chain demander on this (parent) chain, recording the receipt."
        )

        @OptionGroup var tx: TxOptions
        @OptionGroup var swap: SwapOptions

        @Option(name: .long, help: "The demander who deposited on the child.")
        var demander: String

        @Option(name: .long, help: "The child's directory edge under this chain (e.g. Market).")
        var directory: String

        func run() async throws {
            let signer = try tx.signer()
            try requireAddress(demander, "--demander")
            guard !directory.isEmpty, !directory.contains("/") else {
                throw CtlError("--directory is one edge label, not a path")
            }
            try await tx.submit(
                signer: signer,
                receiptActions: [ReceiptAction(
                    withdrawer: signer.address,
                    nonce: UInt128(swap.swapNonce),
                    demander: demander,
                    amountDemanded: swap.demand,
                    directory: directory
                )]
            )
        }
    }

    struct Withdraw: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Claim a deposit on this child chain against the parent receipt you paid."
        )

        @OptionGroup var tx: TxOptions
        @OptionGroup var swap: SwapOptions

        @Option(name: .long, help: "The demander who deposited on this chain.")
        var demander: String

        @Option(name: .long, help: "Amount withdrawn; must equal the locked deposit exactly.")
        var amount: UInt64

        @Option(name: .long, help: "Credit the withdrawn amount to this address (default: the signing key).")
        var to: String?

        func run() async throws {
            let signer = try tx.signer()
            try requireAddress(demander, "--demander")
            let recipient = to ?? signer.address
            try requireAddress(recipient, "--to")
            let credited = try amountDelta(amount)
            try await tx.submit(
                signer: signer,
                accountActions: [
                    AccountAction(owner: recipient, delta: credited),
                ],
                withdrawalActions: [WithdrawalAction(
                    withdrawer: signer.address,
                    nonce: UInt128(swap.swapNonce),
                    demander: demander,
                    amountDemanded: swap.demand,
                    amountWithdrawn: amount
                )]
            )
        }
    }
}

/// The deposit/receipt/withdrawal legs share one identity:
/// `demander / amountDemanded / nonce` (plus the directory on the parent).
struct SwapOptions: ParsableArguments {
    @Option(name: .long, help: "The exchange's nonce: one identity shared by its deposit, receipt, and withdrawal.")
    var swapNonce: UInt64

    @Option(name: .long, help: "Amount the demander is paid on the parent (amountDemanded).")
    var demand: UInt64
}

struct TxOptions: ParsableArguments {
    @OptionGroup var rootOption: RootOption

    @Option(name: .long, help: "Absolute chain path in the tree (e.g. Nexus/Market).")
    var chain: String

    @Option(name: .long, help: "Key file (lattice-rewards format) that signs and pays.")
    var key: String

    @Option(name: .long, help: "Signer nonce; defaults to the chain's next expected nonce for the key.")
    var nonce: UInt64?

    @Option(name: .long, help: "Fee, debited from the signer beyond the actions.")
    var fee: UInt64 = 0

    struct Signer {
        let address: String
        let publicKey: String
        let privateKey: String
    }

    func signer() throws -> Signer {
        struct KeyFile: Decodable {
            let privateKey: String
            let publicKey: String
        }
        let url = URL(fileURLWithPath: key)
        // This key spends money. The tree already refuses to load a
        // group/other-readable node identity, which controls far less.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0 {
            throw CtlError("key file \(url.path) is group/other-readable; chmod 600 it")
        }
        let file = try JSONDecoder().decode(
            KeyFile.self, from: Data(contentsOf: url)
        )
        return Signer(
            address: CryptoUtils.createAddress(from: file.publicKey),
            publicKey: file.publicKey,
            privateKey: file.privateKey
        )
    }

    func submit(
        signer: Signer,
        accountActions: [AccountAction] = [],
        depositActions: [DepositAction] = [],
        receiptActions: [ReceiptAction] = [],
        withdrawalActions: [WithdrawalAction] = []
    ) async throws {
        let topology = try Topology.load(root: rootOption.layout.root).validated()
        guard let target = topology.chains[chain] else {
            throw CtlError("\(chain) is not in the tree")
        }
        let path = chain.components(separatedBy: "/")
        let signerNonce: UInt64
        if let nonce {
            signerNonce = nonce
        } else {
            signerNonce = try await nextNonce(
                rpc: target.rpc, address: signer.address
            )
        }
        var actions = accountActions
        if fee > 0 {
            actions.append(AccountAction(owner: signer.address, delta: -(try amountDelta(fee))))
        }
        let body = TransactionBody(
            accountActions: actions,
            actions: [],
            depositActions: depositActions,
            genesisActions: [],
            receiptActions: receiptActions,
            withdrawalActions: withdrawalActions,
            signers: [signer.address],
            fee: fee,
            nonce: signerNonce,
            chainPath: path
        )
        let header = try HeaderImpl(node: body)
        guard let signature = TransactionSigning.sign(
            bodyHeader: header, privateKeyHex: signer.privateKey
        ) else {
            throw CtlError("signing failed; check the key file")
        }
        let response: SubmitTransactionResponse = try await post(
            rpc: target.rpc, path: "v1/transactions",
            body: SubmitTransactionRequest(transaction: Transaction(
                signatures: [signer.publicKey: signature], body: header
            ))
        )
        print("submitted \(response.transactionCID)")
        print("chain \(chain) signer \(signer.address) nonce \(signerNonce)")
        print("mempool \(response.mempoolCount) transactions")
    }
}

/// The nonce to sign with when the operator did not name one: the chain's
/// next expected nonce for the key, advanced past anything that key already
/// has waiting in the pool.
///
/// The committed tip alone is not enough. Two invocations before a block is
/// mined would both read the same next nonce, and the pool replaces one
/// `(signer, nonce)` with whichever bids the higher real fee — so the earlier
/// transfer would be dropped while both commands printed `submitted` and
/// exited 0. Paying nobody must not look like success.
func nextNonce(rpc: UInt16, address: String) async throws -> UInt64 {
    let committed = try await committedNextNonce(rpc: rpc, address: address)
    guard let pending = try await highestPendingNonce(
        rpc: rpc, signer: address
    ) else { return committed }
    return max(committed, pending &+ 1)
}

/// The chain's own view of the key's next nonce, as of its tip.
func committedNextNonce(rpc: UInt16, address: String) async throws -> UInt64 {
    guard let url = URL(
        string: "http://127.0.0.1:\(rpc)/api/state/account/\(address)"
    ) else { throw CtlError("bad RPC URL") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    // These reads decide which nonce to sign. The node marks them
    // `max-age=3`, and URLSession.shared keeps a shared on-disk cache, so two
    // commands run back to back would otherwise both read the same seconds-old
    // pool and account — the exact window in which the second must see the
    // first.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw CtlError("account lookup failed")
    }
    if http.statusCode == 404 {
        // 404 is both "this key has never transacted" and "the tip is not
        // readable yet". Signing at 0 on the second reading would burn the
        // nonce sequence of a key that is 500 transactions in, so only the
        // first reading is allowed to answer 0.
        guard try await chainHasTip(rpc: rpc) else {
            throw CtlError("\(address): the chain has no readable tip yet; retry once it is active")
        }
        return 0
    }
    guard http.statusCode == 200 else {
        throw CtlError("account lookup failed: HTTP \(http.statusCode)")
    }
    return try JSONDecoder().decode(ExplorerAccount.self, from: data).nonce
}

func chainHasTip(rpc: UInt16) async throws -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(rpc)/health") else {
        throw CtlError("bad RPC URL")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    // These reads decide which nonce to sign. The node marks them
    // `max-age=3`, and URLSession.shared keeps a shared on-disk cache, so two
    // commands run back to back would otherwise both read the same seconds-old
    // pool and account — the exact window in which the second must see the
    // first.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          let status = try JSONSerialization.jsonObject(with: data)
              as? [String: Any] else {
        throw CtlError("status lookup failed")
    }
    return status["tipCID"] as? String != nil
}

/// The highest nonce this signer already has pending, or nil for none. The
/// pool listing is capped by the node, so this can only ever miss entries
/// beyond that cap — in which case the submit is refused rather than
/// silently replacing, which is the safe direction.
func highestPendingNonce(rpc: UInt16, signer: String) async throws -> UInt64? {
    guard let url = URL(string: "http://127.0.0.1:\(rpc)/api/mempool") else {
        throw CtlError("bad RPC URL")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    // These reads decide which nonce to sign. The node marks them
    // `max-age=3`, and URLSession.shared keeps a shared on-disk cache, so two
    // commands run back to back would otherwise both read the same seconds-old
    // pool and account — the exact window in which the second must see the
    // first.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw CtlError("mempool lookup failed")
    }
    let pool = try JSONDecoder().decode(ExplorerMempool.self, from: data)
    var highest: UInt64?
    for cid in pool.transactions {
        guard let entry = try await pooledTransaction(rpc: rpc, cid: cid),
              entry.signers.contains(signer) else { continue }
        highest = max(highest ?? entry.nonce, entry.nonce)
    }
    return highest
}

/// One pooled transaction, or nil when it left the pool between the listing
/// and this read — a race that is ordinary, not an error.
func pooledTransaction(
    rpc: UInt16, cid: String
) async throws -> ExplorerTransaction? {
    guard let url = URL(
        string: "http://127.0.0.1:\(rpc)/api/transaction/\(cid)"
    ) else { throw CtlError("bad RPC URL") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    // These reads decide which nonce to sign. The node marks them
    // `max-age=3`, and URLSession.shared keeps a shared on-disk cache, so two
    // commands run back to back would otherwise both read the same seconds-old
    // pool and account — the exact window in which the second must see the
    // first.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    return try? JSONDecoder().decode(ExplorerTransaction.self, from: data)
}

func requireAddress(_ address: String, _ flag: String) throws {
    guard CryptoUtils.isValidAddress(address) else {
        throw CtlError("\(flag) is not a Lattice address: \(address)")
    }
}

/// Amounts are unsigned on the wire and signed as account deltas.
func amountDelta(_ amount: UInt64) throws -> Int64 {
    guard amount > 0, amount <= UInt64(Int64.max) else {
        throw CtlError("amount must be between 1 and \(Int64.max)")
    }
    return Int64(amount)
}
