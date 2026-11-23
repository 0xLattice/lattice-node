import Foundation
import Lattice
import cashew

// `LatticeLightClient` verifies state witnesses without booting a node: it
// depends only on Lattice and cashew, never on LatticeNode.

/// Namespace for the witness node shared by the proofs here.
public enum LightClientProof {
    public struct WitnessNode: Codable, Sendable, Equatable {
        public let cid: String
        public let data: String

        public init(cid: String, data: Data) {
            self.cid = cid
            self.data = data.base64EncodedString()
        }

        public var rawData: Data? { Data(base64Encoded: data) }
    }
}

public struct StateDictionaryProof: Codable, Sendable, Equatable {
    public enum StateKind: String, Codable, Sendable { case deposits, receipts }
    public struct Claim: Codable, Sendable, Equatable {
        public let key: String
        public let value: String?
        public init(key: String, value: String?) { self.key = key; self.value = value }
    }
    public let blockHash: String
    public let blockHeight: UInt64
    public let block: LightClientProof.WitnessNode
    public let stateRoot: String
    public let dictionary: StateKind
    public let dictionaryRoot: String
    public let claims: [Claim]
    public let witness: [LightClientProof.WitnessNode]

    public init(blockHash: String, blockHeight: UInt64, block: LightClientProof.WitnessNode,
                stateRoot: String, dictionary: StateKind, dictionaryRoot: String,
                claims: [Claim], witness: [LightClientProof.WitnessNode]) {
        self.blockHash = blockHash; self.blockHeight = blockHeight; self.block = block
        self.stateRoot = stateRoot; self.dictionary = dictionary
        self.dictionaryRoot = dictionaryRoot; self.claims = claims; self.witness = witness
    }
}

public enum LightClientProtocol {
    public static func verify(_ proof: StateDictionaryProof) async -> Bool {
        guard let blockData = proof.block.rawData,
              proof.block.cid == proof.blockHash,
              let blockNode = Block(data: blockData),
              (try? HeaderImpl(node: blockNode).rawCID) == proof.blockHash,
              blockNode.height == proof.blockHeight,
              blockNode.postState.rawCID == proof.stateRoot else { return false }
        var entries: [String: Data] = [:]
        for node in proof.witness {
            guard entries[node.cid] == nil, let data = node.rawData else { return false }
            entries[node.cid] = data
        }
        let fetcher = InMemoryContentSource(entries)
        guard let stateData = try? await fetcher.fetch(rawCid: proof.stateRoot),
              let state = LatticeState(data: stateData),
              (try? LatticeStateHeader(node: state).rawCID) == proof.stateRoot else { return false }
        let paths = Swift.Dictionary(uniqueKeysWithValues: proof.claims.map { ([$0.key], ResolutionStrategy.targeted) })
        switch proof.dictionary {
        case .deposits:
            guard state.depositState.rawCID == proof.dictionaryRoot else { return false }
            if proof.claims.isEmpty {
                guard let data = try? await fetcher.fetch(rawCid: proof.dictionaryRoot),
                      let node = DepositState(data: data),
                      (try? DepositStateHeader(node: node).rawCID) == proof.dictionaryRoot else { return false }
                return true
            }
            guard
                  let dictionary = try? await DepositStateHeader(rawCID: proof.dictionaryRoot)
                    .resolve(paths: paths, fetcher: fetcher).node else { return false }
            for claim in proof.claims {
                do {
                    let actual = try dictionary.get(key: claim.key).map(String.init)
                    if actual != claim.value { return false }
                } catch { return false }
            }
        case .receipts:
            guard state.receiptState.rawCID == proof.dictionaryRoot else { return false }
            if proof.claims.isEmpty {
                guard let data = try? await fetcher.fetch(rawCid: proof.dictionaryRoot),
                      let node = ReceiptState(data: data),
                      (try? ReceiptStateHeader(node: node).rawCID) == proof.dictionaryRoot else { return false }
                return true
            }
            guard
                  let dictionary = try? await ReceiptStateHeader(rawCID: proof.dictionaryRoot)
                    .resolve(paths: paths, fetcher: fetcher).node else { return false }
            for claim in proof.claims {
                do {
                    if try dictionary.get(key: claim.key) != claim.value { return false }
                } catch { return false }
            }
        }
        return true
    }
}
