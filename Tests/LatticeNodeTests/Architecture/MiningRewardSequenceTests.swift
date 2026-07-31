import XCTest
import Lattice
import cashew
@testable import LatticeNode

/// Reward payouts are ordinary signed transactions under consensus rules:
/// signer nonces are strictly sequential, so one signed reward is valid in
/// exactly one block, in order — the invariant `lattice-rewards emit-batch`
/// and the reference mining supervisor are built on.
final class MiningRewardSequenceTests: XCTestCase {
    private func rewardRequest(
        privateKeyHex: String,
        publicKeyHex: String,
        nonce: UInt64
    ) throws -> MiningTemplateRequest {
        let address = CryptoUtils.createAddress(from: publicKeyHex)
        let body = TransactionBody(
            accountActions: [AccountAction(
                owner: address,
                delta: Int64(NexusGenesis.spec.initialReward)
            )],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [address],
            fee: 0,
            nonce: nonce,
            chainPath: ["Nexus"]
        )
        let header = try HeaderImpl(node: body)
        let signature = try XCTUnwrap(TransactionSigning.sign(
            bodyHeader: header,
            privateKeyHex: privateKeyHex
        ))
        return MiningTemplateRequest(rewards: [MiningReward(
            chainPath: ["Nexus"],
            transaction: Transaction(
                signatures: [publicKeyHex: signature],
                body: header
            )
        )])
    }

    private func mineOnce(
        _ service: ChainService,
        _ request: MiningTemplateRequest
    ) async throws -> SubmitWorkResponse? {
        let template = try await service.miningTemplate(request)
        for nonce in 0..<200_000 as Range<UInt64> {
            let result = try await service.submitWork(SubmitWorkRequest(
                workID: template.workID,
                nonce: nonce
            ))
            if result.accepted { return result }
        }
        return nil
    }

    func testSignedRewardsMineInNonceOrderAndReplayIsRefused() async throws {
        let key = CryptoUtils.generateKeyPair()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reward-sequence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = try await ChainProcess.open(
            configuration: NodeConfiguration(
                chainPath: ["Nexus"],
                storagePath: directory,
                privateKeyHex: String(repeating: "01", count: 32)
            )
        )
        let service = ChainService(
            process: process,
            childCandidateProvider: { _ in [] },
            childCandidateReservationReconciler: {
                $0.reservations.isEmpty && $0.handoffs.isEmpty
            },
            childProofPublisher: { _ in },
            acceptedBlockPublisher: { _ in },
            acceptedTransactionPublisher: { _ in }
        )

        let first = try await mineOnce(service, rewardRequest(
            privateKeyHex: key.privateKey,
            publicKeyHex: key.publicKey,
            nonce: 0
        ))
        XCTAssertEqual(try XCTUnwrap(first).disposition, .canonicalized)

        // A spent nonce is refused at template assembly — the state
        // transition drops the reward and requireReward fails the build.
        // This surfaces to miners as HTTP 400, the supervisor's signal to
        // advance its cursor.
        do {
            _ = try await mineOnce(service, rewardRequest(
                privateKeyHex: key.privateKey,
                publicKeyHex: key.publicKey,
                nonce: 0
            ))
            XCTFail("replayed reward nonce built a template")
        } catch ChainServiceError.invalidRewardTransaction {}

        let second = try await mineOnce(service, rewardRequest(
            privateKeyHex: key.privateKey,
            publicKeyHex: key.publicKey,
            nonce: 1
        ))
        XCTAssertEqual(try XCTUnwrap(second).disposition, .canonicalized)
    }
}
