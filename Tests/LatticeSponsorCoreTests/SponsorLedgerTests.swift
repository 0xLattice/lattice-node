import Foundation
import XCTest
import Lattice
import UInt256
import cashew
import LatticeMinerCore
@testable import LatticeSponsorCore

/// `2^k - 1`: its work, `floor(2^256 / (target + 1))`, is exactly 2^(256-k).
private func target(_ k: Int) -> UInt256 { (UInt256(1) << k) - UInt256(1) }

private let sponsor = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)

private let nexus = ["Nexus"]
private let market = ["Nexus", "Market"]

/// Nexus's block at 2^200 - 1 paying 1,000, and Market's, 2^4 easier,
/// paying `marketReward`.
private func template(
    workID: String = "w1",
    marketReward: UInt64? = 10,
    marketHeight: UInt64 = 7,
    expiresAt: Int64 = 30_000
) -> SponsorTemplate {
    var prices = [nexus: ChainPrice(target: target(200), height: 3, reward: 1_000)]
    if let marketReward {
        prices[market] = ChainPrice(target: target(204), height: marketHeight, reward: marketReward)
    }
    return SponsorTemplate(
        workID: workID,
        prefixHex: "00",
        prices: prices,
        submitTarget: target(204),
        expiresAt: expiresAt
    )
}

/// `units` whole units of a chain's currency, as credit is kept.
private func units(_ units: UInt64) -> UInt256 { UInt256(units) * SponsorLedger.unit }

private func draft(
    signer: String,
    accountActions: [AccountAction] = [],
    actions: [Action] = [],
    chainPath: [String] = ["Nexus"]
) -> TransactionBody {
    TransactionBody(
        accountActions: accountActions,
        actions: actions,
        depositActions: [],
        receiptActions: [],
        withdrawalActions: [],
        signers: [signer],
        nonce: 0,
        chainPath: chainPath
    )
}

final class SponsorLedgerTests: XCTestCase {
    /// A share target 2^8 easier than Nexus's block (a share is 1/256 of
    /// its 1,000: 1000/256 units) and 2^4 easier than Market's (1/16 of
    /// its 10: 10/16 units).
    private func ledger() -> SponsorLedger {
        var ledger = SponsorLedger(shareTarget: target(208), rangeSize: 100)
        ledger.install(template(), now: 0)
        return ledger
    }

    private let nexusShare = UInt256(1_000) << 56
    private let marketShare = UInt256(10) << 60

