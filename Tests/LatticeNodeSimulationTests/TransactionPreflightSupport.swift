import Foundation
import Lattice
import LatticeNodeCore
import LatticeNodeSim
import XCTest
import cashew

/// The spec Lattice's own suites build on (`ChainSpec.test`), naming only
/// the premine and the chain's policies.
func preflightSpec(premine: UInt64 = 0, policies: [WasmPolicyRef] = []) -> ChainSpec {
    ChainSpec(
        maxNumberOfTransactionsPerBlock: 100,
        maxStateGrowth: 100_000,
        maxBlockSize: 1_000_000,
        premine: premine,
        targetBlockTime: 1_000,
        initialReward: 1024,
        halvingInterval: 10_000,
        halfLife: 5,
        wasmPolicies: policies
    )
}

/// A well-formed content id that nothing stores.
func absentCID(_ seed: String) -> String {
    try! HeaderImpl<PublicKey>(node: PublicKey(key: seed)).rawCID
}

/// `block` and everything it reads, in `cas`.
@discardableResult
func storeBlock(_ block: Block, in cas: SimCAS) async throws -> Block {
    try await LatticeState.emptyHeader.storeRecursively(storer: cas as any VolumeStorer)
    try await BlockHeader(node: block).store(paths: [:], storer: cas as any VolumeStorer)
    try await block.transactions.storeRecursively(storer: cas)
    try await block.spec.storeRecursively(storer: cas as any VolumeStorer)
    try await block.postState.storeRecursively(storer: cas as any VolumeStorer)
    return block
}

/// A genesis at the always-hit target, stored.
func storedGenesis(
    spec: ChainSpec,
    transactions: [Transaction] = [],
    timestamp: Int64,
    cas: SimCAS
) async throws -> Block {
    try await LatticeState.emptyHeader.storeRecursively(storer: cas as any VolumeStorer)
    return try await storeBlock(BlockBuilder.buildGenesisWithTransition(
        spec: spec, transactions: transactions, timestamp: timestamp, target: .max, fetcher: cas
    ).block, in: cas)
}

/// A block on `previous` at the always-hit target, stored.
func storedBlock(
    on previous: Block,
    transactions: [Transaction] = [],
    timestamp: Int64,
    nonce: UInt64 = 0,
    cas: SimCAS
) async throws -> Block {
    try await storeBlock(BlockBuilder.buildBlockWithTransition(
        previous: previous, transactions: transactions, timestamp: timestamp,
        target: .max, nonce: nonce, fetcher: cas
    ).block, in: cas)
}

/// A chain seeded by `genesis` as executed, unvalidated, holding its spec:
/// restored from its block, work and validation facts. On `path`, a root's
/// context pinned to `genesis`.
func preflightChain(
    genesis: Block,
    path: [String] = [DEFAULT_ROOT_DIRECTORY],
    fetcher: any Fetcher
) async throws -> ChainTree {
    let resolved = try await genesis.spec.resolve(fetcher: fetcher).node
    let spec = try XCTUnwrap(resolved)
    let blockHash = try BlockHeader(node: genesis).rawCID
    let work = try XCTUnwrap(ChainTree.rootWork(of: genesis))
    return try ChainTree.restore(
        facts: [
            .block(ChainBlockFact(
                blockHash: blockHash, parentBlockHash: nil, blockHeight: 0,
                postStateCID: genesis.postState.rawCID, prevStateCID: genesis.prevState.rawCID,
                specCID: genesis.spec.rawCID, target: genesis.target.toHexString(),
                nextTarget: genesis.nextTarget.toHexString(), timestamp: genesis.timestamp,
                stateDiff: .empty
            )),
            .work(ChainWorkFact(blockHash: blockHash, contribution: work)),
            .validation(ChainValidationFact(blockHash: blockHash)),
        ],
        context: ChainRuntimeContext(path: path, genesisCID: path.count == 1 ? blockHash : nil),
        specs: [spec]
    )
}

