import Lattice

/// Transport-independent meaning of one chain-local admission attempt.
public enum NodeAdmissionDecision: Sendable, Equatable {
    case canonicalized(ChainCommit)
    case acceptedSide(ChainCommit)
    case carrier
    case duplicate
    case unavailable(CrossChainEvidenceRequirement?)
    case temporarilyInvalid
    case invalid
    case localFailure

    init(_ result: ChainLocalBlockResult) {
        switch result {
        case .accepted(let acceptance):
            self = acceptance.commit.canonicalChanged
                ? .canonicalized(acceptance.commit)
                : .acceptedSide(acceptance.commit)
        case .carrier:
            self = .carrier
        case .duplicate:
            self = .duplicate
        case .rejected(let failure, _, _):
            self.init(failure)
        }
    }

    init(_ failure: ChainAdmissionFailure) {
        switch failure {
        case .unavailableEvidence:
            self = .unavailable(nil)
        case .crossChainEvidenceRequired(let requirement):
            self = .unavailable(requirement)
        case .notYetAdmissible:
            self = .temporarilyInvalid
        case .notAcceptedAtCurrentChain:
            self = .carrier
        case .providerMalformedEvidence, .protocolInvalid:
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
