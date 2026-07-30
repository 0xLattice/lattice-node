import Foundation
import Lattice
import cashew

// Module 10 (layer cleanup) — ownership decision: `LatticeLightClient` is a
// BLESSED lower-layer client package, deliberately kept OUT of the daemon. It
// depends only on Lattice + cashew + VolumeBroker (never LatticeNode), so a
// light client / the `LatticeProofVerifier` executable can verify a state
// witness without booting any node/RPC machinery. It is not folded into Lattice
// because that would force the core consensus library to depend on VolumeBroker;
// keeping it a first-class client target gives clients a stable import path
// while leaving proof verification daemon-free. Do NOT move this into LatticeNode.

public struct LightClientProof: Codable, Sendable {
    public let blockHash: String
    public let blockHeight: UInt64
    /// Header metadata for the block whose state root anchors this witness.
    ///
    /// This binds the duplicated top-level proof fields to one header object. A
    /// light client still has to verify/trust the header chain separately before
    /// treating the state root as canonical.
    public let header: ChainHeader
    public let stateRoot: String
    public let address: String
    public let balance: UInt64
    /// The STORED on-chain nonce: the value witnessed under `_nonce_<address>`
    /// (the account's last-used nonce), or 0 when the key is absent (never signed).
    /// This is what the Merkle witness proves — it is NOT the RPC `getNonce`'s
    /// "next" nonce (stored + 1); a sender computes its next nonce as `nonce + 1`.
    public let nonce: UInt64
    /// CID of the proven account-state subtree. Bound to `stateRoot` by the
    /// witness (the LatticeState committed under `stateRoot` references this CID
    /// as its `accountState`).
    public let accountRoot: String
    /// The real pruned Merkle witness: the minimal set of DAG-CBOR nodes a light
    /// client needs to (a) recompute `accountRoot` from the account-path nodes,
    /// (b) confirm `accountRoot` is committed under `stateRoot` via the
    /// LatticeState wrapper node, and (c) read the proven balance from the
    /// verified account leaf. Each entry's bytes are content-bound to its CID.
    public let witness: [WitnessNode]
    public let timestamp: Int64

    public init(
        blockHash: String,
        blockHeight: UInt64,
        header: ChainHeader,
        stateRoot: String,
        address: String,
        balance: UInt64,
        nonce: UInt64,
        accountRoot: String,
        witness: [WitnessNode],
        timestamp: Int64
    ) {
        self.blockHash = blockHash
        self.blockHeight = blockHeight
        self.header = header
        self.stateRoot = stateRoot
        self.address = address
        self.balance = balance
        self.nonce = nonce
        self.accountRoot = accountRoot
        self.witness = witness
        self.timestamp = timestamp
    }

    /// One content-addressed node of the pruned witness DAG. `data` is the
    /// base64-encoded DAG-CBOR serialization of the node stored under `cid`.
    public struct WitnessNode: Codable, Sendable {
        public let cid: String
        public let data: String

        public init(cid: String, data: Data) {
            self.cid = cid
            self.data = data.base64EncodedString()
        }

        public var rawData: Data? { Data(base64Encoded: data) }
    }
}

public struct ChainHeader: Codable, Sendable {
    public let hash: String
    public let height: UInt64
    public let previousHash: String?
    public let stateRoot: String
    public let target: String
    public let timestamp: Int64
    public let cumulativeWork: String

    public init(
        hash: String,
        height: UInt64,
        previousHash: String?,
        stateRoot: String,
        target: String,
        timestamp: Int64,
        cumulativeWork: String
    ) {
        self.hash = hash
        self.height = height
        self.previousHash = previousHash
        self.stateRoot = stateRoot
        self.target = target
        self.timestamp = timestamp
        self.cumulativeWork = cumulativeWork
    }
}

public enum LightClientProtocol {
    public static func buildAccountProof(
        address: String,
        balance: UInt64,
        nonce: UInt64,
        blockHash: String,
        blockHeight: UInt64,
        header: ChainHeader,
        stateRoot: String,
        timestamp: Int64,
        accountRoot: String = "",
        witness: [LightClientProof.WitnessNode] = []
    ) async -> LightClientProof {
        return LightClientProof(
            blockHash: blockHash,
            blockHeight: blockHeight,
            header: header,
            stateRoot: stateRoot,
            address: address,
            balance: balance,
            nonce: nonce,
            accountRoot: accountRoot,
            witness: witness,
            timestamp: timestamp
        )
    }

