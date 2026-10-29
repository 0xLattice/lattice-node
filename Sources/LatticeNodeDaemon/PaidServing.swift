import Hummingbird
import Lattice
import LatticeNode

/// The operator's terms for paid serving and the balances they credit: what
/// the public read port's `/serving-terms` and `/serving-prepay` answer from.
struct ServingPayments: Sendable {
    let terms: PaidServing
    let ledger: ServingLedger
}

/// `POST /serving-prepay`: a payment to the operator's `payTo`, claimed for
/// one peer by a signer of the paying transaction.
struct ServingPrepayRequest: Codable, Sendable {
    let chain: String
    let txCID: String
    let peer: String
    /// One of the transaction's signers, as its body lists them (an address).
    let signer: String
    /// The signer's signature over `servingPrepayMessage`, in hex.
    let signature: String
}

struct ServingPrepayResponse: Codable, Sendable {
    let peer: String
    let credited: Int
    let balance: Int
}

/// `POST /serving-balance`: bytes the operator credits a peer (work its
/// sponsor was paid in, say).
struct ServingBalanceRequest: Codable, Sendable {
    let peer: String
    let bytes: Int
}

struct ServingBalanceResponse: Codable, Sendable {
    let peer: String
    let balance: Int
}

/// What a prepay's signer signs, with the scheme Lattice signs transactions
/// with (`CryptoUtils.sign`): it binds the payment to one chain and one peer.
func servingPrepayMessage(chain: String, txCID: String, peer: String) -> String {
    "lattice-serving-prepay:v1:\(chain):\(txCID):\(peer)"
}

/// Credits a payment once it is `terms.depth` deep in this node's canonical
/// chain: what it pays `payTo`, net, times the chain's rate. Each refusal is
/// named.
func creditPrepay(
    _ input: ServingPrepayRequest, payments: ServingPayments, reads byPath: ChainReadsByPath
) async throws -> ServingPrepayResponse {
    let terms = payments.terms
    guard let address = ChainAddress(string: input.chain) else {
        throw HTTPError(.badRequest, message: "invalidChainPath")
    }
    guard let payTo = terms.payTo, let rate = terms.rates[address.components] else {
        throw HTTPError(.badRequest, message: "unpricedChain")
    }
    guard isPlausibleCID(input.txCID) else { throw HTTPError(.badRequest, message: "invalidCID") }
    guard ServingLedger.isPeer(input.peer) else { throw HTTPError(.badRequest, message: "invalidPeer") }
    guard let reads = byPath.service(for: address.components) else {
        throw HTTPError(.notFound, message: "unknownChain")
    }
    guard let found = await reads.canonicalTransaction(cid: input.txCID) else {
        throw HTTPError(.notFound, message: "notIncluded")
    }
    // Retryable: the same request succeeds once the chain grows.
    guard found.depth >= terms.depth else { throw HTTPError(.tooEarly, message: "notDeepEnough") }
    guard found.body.signers.contains(input.signer),
          let key = found.transaction.signatures.keys.first(where: { CryptoUtils.createAddress(from: $0) == input.signer })
    else {
        throw HTTPError(.badRequest, message: "notSigner")
    }
    let message = servingPrepayMessage(chain: input.chain, txCID: input.txCID, peer: input.peer)
    guard CryptoUtils.verify(message: message, signature: input.signature, publicKeyHex: key) else {
        throw HTTPError(.badRequest, message: "invalidSignature")
    }
    var amount: Int64 = 0
    for action in found.body.accountActions where action.owner == payTo {
        let (sum, overflow) = amount.addingReportingOverflow(action.delta)
        guard !overflow else { throw HTTPError(.badRequest, message: "noPayment") }
        amount = sum
    }
    guard amount > 0 else { throw HTTPError(.badRequest, message: "noPayment") }
    let (product, overflow) = Int(amount).multipliedReportingOverflow(by: rate)
    let bytes = overflow ? Int.max : product
    let balance = try await payments.ledger.credit(peer: input.peer, bytes: bytes, payment: input.txCID)
    return ServingPrepayResponse(peer: input.peer, credited: bytes, balance: balance)
}
