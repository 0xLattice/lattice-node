import Foundation
import Lattice
@testable import LatticeNode
import XCTest
import cashew

/// Every 64- and 128-bit consensus integer on the JSON wire is a canonical
/// decimal string (the SDK's `^(?:0|-?[1-9][0-9]*)$`), in both directions,
/// and a JSON number is refused.
final class DecimalWireTests: XCTestCase {
    private func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testResponsesSpellWideIntegersAsDecimalStrings() throws {
        let block = try object(ExplorerBlock(
            height: UInt64.max, hash: "h", timestamp: -1, previousBlock: nil,
            transactionCount: 3, childBlockCount: 0, nonce: 9_007_199_254_740_993,
            version: 1, target: .max, nextTarget: .max, transactionsCID: "t",
            postStateCID: "p", chain: ["Nexus"], rewardRecipient: nil, rewardCredited: 0
        ))
        XCTAssertEqual(block["height"] as? String, "18446744073709551615")
        XCTAssertEqual(block["timestamp"] as? String, "-1")
        XCTAssertEqual(block["nonce"] as? String, "9007199254740993")
        XCTAssertEqual(block["rewardCredited"] as? String, "0")
        // Small counts stay JSON numbers; absent optionals are omitted, never null.
        XCTAssertEqual(block["transactionCount"] as? Int, 3)
        XCTAssertNil(block["previousBlock"])
        XCTAssertNil(block["rewardRecipient"])

        let status = try object(NodeStatusResponse(
            phase: .active, chainPath: ["Nexus"], nexusGenesisCID: "g", tipCID: "t",
            height: 42, revision: nil, mempoolCount: 1, mempoolBytes: 2, templateDigest: nil
        ))
        XCTAssertEqual(status["height"] as? String, "42")
        XCTAssertNil(status["revision"])
        XCTAssertEqual(status["mempoolCount"] as? Int, 1)

        let transaction = try object(ExplorerTransaction(
            txCID: "c", blockHeight: nil, blockHash: nil, timestamp: nil, nonce: 7,
            signers: [], chainPath: ["Nexus"], chain: ["Nexus"],
            accountActions: [ExplorerAccountAction(owner: "o", delta: Int64.min)],
            depositActions: [ExplorerDepositAction(nonce: "1", demander: "d", amountDemanded: 2, amountDeposited: 3)],
            receiptActions: [], withdrawalActions: []
        ))
        XCTAssertNil(transaction["blockHeight"])
        XCTAssertEqual(transaction["nonce"] as? String, "7")
        let account = try XCTUnwrap((transaction["accountActions"] as? [[String: Any]])?.first)
        XCTAssertEqual(account["delta"] as? String, "-9223372036854775808")
        let deposit = try XCTUnwrap((transaction["depositActions"] as? [[String: Any]])?.first)
        XCTAssertEqual(deposit["amountDeposited"] as? String, "3")

        let info = try object(ExplorerChainInfo(
            genesisHash: nil, height: 0, tipCID: nil, chain: ["Nexus"], minRelayFee: 5
        ))
        XCTAssertEqual(info["height"] as? String, "0")
        XCTAssertEqual(info["minRelayFee"] as? String, "5")
    }

    func testNonCanonicalOrNumericSpellingsAreRefused() throws {
        let decoder = JSONDecoder()
        struct Box: Decodable { @DecimalString var value: UInt64 }
        struct SignedBox: Decodable { @DecimalString var value: Int64 }
        struct OptionalBox: Decodable { @OptionalDecimalString var value: UInt64? }
        XCTAssertEqual(try decoder.decode(Box.self, from: Data(#"{"value":"18446744073709551615"}"#.utf8)).value, .max)
        XCTAssertEqual(try decoder.decode(SignedBox.self, from: Data(#"{"value":"-5"}"#.utf8)).value, -5)
        XCTAssertNil(try decoder.decode(OptionalBox.self, from: Data("{}".utf8)).value)
        for bad in ["5", #""05""#, #""+5""#, #""-0""#, #""""#, #"" 5""#, #""18446744073709551616""#, #""-1""#] {
            XCTAssertThrowsError(try decoder.decode(Box.self, from: Data(#"{"value":\#(bad)}"#.utf8)), bad)
        }
        XCTAssertThrowsError(try decoder.decode(OptionalBox.self, from: Data(#"{"value":5}"#.utf8)))
    }

    /// The SDK's `transactionPayload` shape decodes to the same consensus
    /// body (same CID) as the native value, and a numeric spelling is refused.
    func testSubmitBodyAcceptsTheSDKDecimalSpelling() throws {
        let body = TransactionBody(
            accountActions: [AccountAction(owner: "alice", delta: -9_007_199_254_740_993)],
            actions: [Action(key: "k", oldValue: nil, newValue: "v")],
            depositActions: [DepositAction(nonce: 12, demander: "bob", amountDemanded: 3, amountDeposited: 4)],
            receiptActions: [ReceiptAction(withdrawer: "w", nonce: 13, demander: "bob", amountDemanded: 5, directory: "Alpha")],
            withdrawalActions: [WithdrawalAction(withdrawer: "w", nonce: 14, demander: "bob", amountDemanded: 6, amountWithdrawn: 7)],
            signers: ["alice"], nonce: UInt64.max, chainPath: ["Nexus"]
        )
        let json = #"""
        {"transaction":{"signatures":{"pk":"sig"},"body":{
          "accountActions":[{"owner":"alice","delta":"-9007199254740993"}],
          "actions":[{"key":"k","newValue":"v"}],
          "depositActions":[{"nonce":"12","demander":"bob","amountDemanded":"3","amountDeposited":"4"}],
          "receiptActions":[{"withdrawer":"w","nonce":"13","demander":"bob","amountDemanded":"5","directory":"Alpha"}],
          "withdrawalActions":[{"withdrawer":"w","nonce":"14","demander":"bob","amountDemanded":"6","amountWithdrawn":"7"}],
          "signers":["alice"],"nonce":"18446744073709551615","chainPath":["Nexus"]}}}
        """#
        let decoded = try JSONDecoder().decode(SubmitTransactionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.transaction.body.rawCID, try HeaderImpl(node: body).rawCID)
        XCTAssertEqual(decoded.transaction.signatures, ["pk": "sig"])

        // Round trip through the node's own encoder keeps the CID.
        let reencoded = try JSONEncoder().encode(decoded)
        XCTAssertEqual(
            try JSONDecoder().decode(SubmitTransactionRequest.self, from: reencoded).transaction.body.rawCID,
            decoded.transaction.body.rawCID
        )

        let numeric = json.replacingOccurrences(of: #""nonce":"18446744073709551615""#, with: #""nonce":1"#)
        XCTAssertThrowsError(try JSONDecoder().decode(SubmitTransactionRequest.self, from: Data(numeric.utf8)))
    }
}
