// Work-for-fee sponsorship: a client grinds shares of the sponsor's block
// template, and the sponsor co-signs the client's transaction, paying its fee
// from its own account. Nothing here is consensus. The share is real block
// work (a share that clears the block target is a block paying the sponsor),
// so the fee is bought at its expected value: a share at target S is worth
// R * workForTarget(S) / workForTarget(T), for a block at target T paying R.
//
// The template is merged: one share is a ticket on every chain's block in it,
// each paying the sponsor. Credit is therefore kept in work, which is the same
// on every chain, and spent on one chain's fee at that chain's price. The
// share's worth on every other chain, and the template's fees, are left out
// of the price, so it errs toward the sponsor.

import Foundation
import Lattice
import LatticeMinerCore
import UInt256

/// What one chain's block in a template pays a share: its committed target
/// and its reward, R(h) at its height.
public struct ChainPrice: Sendable, Equatable {
    public let target: UInt256
    public let reward: UInt64

    public init(target: UInt256, reward: UInt64) {
        self.target = target
        self.reward = reward
    }
}

/// One node template, as the sponsor hands it out.
public struct SponsorTemplate: Sendable, Equatable {
    public let workID: String
    /// Consensus PoW preimage prefix (hex): what a client hashes with a nonce.
    public let prefixHex: String
    /// Each chain whose block the template carries, by absolute path.
    public let prices: [[String]: ChainPrice]
    /// The easiest target any block in this work clears (merged children
    /// included). A share at or under it goes to the node as a block.
    public let submitTarget: UInt256
    /// Milliseconds since the epoch.
    public let expiresAt: Int64

    public init(
        workID: String,
        prefixHex: String,
        prices: [[String]: ChainPrice],
        submitTarget: UInt256,
        expiresAt: Int64
    ) {
        self.workID = workID
        self.prefixHex = prefixHex
        self.prices = prices
        self.submitTarget = submitTarget
        self.expiresAt = expiresAt
    }
}

/// A disjoint nonce range of one template, held by one client. Shares are
/// credited only inside it, so a client cannot claim another's work.
public struct ShareAssignment: Sendable, Equatable {
    public let id: String
    public let client: String
    public let workID: String
    public let prefixHex: String
    public let shareTarget: UInt256
    public let startNonce: UInt64
    public let count: UInt64
    public let expiresAt: Int64
}

public struct ShareCredit: Sendable, Equatable {
    /// The client's credit after this share, in work.
    public let credit: UInt256
    /// The template to submit the nonce to as a block, when it clears one.
    public let blockWorkID: String?
}

public enum SponsorRefusal: Error, Sendable, Equatable {
    case unknownAssignment
    case expired
    case outsideRange
    case duplicateShare
    case missesShareTarget
    /// Too many live assignments; retry once some expire.
    case busy
    /// The client's credit does not cover the fee yet.
    case insufficientCredit
    /// The sponsor's balance, less the fees it already signed, does not
    /// cover this fee.
    case insufficientFloat
    /// No reward to price work against on the chain (its emission has
    /// ended, or the newest template does not carry its block), or no
    /// template yet.
    case unpriceable
    /// The draft is not one the sponsor signs; the reason names why.
    case draft(String)
}

public struct SponsorLedger: Sendable {
    public let shareTarget: UInt256
    public let rangeSize: UInt64
    public let maxAssignments: Int
    /// How long a client's credit outlives its last share.
    public let creditLifetime: Int64
    /// How long a signed fee counts against the float. The account balance
    /// the float is read from already shows a mined fee, so holding a fee
    /// past its block only refuses early, never overspends.
    public let commitmentLifetime: Int64

    private var templates: [String: SponsorTemplate] = [:]
    private var nextStart: [String: UInt64] = [:]
    private var assignments: [String: ShareAssignment] = [:]
    private var shares: Set<ShareKey> = []
    private var credits: [String: (work: UInt256, lastShare: Int64)] = [:]
    private var commitments: [(chainPath: [String], fee: UInt64, until: Int64)] = []
    private var lastID: UInt64 = 0

    private struct ShareKey: Hashable {
        let workID: String
        let nonce: UInt64
    }

