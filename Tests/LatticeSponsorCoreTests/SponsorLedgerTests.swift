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

/// Nexus's block at 2^200 - 1 paying 1,000, and Market's 2^4 easier paying 10.
private func template(expiresAt: Int64 = 30_000) -> SponsorTemplate {
    SponsorTemplate(
        workID: "w1",
        prefixHex: "00",
        prices: [
            nexus: ChainPrice(target: target(200), reward: 1_000),
            market: ChainPrice(target: target(204), reward: 10),
        ],
        submitTarget: target(204),
        expiresAt: expiresAt
    )
}

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
    /// A share target 2^8 easier than the block: 256 shares are one block's
    /// expected work, so a fee of R/256 costs one share.
    private func ledger() -> SponsorLedger {
        var ledger = SponsorLedger(shareTarget: target(208), rangeSize: 100)
        ledger.install(template())
        return ledger
    }

    func testSharesCreditOnlyInsideTheirOwnRangeOnce() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", now: 0)
        let b = try ledger.assign(client: "b", now: 0)
        XCTAssertEqual(a.startNonce, 0)
        XCTAssertEqual(b.startNonce, 100, "ranges are disjoint")

        let easy = UInt256(1)
        let credited = try ledger.credit(assignment: a.id, nonce: 5, hash: easy, now: 1)
        XCTAssertEqual(credited.credit, workForTarget(ledger.shareTarget))
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
        XCTAssertEqual(ledger.credit(of: "b"), .zero)
    }

    func testAShareClearingTheSubmitTargetIsABlock() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", now: 0)
        let share = try ledger.credit(assignment: a.id, nonce: 1, hash: target(205), now: 1)
        XCTAssertNil(share.blockWorkID)
        let child = try ledger.credit(assignment: a.id, nonce: 2, hash: target(203), now: 1)
        XCTAssertEqual(child.blockWorkID, "w1", "a Market block is a block")
    }

    func testCostIsTheFeesShareOfABlocksExpectedWork() {
        let price = ChainPrice(target: target(200), reward: 1_000)
        let block = workForTarget(price.target)
        XCTAssertEqual(SponsorLedger.cost(fee: 1_000, at: price), block, "a whole reward is a whole block")
        XCTAssertEqual(SponsorLedger.cost(fee: 1, at: price), (block + UInt256(999)) / UInt256(1_000), "rounded up")
        XCTAssertNil(SponsorLedger.cost(fee: 1, at: ChainPrice(target: target(200), reward: 0)), "no reward, no price")
        XCTAssertEqual(ledger().sharesFor(fee: 1_000, on: nexus), UInt256(256))
        XCTAssertEqual(ledger().sharesFor(fee: 4, on: nexus), UInt256(2), "4/1000 of 256 shares, rounded up")
        XCTAssertEqual(ledger().sharesFor(fee: 10, on: market), UInt256(16), "Market's block is 16 shares")
        XCTAssertNil(ledger().sharesFor(fee: 1, on: ["Nexus", "Absent"]), "no block in the template, no price")
    }

    /// One share is a ticket on every chain's block at once, so credit is
    /// work: earned once, spent on whichever chain's fee the client needs.
    func testCreditBuysAFeeOnAnyChainTheTemplateCarries() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", now: 0)
        for nonce in 0..<16 {
            _ = try ledger.credit(assignment: a.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        try ledger.commit(client: "a", fee: 5, on: market, balance: 5, now: 2)
        XCTAssertEqual(ledger.credit(of: "a"), workForTarget(ledger.shareTarget) * UInt256(8))
        try ledger.commit(client: "a", fee: 5, on: nexus, balance: 5, now: 2)
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 1, on: ["Nexus", "Absent"], balance: 5, now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .unpriceable)
        }
    }

    func testCommitSpendsCreditAndHoldsTheFeeAgainstTheFloat() throws {
        var ledger = ledger()
        let a = try ledger.assign(client: "a", now: 0)
        for nonce in 0..<2 {
            _ = try ledger.credit(assignment: a.id, nonce: UInt64(nonce), hash: UInt256(1), now: 1)
        }
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 8, on: nexus, balance: 100, now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientCredit, "fee 8 costs 3 shares")
        }
        XCTAssertThrowsError(try ledger.commit(client: "a", fee: 4, on: nexus, balance: 3, now: 2)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat)
        }
        try ledger.commit(client: "a", fee: 4, on: nexus, balance: 7, now: 2)
        let spent = ledger.cost(fee: 4, on: nexus)!
        XCTAssertEqual(ledger.credit(of: "a"), workForTarget(ledger.shareTarget) * UInt256(2) - spent)

        let b = try ledger.assign(client: "b", now: 2)
        for nonce in 100..<102 {
            _ = try ledger.credit(assignment: b.id, nonce: UInt64(nonce), hash: UInt256(1), now: 3)
        }
        XCTAssertThrowsError(try ledger.commit(client: "b", fee: 4, on: nexus, balance: 7, now: 3)) {
            XCTAssertEqual($0 as? SponsorRefusal, .insufficientFloat, "a's fee is still held")
        }
        try ledger.commit(client: "b", fee: 4, on: nexus, balance: 8, now: 3)
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
