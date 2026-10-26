// Work-for-fee sponsorship: a client grinds shares of the sponsor's block
// template, and the sponsor co-signs the client's transaction, paying its fee
// from its own account. Nothing here is consensus. The share is real block
// work (a share that clears the block target is a block paying the sponsor),
// so the fee is bought at its expected value. A chain's block at target T
// paying R prices its smallest unit at workForTarget(T) / R work, so a share
// at target S is worth R * workForTarget(S) / workForTarget(T) units there.
//
// A share is a ticket on the blocks of the one template it was ground on, so
// it is valued when it is credited, at that template's price, on the one
// chain its client named: the client earns on that chain alone. The template
// is merged and pays the sponsor on every chain it carries; the share's worth
// on the others, and the template's fees, are the sponsor's.

import Foundation
import Lattice
import LatticeMinerCore
import UInt256

/// What one chain's block in a template pays a share: the target a hash
/// must clear to make it (the block's committed target, or the template's
/// search target where that is harder, since the node takes no hash above
/// it), the block's height, and its reward, R(h).
public struct ChainPrice: Sendable, Equatable {
    public let target: UInt256
    public let height: UInt64
    public let reward: UInt64

    public init(target: UInt256, height: UInt64, reward: UInt64) {
        self.target = target
        self.height = height
        self.reward = reward
    }
}

/// One node template, as the sponsor hands it out.
public struct SponsorTemplate: Sendable, Equatable {
    public let workID: String
    /// Consensus PoW preimage prefix (hex): what a client hashes with a nonce.
    public let prefixHex: String
    /// Each chain whose block the template carries and pays the sponsor, by
    /// absolute path.
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
    /// The chain the client's shares are credited on, and the height of
    /// its block in this template.
    public let chainPath: [String]
    public let height: UInt64
    public let workID: String
    public let prefixHex: String
    public let shareTarget: UInt256
    /// What one share is worth on `chainPath` at this template's price, in
    /// units scaled by 2^64 (`SponsorLedger.unit`).
    public let shareValue: UInt256
    /// The block's whole reward, scaled the same way: the most credit its
    /// height can back.
    public let blockValue: UInt256
    public let startNonce: UInt64
    public let count: UInt64
    public let expiresAt: Int64
}

public struct ShareCredit: Sendable, Equatable {
    /// The client's credit on the assignment's chain after this share, in
    /// units scaled by 2^64.
    public let credit: UInt256
    /// The template to submit the nonce to as a block, when it clears one.
    public let blockWorkID: String?
}

public enum SponsorRefusal: Error, Sendable, Equatable {
    case unknownAssignment
    /// The template expired, or the chain has moved past the block it
    /// carries: the work can no longer win it.
    case expired
    case outsideRange
    case duplicateShare
    case missesShareTarget
    /// Too many live assignments; retry once some expire.
    case busy
    /// Credit backed by the chain's block at this height has reached its
    /// reward; retry once the chain moves on.
    case soldOut
    /// The client's credit on the fee's chain does not cover the fee yet.
    case insufficientCredit
    /// The sponsor's balance, less the fees it already signed, does not
    /// cover this fee.
    case insufficientFloat
    /// No price for a share on the chain: the newest template does not
    /// carry a block paying the sponsor there, its emission has ended, or
    /// there is no live template.
    case unpriceable
    /// The draft is not one the sponsor signs; the reason names why.
    case draft(String)
}

public struct SponsorLedger: Sendable {
    /// Credit is kept in units of a chain's currency scaled by 2^64, since a
    /// share is usually a small fraction of one unit.
    public static let unit = UInt256(1) << 64

    public let shareTarget: UInt256
    public let rangeSize: UInt64
    public let maxAssignments: Int
    /// How long a client's credit outlives its last share.
    public let creditLifetime: Int64

    private var templates: [String: SponsorTemplate] = [:]
    private var nextStart: [String: UInt64] = [:]
    private var assignments: [String: ShareAssignment] = [:]
    private var shares: Set<ShareKey> = []
    private var credits: [CreditKey: (value: UInt256, lastShare: Int64)] = [:]
    private var sold: [BlockKey: UInt256] = [:]
    private var commitments: [(chainPath: [String], fee: UInt64, until: Int64)] = []
    private var lastID: UInt64 = 0