    public init(
        shareTarget: UInt256,
        rangeSize: UInt64 = 1 << 32,
        maxAssignments: Int = 100_000,
        creditLifetime: Int64 = 3_600_000,
        commitmentLifetime: Int64 = 600_000
    ) {
        precondition(shareTarget > .zero && rangeSize > 0 && maxAssignments > 0)
        self.shareTarget = shareTarget
        self.rangeSize = rangeSize
        self.maxAssignments = maxAssignments
        self.creditLifetime = creditLifetime
        self.commitmentLifetime = commitmentLifetime
    }

    /// The newest live template, the one fees are priced against.
    public private(set) var latest: SponsorTemplate?

    public mutating func install(_ template: SponsorTemplate) {
        if templates[template.workID] == nil {
            templates[template.workID] = template
        }
        latest = template
    }

    /// A fresh nonce range of the newest template for `client`.
    public mutating func assign(client: String, now: Int64) throws -> ShareAssignment {
        prune(now: now)
        guard let template = latest, now < template.expiresAt else { throw SponsorRefusal.unpriceable }
        guard assignments.count < maxAssignments else { throw SponsorRefusal.busy }
        let start = nextStart[template.workID] ?? 0
        let (end, overflow) = start.addingReportingOverflow(rangeSize)
        guard !overflow else { throw SponsorRefusal.busy }
        nextStart[template.workID] = end
        lastID &+= 1
        let assignment = ShareAssignment(
            id: "\(template.workID).\(lastID)",
            client: client,
            workID: template.workID,
            prefixHex: template.prefixHex,
            shareTarget: shareTarget,
            startNonce: start,
            count: rangeSize,
            expiresAt: template.expiresAt
        )
        assignments[assignment.id] = assignment
        return assignment
    }

    /// Credit one share: `nonce` inside the assignment's range whose hash
    /// clears the share target. `hash` is the template's PoW hash at `nonce`
    /// (`ProofOfWork.hash`), computed by the caller from the prefix.
    public mutating func credit(
        assignment id: String,
        nonce: UInt64,
        hash: UInt256,
        now: Int64
    ) throws -> ShareCredit {
        guard let assignment = assignments[id], let template = templates[assignment.workID] else {
            throw SponsorRefusal.unknownAssignment
        }
        guard now < assignment.expiresAt else { throw SponsorRefusal.expired }
        guard nonce >= assignment.startNonce, nonce - assignment.startNonce < assignment.count else {
            throw SponsorRefusal.outsideRange
        }
        guard hash <= assignment.shareTarget else { throw SponsorRefusal.missesShareTarget }
        guard shares.insert(ShareKey(workID: assignment.workID, nonce: nonce)).inserted else {
            throw SponsorRefusal.duplicateShare
        }
        let previous = credits[assignment.client]?.work ?? .zero
        let (sum, overflow) = previous.addingReportingOverflow(workForTarget(assignment.shareTarget))
        let work = overflow ? UInt256.max : sum
        credits[assignment.client] = (work, now)
        return ShareCredit(
            credit: work,
            blockWorkID: hash <= template.submitTarget ? template.workID : nil
        )
    }

    public func assignment(_ id: String) -> ShareAssignment? {
        assignments[id]
    }

    public func credit(of client: String) -> UInt256 {
        credits[client]?.work ?? .zero
    }

    /// The work that buys `fee` on a chain at `price`: the fee's share of the
    /// chain's block's expected work, `ceil(fee * workForTarget(T) / R)`. Nil
    /// when it cannot be priced (no reward) or exceeds any credit.
    public static func cost(fee: UInt64, at price: ChainPrice) -> UInt256? {
        guard price.reward > 0 else { return nil }
        let (product, overflow) = UInt256(fee).multipliedReportingOverflow(by: workForTarget(price.target))
        guard !overflow else { return nil }
        let reward = UInt256(price.reward)
        let (quotient, remainder) = product.quotientAndRemainder(dividingBy: reward)
        return remainder == .zero ? quotient : quotient + UInt256(1)
    }

    /// The work that buys `fee` on `chainPath` at the newest template's price.
    public func cost(fee: UInt64, on chainPath: [String]) -> UInt256? {
        guard let price = latest?.prices[chainPath] else { return nil }
        return Self.cost(fee: fee, at: price)
    }

