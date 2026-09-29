import Lattice
import VolumeBroker
import XCTest
import cashew
@testable import LatticeNode

/// A transaction signed by every key in `keys`, all of them listed as signers.
func signedTransaction(
    keys: [(privateKey: String, publicKey: String)],
    chainPath: [String] = ["Nexus"],
    accountActions: [AccountAction] = [],
    actions: [Action] = [],
    genesisActions: [GenesisAction] = [],
    nonce: UInt64 = 0
) throws -> Transaction {
    let body = TransactionBody(
        accountActions: accountActions,
        actions: actions,
        depositActions: [],
        genesisActions: genesisActions,
        receiptActions: [],
        withdrawalActions: [],
        signers: keys.map { CryptoUtils.createAddress(from: $0.publicKey) },
        nonce: nonce,
        chainPath: chainPath
    )
    let header = try HeaderImpl(node: body)
    var signatures: [String: String] = [:]
    for key in keys {
        signatures[key.publicKey] = try XCTUnwrap(TransactionSigning.sign(
            bodyHeader: header,
            privateKeyHex: key.privateKey
        ))
    }
    return Transaction(signatures: signatures, body: header)
}

func signedTransaction(
    key: (privateKey: String, publicKey: String),
    chainPath: [String] = ["Nexus"],
    accountActions: [AccountAction] = [],
    actions: [Action] = [],
    genesisActions: [GenesisAction] = [],
    nonce: UInt64 = 0
) throws -> Transaction {
    try signedTransaction(
        keys: [key],
        chainPath: chainPath,
        accountActions: accountActions,
        actions: actions,
        genesisActions: genesisActions,
        nonce: nonce
    )
}

/// A fresh key's transaction anchoring `childGenesisCID` under `directory`.
func signedGenesisAnchorTransaction(
    directory: String,
    childGenesisCID: String,
    chainPath: [String] = ["Nexus"]
) throws -> Transaction {
    try signedTransaction(
        key: CryptoUtils.generateKeyPair(),
        chainPath: chainPath,
        genesisActions: [GenesisAction(
            directory: directory,
            blockCID: childGenesisCID
        )]
    )
}

extension ChainProcess {
    /// `activateChildGenesis` from `seed`, anchored at the CID the seed
    /// builds to: for tests whose parent record is `confirm`.
    func activateChildGenesis(
        seed: ChildGenesisSeed,
        confirmParentRecordedGenesis confirm: (String) async -> Bool
    ) async throws -> Bool {
        let genesis = try await ChildGenesisBuilder.build(
            seed: seed,
            chainPath: configuration.chainPath,
            fetcher: CoalescingFetcher(CompositeContentSource([MemoryBroker()]))
        )
        return try await activateChildGenesis(
            anchoredCID: BlockHeader(node: genesis).rawCID,
            from: .seed(seed),
            confirmParentRecordedGenesis: confirm
        ) == .activated
    }
}