    private struct ShareKey: Hashable {
        let workID: String
        let nonce: UInt64
    }

    private struct CreditKey: Hashable {
        let client: String
        let chainPath: [String]
    }

    private struct BlockKey: Hashable {
        let chainPath: [String]
        let height: UInt64
    }

    public init(
        shareTarget: UInt256,
        rangeSize: UInt64 = 1 << 32,
        maxAssignments: Int = 100_000,
        creditLifetime: Int64 = 3_600_000
    ) {
        precondition(shareTarget > .zero && rangeSize > 0 && maxAssignments > 0)
        self.shareTarget = shareTarget
        self.rangeSize = rangeSize
        self.maxAssignments = maxAssignments
        self.creditLifetime = creditLifetime
    }

    /// The newest template, the one new work is handed out from.
    public private(set) var latest: SponsorTemplate?

    /// Take `template` as the newest work, and drop what has expired: this
    /// runs on the sponsor's refresh, so requests never pay for the sweep.
    public mutating func install(_ template: SponsorTemplate, now: Int64) {
        if templates[template.workID] == nil {
            templates[template.workID] = template
        }
        latest = template
        prune(now: now)
    }

    /// A fresh nonce range of the newest template for `client`, its shares
    /// credited on `chainPath` at this template's price.
    public mutating func assign(client: String, on chainPath: [String], now: Int64) throws -> ShareAssignment {
        guard let template = latest, now < template.expiresAt,
              let price = template.prices[chainPath],
              let value = Self.shareValue(shareTarget: shareTarget, at: price), value > .zero else {
            throw SponsorRefusal.unpriceable
        }
        let blockValue = UInt256(price.reward) * Self.unit
        guard sold[BlockKey(chainPath: chainPath, height: price.height)] ?? .zero < blockValue else {
            throw SponsorRefusal.soldOut
        }
        guard assignments.count < maxAssignments else { throw SponsorRefusal.busy }
        let start = nextStart[template.workID] ?? 0
        let (end, overflow) = start.addingReportingOverflow(rangeSize)
        guard !overflow else { throw SponsorRefusal.busy }
        nextStart[template.workID] = end
        lastID &+= 1
        let assignment = ShareAssignment(
            id: "\(template.workID).\(lastID)",
            client: client,
            chainPath: chainPath,
            height: price.height,
            workID: template.workID,
            prefixHex: template.prefixHex,
            shareTarget: shareTarget,
            shareValue: value,
            blockValue: blockValue,
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
    ///
    /// Only one block per height can be the chain's, so the credit a height
    /// backs, across every template and client, stops at its block's
    /// reward: past that, more work at the height earns the sponsor nothing.
    public mutating func credit(
        assignment id: String,
        nonce: UInt64,
        hash: UInt256,
        now: Int64
    ) throws -> ShareCredit {
        guard let assignment = assignments[id], let template = templates[assignment.workID] else {
            throw SponsorRefusal.unknownAssignment
        }
        guard now < assignment.expiresAt,
              (liveHeight(of: assignment.chainPath) ?? assignment.height) <= assignment.height else {
            throw SponsorRefusal.expired
        }
        guard nonce >= assignment.startNonce, nonce - assignment.startNonce < assignment.count else {
            throw SponsorRefusal.outsideRange
        }
        guard hash <= assignment.shareTarget else { throw SponsorRefusal.missesShareTarget }
        guard shares.insert(ShareKey(workID: assignment.workID, nonce: nonce)).inserted else {
            throw SponsorRefusal.duplicateShare
        }
        let block = BlockKey(chainPath: assignment.chainPath, height: assignment.height)
        let backed = sold[block] ?? .zero
        guard backed < assignment.blockValue else { throw SponsorRefusal.soldOut }
        let value = min(assignment.shareValue, assignment.blockValue - backed)
        sold[block] = backed + value
        let key = CreditKey(client: assignment.client, chainPath: assignment.chainPath)
        let (sum, overflow) = (credits[key]?.value ?? .zero).addingReportingOverflow(value)
        let credit = overflow ? UInt256.max : sum
        credits[key] = (credit, now)
        return ShareCredit(
            credit: credit,
            blockWorkID: hash <= template.submitTarget ? template.workID : nil
        )
    }

    /// The highest height of `chainPath`'s block in any live template. An
    /// assignment's own template is live while it is, so one refresh that
    /// leaves the chain out cannot hide that it moved on.
    private func liveHeight(of chainPath: [String]) -> UInt64? {
        templates.values.compactMap { $0.prices[chainPath]?.height }.max()
    }

    public func assignment(_ id: String) -> ShareAssignment? {
        assignments[id]
    }

    /// `client`'s credit on `chainPath`, in units scaled by 2^64.
    public func credit(of client: String, on chainPath: [String]) -> UInt256 {
        credits[CreditKey(client: client, chainPath: chainPath)]?.value ?? .zero
    }

    /// What one share at `shareTarget` is worth on a chain at `price`, in
    /// units scaled by 2^64: `R * workForTarget(S) / workForTarget(T)`,
    /// rounded down. Nil when that overflows.
    public static func shareValue(shareTarget: UInt256, at price: ChainPrice) -> UInt256? {
        let (scaled, overflow) = UInt256(price.reward).multipliedReportingOverflow(by: unit)
        guard !overflow else { return nil }
        let (product, overflowed) = scaled.multipliedReportingOverflow(by: workForTarget(shareTarget))
        guard !overflowed else { return nil }
        return product / workForTarget(price.target)
    }

    /// How many shares of the newest template buy `fee` on `chainPath`.
    public func sharesFor(fee: UInt64, on chainPath: [String]) -> UInt256? {
        guard let price = latest?.prices[chainPath],
              let value = Self.shareValue(shareTarget: shareTarget, at: price), value > .zero else {
            return nil
        }
        let (quotient, remainder) = (UInt256(fee) * Self.unit).quotientAndRemainder(dividingBy: value)
        return remainder == .zero ? quotient : quotient + UInt256(1)
    }

    /// Spend `fee` of `client`'s credit on `chainPath` and hold the fee
    /// against the sponsor's `balance` there until `holdUntil`: a signed fee
    /// not yet mined does not show in the balance. The caller signs only
    /// after this returns.
    public mutating func commit(
        client: String, fee: UInt64, on chainPath: [String], balance: UInt64, holdUntil: Int64, now: Int64
    ) throws {
        let key = CreditKey(client: client, chainPath: chainPath)
        let cost = UInt256(fee) * Self.unit
        guard let held = credits[key], held.value >= cost else { throw SponsorRefusal.insufficientCredit }
        var committed = UInt256(fee)
        for commitment in commitments where commitment.chainPath == chainPath && commitment.until > now {
            committed = committed + UInt256(commitment.fee)
        }
        guard committed <= UInt256(balance) else { throw SponsorRefusal.insufficientFloat }
        credits[key] = (held.value - cost, held.lastShare)
        commitments.append((chainPath, fee, holdUntil))
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
        // A height's backing is dropped only once a live template carries the
        // chain higher: a chain missing from every live template keeps it, so
        // the same height cannot back its reward twice.
        sold = sold.filter { key, _ in liveHeight(of: key.chainPath).map { key.height >= $0 } ?? true }
        credits = credits.filter { now - $0.value.lastShare < creditLifetime && $0.value.value > .zero }
        commitments.removeAll { now >= $0.until }
    }
}

/// The body the sponsor signs for `draft`: the draft as written plus one
/// debit of `fee` from `sponsor`, with the sponsor appended as a co-signer.
///
/// A co-signature authorizes everything the body does, so the draft may not
/// name the sponsor as an account, a demander or a withdrawer, or inside an
/// action's key or values, and must balance without the sponsor, so the
/// sponsor's debit can only ever be the fee. A chain's policies may still
/// read the signer list, which no check here can bound: the sponsor's key
/// must hold its fee float and nothing else. The client stays first signer:
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
    let mentioned = draft.actions.contains {
        [$0.key, $0.oldValue, $0.newValue].contains { $0?.contains(sponsor) == true }
    }
    guard !named.contains(sponsor), !mentioned else {
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