extension ChainTree {
    /// Transaction preflight as a node runs it on this chain: classified on
    /// `transactionPreflightTip(at:)` (the canonical tip when nil), on the
    /// chain's path.
    func preflightTransaction(
        _ transaction: Transaction,
        at tipCID: String? = nil,
        parentState: LatticeStateHeader? = nil,
        fetcher: any Fetcher,
        validationContext: ValidationContext = .current
    ) async -> TransactionPreflightResult {
        let tip = transactionPreflightTip(at: tipCID)
        return await TransactionPreflight.classify(
            transaction,
            tipCID: tip.cid,
            snapshot: tip.snapshot,
            chainPath: context!.path,
            parentState: parentState,
            fetcher: fetcher,
            validationContext: validationContext
        )
    }

    /// Weigh a root block from its header (`insertRootHeader`). A header
    /// refused or landing excluded is not executed; otherwise, when
    /// `executing`, `connectJob` → `connect` → `applyConnect`.
    mutating func admitRoot(
        _ block: Block,
        executing: Bool = true,
        fetcher: any Fetcher
    ) async throws -> ChainTreeAdmission {
        guard let childIndex = try? await block.children.resolve(fetcher: fetcher).node else {
            return .rejected(.unavailableEvidence)
        }
        let inserted = insertRootHeader(block, childIndex: childIndex)
        guard executing, inserted.failure == nil, inserted.update?.excluded != true else { return inserted }
        return await execute(try BlockHeader(node: block).rawCID, fetcher: fetcher) ?? inserted
    }

    /// Execute a block this tree weighs: `connectJob` → `connect` →
    /// `applyConnect`. Nil for a block it does not hold.
    mutating func execute(_ blockHash: String, fetcher: any Fetcher) async -> ChainTreeAdmission? {
        guard let job = connectJob(for: blockHash) else { return nil }
        return applyConnect(await ChainTree.connect(job, fetcher: fetcher))
    }
}

// MARK: - Policy modules, assembled

/// Fixed context offsets of the block fields a policy can read.
let wasmPolicyContextHeightOffset: Int32 = 11
let wasmPolicyContextTimestampOffset: Int32 = 19