    func testSharesCreditOnlyInsideTheirOwnRangeOnce() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus, now: 0)
        let b = try ledger.assign(client: "b", on: nexus, now: 0)
        XCTAssertEqual(a.startNonce, 0)
        XCTAssertEqual(b.startNonce, 100, "ranges are disjoint")

        let easy = UInt256(1)
        let credited = try ledger.credit(assignment: a.id, nonce: 5, hash: easy, now: 1)
        XCTAssertEqual(credited, nexusShare)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 5, hash: easy, now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .duplicateShare)
        }
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 105, hash: easy, now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .outsideRange, "b's nonce is not a's work")
        }
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 6, hash: ledger.shareTarget + UInt256(1), now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .missesShareTarget)
        }
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 7, hash: easy, now: 30_000)) {
            XCTAssertEqual($0 as? SponsorRefusal, .expired)
        }
        XCTAssertEqual(ledger.credit(of: "b", on: nexus), .zero)
    }

    func testAShareClearingTheSubmitTargetIsABlock() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus, now: 0)
        XCTAssertNil(ledger.block(assignment: a.id, nonce: 1, hash: target(205)))
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "w1", "a Market block is a block")
        XCTAssertNil(ledger.block(assignment: a.id, nonce: 2, hash: target(203)), "a replay is never resubmitted")
    }

    /// A share refused credit is still the sponsor's block when it clears the
    /// submit target.
    func testAShareRefusedCreditIsStillABlock() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: market, now: 0)
        ledger.install(template(workID: "w2", marketHeight: 8), now: 1)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 0, hash: target(203), now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .expired)
        }
        XCTAssertEqual(ledger.block(assignment: a.id, nonce: 0, hash: target(203)), "w1")
    }

    func testAShareIsWorthItsChanceOfTheChainsBlockTimesItsReward() {
        let price = ChainPrice(target: target(200), height: 3, reward: 1_000)
        XCTAssertEqual(SponsorLedger.shareValue(shareTarget: target(200), at: price), units(1_000), "a block's work is its reward")
        XCTAssertEqual(SponsorLedger.shareValue(shareTarget: target(208), at: price), nexusShare)
        XCTAssertEqual(SponsorLedger.shareValue(shareTarget: target(208), at: ChainPrice(target: target(200), height: 3, reward: 0)), .zero)
        XCTAssertEqual(ledger().sharesFor(fee: 1_000, on: nexus), UInt256(256))
        XCTAssertEqual(ledger().sharesFor(fee: 4, on: nexus), UInt256(2), "4 of 1000/256 a share, rounded up")
        XCTAssertEqual(ledger().sharesFor(fee: 10, on: market), UInt256(16))
        XCTAssertNil(ledger().sharesFor(fee: 1, on: ["Nexus", "Absent"]), "no block in the template, no price")
    }

    /// A share is a ticket on its own template's blocks: it is credited on
    /// the chain its client named, at that template's price, and only there.
    func testCreditIsEarnedOnTheNamedChainAtTheSharesOwnTemplatesPrice() throws {
        var ledger = ledger()
        let early = try ledger.assign(client: "a", on: market, now: 0)
        for nonce in 0..<8 {
            _ = try ledger.credit(assignment: early.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        XCTAssertEqual(ledger.credit(of: "a", on: market), units(5))
        XCTAssertEqual(ledger.credit(of: "a", on: nexus), .zero, "the client earns on one chain")

        // Market's reward doubles: new work is worth twice as much there,
        // and work already done keeps the price it was done at.
        ledger.install(template(workID: "w2", marketReward: 20), now: 2)
        let late = try ledger.assign(client: "a", on: market, now: 2)
        _ = try ledger.credit(assignment: early.id, nonce: 8, hash: UInt256(1), now: 3)
        for nonce in 0..<8 {
            _ = try ledger.credit(assignment: late.id, nonce: UInt64(nonce), hash: UInt256(1), now: 3)
        }
        XCTAssertEqual(ledger.credit(of: "a", on: market), units(15) + marketShare)

        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 1, on: nexus, balance: 100, holdUntil: 600_000, now: 4)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit, "market credit pays no Nexus fee")
        }
        try ledger.commit(client: "a", fee: 15, on: market, balance: 100, holdUntil: 600_000, now: 4)
        XCTAssertEqual(ledger.credit(of: "a", on: market), marketShare)

        ledger.install(template(workID: "w3", marketReward: nil), now: 5)
        XCTAssertThrowsError(try ledger.assign(client: "a", on: market, now: 5)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unpriceable, "work on a template without Market's block buys nothing there")
        }
    }

    func testCommitSpendsCreditAndHoldsTheFeeAgainstTheFloat() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: nexus, now: 0)
        for nonce in 0..<2 {
            _ = try ledger.credit(assignment: a.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 8, on: nexus, balance: 100, holdUntil: 600_000, now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit, "two shares are 7.8 units")
        }
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 4, on: nexus, balance: 3, holdUntil: 600_000, now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat)
        }
        try ledger.commit(client: "a", fee: 4, on: nexus, balance: 7, holdUntil: 600_000, now: 2)
        XCTAssertEqual(ledger.credit(of: "a", on: nexus), nexusShare * UInt256(2) - units(4))

        let b = try ledger.assign(client: "b", on: nexus, now: 2)
        for nonce in 100..<102 {
            _ = try ledger.credit(assignment: b.id, nonce: UInt64(nonce), hash: UInt256(1), now: 3)
        }
        XCTAssertThrowsError(try ledger.commit(client: "b", fee: 4, on: nexus, balance: 7, holdUntil: 600_000, now: 3)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat, "a's fee is still held")
        }
        try ledger.commit(client: "b", fee: 4, on: nexus, balance: 8, holdUntil: 600_000, now: 3)
    }

    /// Only one block per height can be the chain's: the credit a height
    /// backs, over every client, stops at its reward.
    func testCreditAtAHeightStopsAtItsBlocksReward() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: market, now: 0)
        let b = try ledger.assign(client: "b", on: market, now: 0)
        for nonce in 0..<10 {
            _ = try ledger.credit(assignment: a.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        for nonce in 100..<106 {
            _ = try ledger.credit(assignment: b.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        XCTAssertEqual(ledger.credit(of: "a", on: market) + ledger.credit(of: "b", on: market), units(10))
        XCTAssertThrowsError(try ledger.credit(assignment: b.id, nonce: 106, hash: UInt256(1), now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut)
        }
        XCTAssertThrowsError(try ledger.assign(client: "c", on: market, now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut)
        }
        ledger.install(template(workID: "w2", marketHeight: 8), now: 2)
        XCTAssertNoThrow(try ledger.assign(client: "c", on: market, now: 2), "the next height backs credit anew")
    }

    /// Once the chain moves past the block a template carries, work on that
    /// template can no longer win it and earns nothing.
    func testWorkOnAHeightTheChainHasPassedEarnsNothing() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: market, now: 0)
        ledger.install(template(workID: "w2", marketHeight: 8), now: 1)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 0, hash: UInt256(1), now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .expired)
        }
    }

    /// A refresh that leaves the chain out (the node omitted its block, or a
    /// read failed) neither resets a height's backing nor hides that the
    /// chain moved past it.
    func testAChainMissingFromOneRefreshKeepsItsHeightsBackingAndStaleness() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", on: market, now: 0)
        for nonce in 0..<16 {
            _ = try ledger.credit(assignment: a.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        ledger.install(template(workID: "w2", marketReward: nil), now: 2)
        XCTAssertThrowsError(try ledger.credit(assignment: a.id, nonce: 16, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut, "the height's reward is still spent")
        }
        ledger.install(template(workID: "w3", marketHeight: 7), now: 3)
        XCTAssertThrowsError(try ledger.assign(client: "b", on: market, now: 3)) {
            XCTAssertEqual($0 as? SponsorRefusal, .soldOut)
        }

        var moved = self.ledger()
        let b = try moved.assign(client: "b", on: market, now: 0)
        moved.install(template(workID: "w2", marketHeight: 8), now: 1)
        moved.install(template(workID: "w3", marketReward: nil), now: 2)
        XCTAssertThrowsError(try moved.credit(assignment: b.id, nonce: 0, hash: UInt256(1), now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .expired, "a live template still shows the chain at 8")
        }
    }

    /// After a reorg to a lower height, no range is handed out that a live
    /// template's higher height would refuse.
    func testNoWorkIsAssignedBelowALiveTemplatesHeight() throws {
        var ledger = ledger()
        ledger.install(template(workID: "w0", marketHeight: 8), now: 0)
        ledger.install(template(workID: "w2", marketHeight: 7), now: 1)
        XCTAssertThrowsError(try ledger.assign(client: "a", on: market, now: 1)) {
            XCTAssertEqual($0 as? SponsorRefusal, .busy)
        }
        ledger.install(template(workID: "w3", marketHeight: 7, expiresAt: 60_000), now: 30_000)
        XCTAssertNoThrow(try ledger.assign(client: "a", on: market, now: 30_000), "once the higher template expires")
    }

    func testSponsoredBodyAddsOnlyTheFeeAndCoSigns() throws {
        let client = CryptoUtils.generateKeyPair()
        let sponsorKey = CryptoUtils.generateKeyPair()
        let clientAddress = CryptoUtils.createAddress(from: client.publicKey)
        let sponsorAddress = CryptoUtils.createAddress(from: sponsorKey.publicKey)
        let body = try sponsoredBody(
            draft: draft(signer: clientAddress, actions: [Action(key: "greeting", oldValue: nil, newValue: "hi")]),
            sponsor: sponsorAddress,
            fee: 7,
            chainPath: ["Nexus"]
        )
        XCTAssertEqual(body.signers, [clientAddress, sponsorAddress], "the client keeps the nonce")
        XCTAssertEqual(body.minerSurplus(), WorkSum(UInt256(7)))

        let header = try HeaderImpl(node: body)
        var signatures: [String: String] = [:]
        for key in [client, sponsorKey] {
            signatures[key.publicKey] = TransactionSigning.sign(bodyHeader: header, privateKeyHex: key.privateKey)
        }
        XCTAssertTrue(Transaction(signatures: signatures, body: header).signaturesMatchSigners())
    }

    func testSponsoredBodyRefusesDraftsThatReachTheSponsor() {
        let client = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let refused: [TransactionBody] = [
            draft(signer: client, accountActions: [
                AccountAction(owner: sponsor, delta: -5), AccountAction(owner: client, delta: 5),
            ]),
            draft(signer: client, actions: [Action(key: "owner/\(sponsor)", oldValue: nil, newValue: "x")]),
            draft(signer: client, actions: [Action(key: "name/h", oldValue: sponsor, newValue: "\(sponsor)>\(client)")]),
            draft(signer: client, accountActions: [AccountAction(owner: client, delta: 5)]),
            draft(signer: client, chainPath: ["Nexus", "Market"]),
            draft(signer: sponsor),
        ]
        for body in refused {
            XCTAssertThrowsError(try sponsoredBody(draft: body, sponsor: sponsor, fee: 1, chainPath: ["Nexus"]))
        }
        XCTAssertThrowsError(try sponsoredBody(draft: draft(signer: client), sponsor: sponsor, fee: 0, chainPath: ["Nexus"]))
    }
}