    /// How many shares buy `fee` on `chainPath` at the newest template's price.
    public func sharesFor(fee: UInt64, on chainPath: [String]) -> UInt256? {
        guard let cost = cost(fee: fee, on: chainPath) else { return nil }
        let (quotient, remainder) = cost.quotientAndRemainder(dividingBy: workForTarget(shareTarget))
        return remainder == .zero ? quotient : quotient + UInt256(1)
    }

    /// Spend `client`'s credit on `fee` on `chainPath` and hold the fee
    /// against the sponsor's `balance` there. The caller signs only after
    /// this returns.
    public mutating func commit(
        client: String, fee: UInt64, on chainPath: [String], balance: UInt64, now: Int64
    ) throws {
        prune(now: now)
        guard let cost = cost(fee: fee, on: chainPath) else { throw SponsorRefusal.unpriceable }
        guard let held = credits[client], held.work >= cost else { throw SponsorRefusal.insufficientCredit }
        var committed = UInt256(fee)
        for commitment in commitments where commitment.chainPath == chainPath {
            committed = committed + UInt256(commitment.fee)
        }
        guard committed <= UInt256(balance) else { throw SponsorRefusal.insufficientFloat }
        credits[client] = (held.work - cost, held.lastShare)
        commitments.append((chainPath, fee, now + commitmentLifetime))
    }

    private mutating func prune(now: Int64) {
        let expired = templates.values.filter { now >= $0.expiresAt }.map(\.workID)
        if !expired.isEmpty {
            let gone = Set(expired)
            for workID in gone {
                templates.removeValue(forKey: workID)
                nextStart.removeValue(forKey: workID)
            }
            assignments = assignments.filter { !gone.contains($0.value.workID) }
            shares = shares.filter { !gone.contains($0.workID) }
        }
        credits = credits.filter { now - $0.value.lastShare < creditLifetime && $0.value.work > .zero }
        commitments.removeAll { now >= $0.until }
    }
}

/// The body the sponsor signs for `draft`: the draft as written plus one
/// debit of `fee` from `sponsor`, with the sponsor appended as a co-signer.
///
/// A co-signature authorizes everything the body does, so the draft may not
/// name the sponsor anywhere — not as an account, a demander, a withdrawer,
/// or inside an action key — and must balance without the sponsor, so the
/// sponsor's debit can only ever be the fee. The client stays first signer:
/// only the first signer's nonce is consensus, so the sponsor's own nonce is
/// never consumed and it can co-sign any number of drafts at once.
public func sponsoredBody(
    draft: TransactionBody,
    sponsor: String,
    fee: UInt64,
    chainPath: [String]
) throws -> TransactionBody {
    guard fee > 0, fee <= UInt64(Int64.max) else { throw SponsorRefusal.draft("fee out of range") }
    guard draft.chainPath == chainPath else { throw SponsorRefusal.draft("wrong chain") }
    guard draft.signers.count == 1, let client = draft.signers.first, client != sponsor else {
        throw SponsorRefusal.draft("the draft must have exactly one signer, not the sponsor")
    }
    let named = draft.accountActions.map(\.owner)
        + draft.depositActions.map(\.demander)
        + draft.receiptActions.flatMap { [$0.withdrawer, $0.demander] }
        + draft.withdrawalActions.flatMap { [$0.withdrawer, $0.demander] }
    guard !named.contains(sponsor), !draft.actions.contains(where: { $0.key.contains(sponsor) }) else {
        throw SponsorRefusal.draft("the draft names the sponsor")
    }
    guard draft.minerSurplus() != nil else {
        throw SponsorRefusal.draft("the draft creates value")
    }
    return TransactionBody(
        accountActions: draft.accountActions + [AccountAction(owner: sponsor, delta: -Int64(fee))],
        actions: draft.actions,
        depositActions: draft.depositActions,
        receiptActions: draft.receiptActions,
        withdrawalActions: draft.withdrawalActions,
        signers: [client, sponsor],
        nonce: draft.nonce,
        chainPath: draft.chainPath
    )
}
