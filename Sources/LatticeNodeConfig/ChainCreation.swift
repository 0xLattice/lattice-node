import Foundation
import Lattice
import LatticeNodeAPI
import LatticeNodeCore

/// Creating a child chain: a one-shot action, apart from the configuration.
/// It checks what fixes the chain's genesis (its spec, premine recipient,
/// genesis transactions and the modules the spec names) and writes it,
/// once, under `specs/`. A hosted path with these files is mined from them;
/// one without them is synced from its peers.
public enum ChainCreation {
    /// The chain was created with something else: a chain is created once.
    public struct Exists: Error, CustomStringConvertible {
        public let path: String
        public var description: String {
            "\(path) already exists with another spec, premine recipient or genesis transactions; a child chain is created once"
        }
    }

    /// The chain is followed here without a spec: in the hosted tree (listed
    /// by a layer, or implied by a chain listed under it), or held in
    /// storage. A spec now would mine a rival genesis.
    public struct Synced: Error, CustomStringConvertible {
        public let path: String
        public let reason: String
        public var description: String {
            "\(path) is \(reason) without a spec, synced from its peers; it takes no spec"
        }
    }

    /// Whether `path` was created here (its spec is under `specs/`).
    public static func isCreated(_ path: String, layout: HostLayout) -> Bool {
        FileManager.default.fileExists(atPath: layout.childSpec(for: path).path)
    }

    /// Checks `chain` and writes its files. False when it was created with
    /// exactly these already (nothing written); `Exists` when with others.
    @discardableResult
    /// `holdsBlocks` answers whether this node's store holds blocks of a
    /// chain path; it throws when the store cannot be read.
    public static func create(
        _ chain: HostedChain,
        layout: HostLayout,
        holdsBlocks: (_ chainPath: String) throws -> Bool
    ) throws -> Bool {
        guard let address = ChainAddress(string: chain.path), address.key == chain.path, !address.isNexus else {
            throw CtlError("\(chain.path) is not a child chain's path")
        }
        guard let spec = chain.spec else { throw CtlError("\(chain.path): a chain is created from a spec") }
        // A premine is paid only to an account the creator names.
        if spec.premineAmount() > 0, (chain.premineTo ?? "").isEmpty {
            throw CtlError("\(chain.path): the spec has a premine of \(spec.premine) blocks; name the account it goes to (premineTo)")
        }
        if spec.premineAmount() == 0, chain.premineTo != nil {
            throw CtlError("\(chain.path): premineTo names an account, but the spec pays no premine")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let specData = try encoder.encode(spec)
        let specFile = layout.childSpec(for: chain.path)
        let premineFile = layout.premineRecipient(for: chain.path)
        let genesisFile = layout.genesisTransactions(for: chain.path)
        let genesisData = try chain.genesisTransactions.map { try encoder.encode($0) }
        if let existing = try? Data(contentsOf: specFile) {
            // Modules are named by CID in the spec: the same spec, the same modules.
            let sameSpec = (try? encoder.encode(JSONDecoder().decode(ChainSpec.self, from: existing))) == specData
            let premine = (try? String(contentsOf: premineFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let genesis = (try? Data(contentsOf: genesisFile)).flatMap {
                try? encoder.encode(JSONDecoder().decode([SubmitTransactionRequest].self, from: $0))
            }
            guard sameSpec, premine == chain.premineTo, genesis == genesisData else { throw Exists(path: chain.path) }
            return false
        }
        // A chain already followed here takes no spec, running or not (in
        // the hosted tree, listed or implied; failed to start; unhosted, its
        // data not yet let go of).
        if let followed = try MergedConfig.load(root: layout.root).tree[chain.path] {
            throw Synced(path: chain.path, reason: followed.listedBy.isEmpty
                ? "hosted for \(followed.impliedBy.joined(separator: ", "))"
                : "listed by \(followed.listedBy.joined(separator: ", "))")
        }
        // Fails closed: a store that cannot be read refuses the creation.
        let holds: Bool
        do {
            holds = try holdsBlocks(chain.path)
        } catch {
            throw CtlError("\(chain.path): whether this node holds the chain could not be read (\(error)); not created")
        }
        if holds {
            throw Synced(path: chain.path, reason: "held in this node's storage")
        }
        var modules: [String: Data] = [:]
        for bytes in chain.policyModules ?? [] {
            let cid = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: bytes)).rawCID
            let policies = spec.wasmPolicies.filter { $0.moduleCID == cid }
            guard !policies.isEmpty else {
                throw CtlError("module \(cid) is not named by the spec's wasmPolicies")
            }
            for policy in policies {
                do {
                    try WasmPolicyEvaluator.validate(policy: policy, moduleBytes: bytes)
                } catch {
                    throw CtlError("module \(cid) is not valid for policy \(policy.entrypoint): \(error)")
                }
            }
            modules[cid] = bytes
        }
        if let missing = spec.wasmPolicies.map(\.moduleCID).first(where: { modules[$0] == nil }) {
            throw CtlError("the spec names policy module \(missing); send it in policyModules")
        }
        do {
            try ChildGenesis.checkPremine(
                spec: spec, to: chain.premineTo, transactions: (chain.genesisTransactions ?? []).map(\.transaction),
                on: address.components, modules: Array(modules.values),
                timestamp: Int64(Date().timeIntervalSince1970 * 1000)
            )
        } catch {
            throw CtlError("\(chain.path): \(error)")
        }
        if let premineTo = chain.premineTo { try writeDurably(Data(premineTo.utf8), to: premineFile) }
        if let genesisData { try writeDurably(genesisData, to: genesisFile) }
        let directory = layout.policyModules(for: chain.path)
        for (cid, bytes) in modules.sorted(by: { $0.key < $1.key }) {
            try writeDurably(bytes, to: directory.appendingPathComponent(cid + ".wasm"))
        }
        // The spec last: it marks the chain created, so it never stands
        // without what its genesis is built from.
        try writeDurably(specData, to: specFile)
        return true
    }
}