    /// Collect the pruned Merkle witness that proves `address`'s account leaf is
    /// committed under `stateRoot`. Returns the (accountRoot, witness-nodes) pair:
    ///
    ///  - the LatticeState wrapper node committed under `stateRoot` (binds
    ///    `accountRoot` as its `accountState`), and
    ///  - the pruned account-state subtree along the radix path to `address`
    ///    (its top node hashes to `accountRoot`).
    ///
    /// The returned `accountRoot` is the proof result's own CID; its bytes and the
    /// wrapper's bytes are content-addressed, so a verifier recomputes both CIDs
    /// and rejects any tampered witness.
    public static func collectAccountWitness(
        state: LatticeState,
        stateRoot: String,
        address: String,
        nonceExists: Bool,
        fetcher: any Fetcher
    ) async throws -> (accountRoot: String, witness: [LightClientProof.WitnessNode]) {
        // Prove the balance leaf AND the nonce leaf on EVERY proof so it is
        // self-contained: `.existence` when the "_nonce_<address>" key exists,
        // `.insertion` (the non-existence / would-insert proof) when it does not.
        // Without the insertion proof a zero-nonce proof is not verifiable —
        // `verify` could default missing data to 0 with no absence witness.
        let proofPaths: [[String]: SparseMerkleProof] = [
            [address]: .existence,
            [AccountStateHeader.nonceTrackingKey(address)]: nonceExists ? .existence : .insertion,
        ]
        let proof = try await state.accountState.proof(paths: proofPaths, fetcher: fetcher)

        let storer = _ProofCollectingStorer()
        // The pruned account-path nodes (top node hashes to accountRoot).
        try await proof.storeRecursively(storer: storer)
        // The LatticeState wrapper node committed under stateRoot. Store only the
        // wrapper's own bytes (not its full sub-trees) so the witness stays pruned
        // while still binding accountRoot → stateRoot.
        if let wrapperData = state.toData() {
            try await storer.store(entries: [stateRoot: wrapperData])
        }

        let witness = await storer.entries.sorted { $0.key < $1.key }.map {
            LightClientProof.WitnessNode(cid: $0.key, data: $0.value)
        }
        return (proof.rawCID, witness)
    }

    /// Verify a balance proof end-to-end from its own witness, fail-closed:
    ///  (0) confirm the claimed block metadata matches the embedded header,
    ///  (a) recompute `accountRoot` from the witness's account-path nodes,
    ///  (b) confirm `accountRoot` is committed under `stateRoot` (the LatticeState
    ///      wrapper node stored under `stateRoot` references it as `accountState`),
    ///  (c) read the balance from the verified account leaf and confirm it equals
    ///      the proof's claimed balance.
    ///
    /// The witness's CID→bytes map is attacker-supplied, so every node fetched is
    /// content-bound: bytes stored under a CID must hash back to it.
    public static func verify(_ proof: LightClientProof) async -> Bool {
        guard !proof.witness.isEmpty, !proof.stateRoot.isEmpty, !proof.accountRoot.isEmpty else {
            return false
        }
        guard proof.header.hash == proof.blockHash,
              proof.header.height == proof.blockHeight,
              proof.header.stateRoot == proof.stateRoot,
              proof.header.timestamp == proof.timestamp else {
            return false
        }

        // Verification runs over ONLY the proof's witness nodes, in a sealed
        // in-memory source. `InMemoryContentSource` has no tier chain — it cannot
        // reach the network by construction — so a self-contained proof is
        // enforced by the type, not by convention.
        var witnessMap: [String: Data] = [:]
        witnessMap.reserveCapacity(proof.witness.count)
        for node in proof.witness {
            guard let data = node.rawData else { return false }
            witnessMap[node.cid] = data
        }
        let fetcher = InMemoryContentSource(witnessMap)

        // (b) The LatticeState wrapper committed under stateRoot must be present and
        // content-bound, and must reference the claimed accountRoot as accountState.
        guard let stateData = try? await fetcher.fetch(rawCid: proof.stateRoot),
              let stateNode = LatticeState(data: stateData),
              // known-valid local node; CID cannot fail
              try! LatticeStateHeader(node: stateNode).rawCID == proof.stateRoot,
              stateNode.accountState.rawCID == proof.accountRoot else {
            return false
        }

        // (a)+(c) Resolve the account leaf (and the nonce key when claimed) from the
        // pruned account subtree at accountRoot. Targeted resolution recomputes node
        // CIDs along each path; a tampered node fails content-binding inside cashew.
        let nonceKey = AccountStateHeader.nonceTrackingKey(proof.address)
        let accountHeader = AccountStateHeader(rawCID: proof.accountRoot)
        guard let accountNode = try? await accountHeader.resolve(
            paths: [[proof.address]: .targeted, [nonceKey]: .targeted], fetcher: fetcher
        ).node else {
            return false
        }
        let balance: UInt64 = (try? accountNode.get(key: proof.address)) ?? 0
        guard balance == proof.balance else { return false }
        // A non-zero claimed nonce must be backed by the witnessed nonce leaf. A
        // zero claim is valid only when resolving the nonce path succeeds and no
        // nonce value is present; for absent keys, the witness carries an insertion
        // proof for that path.
        let witnessedNonce: UInt64 = (try? accountNode.get(key: nonceKey)) ?? 0
        if proof.nonce != 0 { return witnessedNonce == proof.nonce }
        return witnessedNonce == 0
    }
}

private actor _ProofCollectingStorer: Storer {
    private(set) var entries: [String: Data] = [:]

    func store(entries newEntries: [String: Data]) async throws {
        for (cid, data) in newEntries {
            entries[cid] = data
        }
    }
}