/// Policy modules in the binary format: the node's test target has no WAT
/// assembler. Each body is spelled as the WAT it encodes.
enum PolicyWasm {
    static func uleb(_ value: Int) -> [UInt8] {
        var value = UInt64(value), bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    static func sleb(_ value: Int64) -> [UInt8] {
        var value = value, bytes: [UInt8] = []
        while true {
            let byte = UInt8(value & 0x7f)
            value >>= 7
            if (value == 0 && byte & 0x40 == 0) || (value == -1 && byte & 0x40 != 0) {
                return bytes + [byte]
            }
            bytes.append(byte | 0x80)
        }
    }

    static func vector(_ items: [[UInt8]]) -> [UInt8] { uleb(items.count) + items.flatMap { $0 } }
    static func name(_ text: String) -> [UInt8] { uleb(text.utf8.count) + Array(text.utf8) }
    static func section(_ id: UInt8, _ items: [[UInt8]]) -> [UInt8] {
        let body = vector(items)
        return [id] + uleb(body.count) + body
    }

    /// `i32.const value`
    static func i32(_ value: Int64) -> [UInt8] { [0x41] + sleb(value) }
    /// `call_indirect (type $nullary) (i32.const slot)`
    static func callNullary(slot: Int64) -> [UInt8] { i32(slot) + [0x11, 0x00, 0x00] }
    static let unreachable: [UInt8] = [0x00]

    static let i32Type: UInt8 = 0x7f
    static let i64Type: UInt8 = 0x7e

    /// ```
    /// (module
    ///   imports
    ///   (type $nullary (func))
    ///   (memory (export "memory") 1)
    ///   (table 2 funcref)
    ///   (elem (i32.const 0) $recurse)
    ///   (func $recurse (result i32) call $recurse)
    ///   (func (export "lattice_alloc") (param i32) (result i32) alloc)
    ///   (func (export "lattice_validate_transaction") (param i32 i32) (result i32) body)
    ///   (func (export "lattice_validate_action") (param i32 i32) (result i32) body))
    /// ```
    /// `body` and `alloc` take `recurse`, the index of `$recurse`.
    /// `importsFunction` adds `(import "env" "f" (func))`.
    static func module(
        body: (_ recurse: Int) -> [UInt8] = { _ in i32(1) },
        alloc: [UInt8] = i32(1024),
        importsFunction: Bool = false
    ) -> Data {
        let recurse = importsFunction ? 1 : 0
        let types: [[UInt8]] = [
            [0x60, 0x00, 0x00],                         // $nullary
            [0x60, 0x00, 0x01, i32Type],                // (result i32)
            [0x60, 0x01, i32Type, 0x01, i32Type],       // (param i32) (result i32)
            [0x60, 0x02, i32Type, i32Type, 0x01, i32Type],
        ]
        func code(_ instructions: [UInt8]) -> [UInt8] {
            let function = [0x00] + instructions + [0x0b]
            return uleb(function.count) + function
        }
        func export(_ text: String, kind: UInt8, index: Int) -> [UInt8] { name(text) + [kind] + uleb(index) }
        var bytes: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        bytes += section(1, types)
        if importsFunction { bytes += section(2, [name("env") + name("f") + [0x00, 0x00]]) }
        bytes += section(3, [[0x01], [0x02], [0x03], [0x03]])
        bytes += section(4, [[0x70, 0x00, 0x02]])
        bytes += section(5, [[0x00, 0x01]])
        bytes += section(7, [
            export("memory", kind: 2, index: 0),
            export("lattice_alloc", kind: 0, index: recurse + 1),
            export("lattice_validate_transaction", kind: 0, index: recurse + 2),
            export("lattice_validate_action", kind: 0, index: recurse + 3),
        ])
        bytes += section(9, [[0x00] + i32(0) + [0x0b] + vector([uleb(recurse)])])
        bytes += section(10, [
            code([0x10] + uleb(recurse)),
            code(alloc),
            code(body(recurse)),
            code(body(recurse)),
        ])
        return Data(bytes)
    }

    /// A transaction policy accepting iff the big-endian 64-bit context field
    /// at `offset` is at least `minimum` (signed compare).
    static func contextField(at offset: Int32, atLeast minimum: Int64) -> Data {
        let validate: [UInt8] = [
            0x02, 0x01, i32Type, 0x01, i64Type,         // (local $i i32) (local $v i64)
            0x03, 0x40,                                 // loop $read
            0x20, 0x03, 0x42, 0x08, 0x86,               //   local.get $v  i64.const 8  i64.shl
            0x20, 0x00] + i32(Int64(offset)) + [0x6a,   //   local.get $ptr  i32.const offset  i32.add
            0x20, 0x02, 0x6a,                           //   local.get $i  i32.add
            0x31, 0x00, 0x00, 0x84, 0x21, 0x03,         //   i64.load8_u  i64.or  local.set $v
            0x20, 0x02] + i32(1) + [0x6a, 0x22, 0x02,   //   local.get $i  i32.const 1  i32.add  local.tee $i
        ] + i32(8) + [0x49, 0x0d, 0x00,                 //   i32.const 8  i32.lt_u  br_if $read
            0x0b,                                       // end
            0x20, 0x03, 0x42] + sleb(minimum) + [0x59,  // local.get $v  i64.const minimum  i64.ge_s
            0x0b,
        ]
        let alloc: [UInt8] = [0x00] + i32(1024) + [0x0b]
        func export(_ text: String, kind: UInt8, index: Int) -> [UInt8] { name(text) + [kind] + uleb(index) }
        var bytes: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        bytes += section(1, [
            [0x60, 0x01, i32Type, 0x01, i32Type],
            [0x60, 0x02, i32Type, i32Type, 0x01, i32Type],
        ])
        bytes += section(3, [[0x00], [0x01]])
        bytes += section(5, [[0x00, 0x01]])
        bytes += section(7, [
            export("memory", kind: 2, index: 0),
            export("lattice_alloc", kind: 0, index: 0),
            export("lattice_validate_transaction", kind: 0, index: 1),
        ])
        bytes += section(10, [uleb(alloc.count) + alloc, uleb(validate.count) + validate])
        return Data(bytes)
    }

    /// `module` stored in `cas`, referenced at `scope`.
    static func store(
        _ module: Data,
        scope: WasmPolicyRef.Scope = .transaction,
        entrypoint: String? = nil,
        in cas: SimCAS
    ) async throws -> WasmPolicyRef {
        let header = try WasmPolicyModuleHeader(node: WasmPolicyModule(bytes: module))
        try await header.storeRecursively(storer: cas as any VolumeStorer)
        return WasmPolicyRef(moduleCID: header.rawCID, scope: scope, entrypoint: entrypoint)
    }
}
