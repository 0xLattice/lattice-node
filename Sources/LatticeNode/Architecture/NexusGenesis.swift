import Lattice
import UInt256
import cashew

/// The deterministic local bootstrap definition for Nexus.
public enum NexusGenesis {
    public static let ownerPublicKeyHex =
        "ed01fe416588df6e7fa5213c0d3e430f504bb5203172120c86b874826b55f53bdb7d"
    public static let ownerAddress = CryptoUtils.createAddress(from: ownerPublicKeyHex)

    public static let spec = ChainSpec(
        maxNumberOfTransactionsPerBlock: 5_000,
        maxStateGrowth: 3_000_000,
        maxBlockSize: 1_000_000,
        premine: 175_320,
        targetBlockTime: 3_600_000,
        initialReward: 1_048_576,
        halvingInterval: 876_600,
        retargetWindow: 120
    )
    public static let config = GenesisConfig(
        spec: spec,
        timestamp: 0
    )

    /// Canonical identity of the Nexus bootstrap block.
    public static let expectedBlockHash =
        "bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq"

    public static func buildGenesisBlock(fetcher: any Fetcher) async throws -> Block {
        let body = TransactionBody(
            accountActions: [AccountAction(
                owner: ownerAddress,
                delta: Int64(spec.premineAmount())
            )],
            actions: [],
            depositActions: [],
            genesisActions: [],
            receiptActions: [],
            withdrawalActions: [],
            signers: [],
            fee: 0,
            nonce: 0,
            chainPath: ["Nexus"]
        )
        let transaction = Transaction(
            signatures: [:],
            body: try HeaderImpl<TransactionBody>(node: body)
        )
        return try await BlockBuilder.buildGenesis(
            spec: spec,
            transactions: [transaction],
            timestamp: config.timestamp,
            // Genesis target is not configurable — it is canonically the maximum
            // (easiest) value, which genesis validation requires.
            target: UInt256.max,
            fetcher: fetcher
        )
    }

    public static func create(fetcher: any Fetcher) async throws -> GenesisResult {
        let block = try await buildGenesisBlock(fetcher: fetcher)
        return GenesisResult(
            block: block,
            blockHash: try BlockHeader(node: block).rawCID
        )
    }

    public static func computedBlockHash(fetcher: any Fetcher) async throws -> String {
        try await create(fetcher: fetcher).blockHash
    }

    public static func verifyGenesis(_ result: GenesisResult) throws -> Bool {
        guard try BlockHeader(node: result.block).rawCID == result.blockHash else {
            return false
        }
        return result.blockHash == expectedBlockHash
    }
}
