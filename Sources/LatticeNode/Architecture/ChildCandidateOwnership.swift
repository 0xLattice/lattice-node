import Lattice

/// One atomic ownership transition for child candidates. A committed handoff
/// always wins over speculative reservations from other outstanding templates.
struct ChildCandidateOwnership {
    let reservations: [ChildCandidateReservationReference]
    let handoffs: [ChildCandidateReservationReference]

    init(
        candidates: [DirectChildCandidate],
        handoffs: [ChildCandidateReservationReference]
    ) throws {
        let handoffs = Set(handoffs)
        let candidateReferences = try Set(
            candidates.compactMap {
                candidate -> ChildCandidateReservationReference? in
                guard let peerKey = candidate.advertiserPeerKey else {
                    return nil
                }
                return ChildCandidateReservationReference(
                    peerKey: peerKey,
                    candidateCID: try BlockHeader(node: candidate.block).rawCID
                )
            }
        )
        self.handoffs = Self.sorted(handoffs)
        reservations = Self.sorted(candidateReferences.subtracting(handoffs))
    }

    var update: ChildCandidateReservationUpdate {
        ChildCandidateReservationUpdate(
            reservations: reservations,
            handoffs: handoffs
        )
    }

    private static func sorted(
        _ references: Set<ChildCandidateReservationReference>
    ) -> [ChildCandidateReservationReference] {
        references.sorted {
            ($0.peerKey.description, $0.candidateCID)
                < ($1.peerKey.description, $1.candidateCID)
        }
    }
}
