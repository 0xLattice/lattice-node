import Lattice

/// Transport-independent meaning of one chain-local admission attempt.
public enum NodeImportDecision: Sendable, Equatable {
    case canonicalized(ChainCommit)
    case acceptedSide(ChainCommit)
    case duplicate
    case unavailable(CrossChainEvidenceRequirement?)
    case temporarilyInvalid
    /// The header proves no work the chain accepts (Lattice
    /// `.proofOfWorkInvalid`): the one refusal that blames its sender.
    case proofOfWorkInvalid
    /// Refused for a reason that blames no one.
    case invalid
    case localFailure

    init(_ result: BlockImportResult) {
        switch result {
        case .accepted(let acceptance):
            self = acceptance.commit.canonicalChanged
                ? .canonicalized(acceptance.commit)
                : .acceptedSide(acceptance.commit)
        case .duplicate(_, let promotedCommit):
            if let promotedCommit, promotedCommit.canonicalChanged {
                self = .canonicalized(promotedCommit)
            } else {
                self = .duplicate
            }
        case .rejected(let failure, _):
            self.init(failure)
        }
    }

    init(_ failure: BlockImportError) {
        switch failure {
        case .unavailableEvidence:
            self = .unavailable(nil)
        case .crossChainEvidenceRequired(let requirement):
            self = .unavailable(requirement)
        case .notYetValid:
            self = .temporarilyInvalid
        case .proofOfWorkInvalid:
            self = .proofOfWorkInvalid
        case .providerMalformedEvidence, .protocolInvalid,
             .notAcceptedAtCurrentChain:
            self = .invalid
        case .localVerificationFailure, .revisionExhausted:
            self = .localFailure
        }
    }

    public var isAccepted: Bool {
        switch self {
        case .canonicalized, .acceptedSide, .duplicate: true
        default: false
        }
    }

    public var shouldPublishCanonicalTip: Bool {
        if case .canonicalized = self { return true }
        return false
    }

    public var shouldRetryWhenEvidenceChanges: Bool {
        if case .unavailable = self { return true }
        return false
    }

    public var shouldRetryLater: Bool { self == .temporarilyInvalid }
}
