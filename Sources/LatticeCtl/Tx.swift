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
        let file = try JSONDecoder().decode(
            KeyFile.self, from: Data(contentsOf: URL(fileURLWithPath: key))
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
            signerNonce = try await nextExpectedNonce(
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

/// The chain's own view of the key's next nonce, as of its tip. A key that
/// never transacted is absent from state and starts at 0.
func nextExpectedNonce(rpc: UInt16, address: String) async throws -> UInt64 {
    guard let url = URL(
        string: "http://127.0.0.1:\(rpc)/api/state/account/\(address)"
    ) else { throw CtlError("bad RPC URL") }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw CtlError("account lookup failed")
    }
    if http.statusCode == 404 { return 0 }
    guard http.statusCode == 200 else {
        throw CtlError("account lookup failed: HTTP \(http.statusCode)")
    }
    return try JSONDecoder().decode(ExplorerAccount.self, from: data).nonce
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
