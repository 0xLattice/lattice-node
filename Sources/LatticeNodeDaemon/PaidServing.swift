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
