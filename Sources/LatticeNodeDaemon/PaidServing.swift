/// `POST /serving-credit`: bytes the operator credits a peer's standing
/// (work its sponsor was paid in, say).
struct ServingCreditRequest: Codable, Sendable {
    let peer: String
    let bytes: Int
}

struct ServingCreditResponse: Codable, Sendable {
    let peer: String
    let standing: Int
}
