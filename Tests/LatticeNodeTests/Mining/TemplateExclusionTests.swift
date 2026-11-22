import Foundation
import Ivy
import Lattice
import UInt256
import XCTest
import cashew
@testable import LatticeNode
import LatticeNodeAPI

/// A template request's `exclude`: the chains named get no block this round,
/// and the search is set by the chains left in.
final class TemplateExclusionTests: XCTestCase {
    static let testnet = ["Nexus", "testnet"]
    static let a = testnet + ["a"]
    static let b = testnet + ["b"]
    static func spec(blockTime: UInt64) -> ChainSpec {
        ChainSpec(
            maxNumberOfTransactionsPerBlock: 100, maxStateGrowth: 100_000, premine: 0,
            targetBlockTime: blockTime, initialReward: 10, halvingInterval: 10_000, halfLife: 10
        )
    }

    private func start(_ key: String) async throws -> NodeRuntime {
        let storageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "lattice-exclude-\(UUID().uuidString)", isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: storageDirectory) }
        let port = NetworkTransportTestPorts.allocate()
        // `b`'s blocks always come later than its 1 ms schedule, so its target
        // stays the maximum while `a`, on a 60 s schedule, hardens fast.
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"], storagePath: storageDirectory, privateKeyHex: String(repeating: key, count: 32),
            listenPort: port, rpcPort: NetworkTransportTestPorts.allocate(),
            hostedChildren: [Self.testnet, Self.a, Self.b],
            childSpecs: [Self.testnet: Self.spec(blockTime: 1_000), Self.a: Self.spec(blockTime: 60_000), Self.b: Self.spec(blockTime: 1)]
        )
        let overlay = IvyConfig(
            signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
            requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
            mode: .overlay
        )
        let storage = try await NodeStorage.open(configuration: configuration)
        return try await NodeRuntime.start(storage: storage, configuration: configuration, overlay: overlay)
    }

    private static func carried(_ template: MiningTemplateResponse) -> (testnet: Block, a: Block?, b: Block?)? {
        guard let testnet = template.block.children.node?.entries["testnet"]?.node else { return nil }
        let entries = testnet.children.node?.entries
        return (testnet, entries?["a"]?.node, entries?["b"]?.node)
    }

    /// The easiest threshold a minimum work can ask for below the maximum.
    static let halfTarget = minimumWorkTarget(UInt256(2))

    func testAnExcludedSiblingLeavesTheSearchAndGetsNoBlock() async throws {
        let runtime = try await start("5a")
        let aReads = try XCTUnwrap(runtime.levelReads[Self.a])
        let bReads = try XCTUnwrap(runtime.levelReads[Self.b])
        // `testnet` pays a recipient, so its state changes: its children's
        // geneses commit a non-empty parent state.
        let recipient = CryptoUtils.createAddress(from: CryptoUtils.generateKeyPair().publicKey)
        let plain = MiningTemplateRequest(recipients: [MiningRecipient(chainPath: Self.testnet, address: recipient)])

        var template = try await runtime.miningTemplate(plain)
        var mined = 0
        while mined < 128 {
            if let carried = Self.carried(template), let a = carried.a, let b = carried.b,
               a.target < Self.halfTarget, b.target == .max,
               (await aReads.readSnapshot().height ?? 0) >= 1,
               (await bReads.readSnapshot().height ?? 0) >= 1 { break }
            _ = try await runtime.mineBlock(plain)
            mined += 1
            try await eventually("block \(mined) executes") { runtime.published.value?.actOnHeight == UInt64(mined) }
            template = try await runtime.miningTemplate(plain)
        }
        let carried = try XCTUnwrap(Self.carried(template))
        let a = try XCTUnwrap(carried.a, "the template carries a")
        let b = try XCTUnwrap(carried.b, "the template carries b")
        XCTAssertLessThan(a.target, Self.halfTarget, "a mines at a hard scheduled target")
        XCTAssertEqual(b.target, .max)

        // No `exclude`: unchanged, b's easy target sets the search.
        XCTAssertEqual(template.searchTarget, b.target)

        // A filter on b between a's and b's targets binds: the search stops
        // at it, never at b's easier target.
        let between = try await runtime.miningTemplate(MiningTemplateRequest(
            recipients: plain.recipients,
            minimumWork: [MiningMinimumWork(chainPath: Self.b, work: UInt256(2))]
        ))
        let betweenB = try XCTUnwrap(Self.carried(between)?.b)
        let betweenA = try XCTUnwrap(Self.carried(between)?.a)
        XCTAssertLessThan(betweenA.target, Self.halfTarget)
        XCTAssertLessThan(Self.halfTarget, betweenB.target)
        XCTAssertEqual(between.searchTarget, Self.halfTarget)

        // A filter on b while b is carried stops the whole search at it: a
        // hash for a would also make the b block the miner declined.
        let filterB = [MiningMinimumWork(chainPath: Self.b, work: maximumRepresentableWork)]
        let filtered = try await runtime.miningTemplate(MiningTemplateRequest(
            recipients: plain.recipients, minimumWork: filterB
        ))
        XCTAssertEqual(filtered.searchTarget, UInt256(1))

        // Excluded, b is not carried and its target leaves the search, with
        // or without a filter on it.
        for minimumWork in [[], filterB] {
            let excluded = try await runtime.miningTemplate(MiningTemplateRequest(
                recipients: plain.recipients, minimumWork: minimumWork, exclude: [Self.b]
            ))
            let kept = try XCTUnwrap(Self.carried(excluded))
            XCTAssertNotNil(kept.a)
            XCTAssertNil(kept.b, "b is left out")
            XCTAssertFalse(excluded.chains?.contains { $0.chainPath == Self.b } ?? true)
            let easiest = [excluded.block.target, kept.testnet.target, try XCTUnwrap(kept.a).target].max()
            XCTAssertEqual(excluded.searchTarget, easiest, "the easiest included target, minimumWork \(minimumWork)")
            XCTAssertEqual(excluded.targets.first, excluded.searchTarget)
            XCTAssertLessThan(excluded.searchTarget, b.target)
        }

        // A nonce that clears every target (b's included) advances a, never b.
        let bHeight = await bReads.readSnapshot().height ?? 0
        let excludeB = MiningTemplateRequest(recipients: plain.recipients, exclude: [Self.b])
        var advanced = false
        for _ in 0..<8 where !advanced {
            let aBefore = await aReads.readSnapshot().height ?? 0
            let work = try await runtime.miningTemplate(excludeB)
            let solved = try await runtime.mine(work)
            XCTAssertLessThanOrEqual(solved.proofOfWorkHash(), b.target)
            advanced = (try? await eventually("a advances", within: .seconds(3)) {
                (await aReads.readSnapshot().height ?? 0) > aBefore
            }) != nil
        }
        XCTAssertTrue(advanced, "a advances")
        let bAfter = await bReads.readSnapshot().height ?? 0
        XCTAssertEqual(bAfter, bHeight, "an excluded chain gets no block")
        await runtime.stop()
    }

    func testExcludingAChainThatCarriesAnIncludedOneIsRefused() async throws {
        let runtime = try await start("5b")
        func refusal(_ exclude: [[String]]) async -> NodeAPIError? {
            do {
                _ = try await runtime.miningTemplate(MiningTemplateRequest(exclude: exclude))
                return nil
            } catch {
                return error as? NodeAPIError
            }
        }
        let carryingIncluded = await refusal([Self.testnet])
        XCTAssertEqual(carryingIncluded, .excludedAncestor, "testnet carries a and b")
        let partly = await refusal([Self.testnet, Self.a])
        XCTAssertEqual(partly, .excludedAncestor, "testnet carries b")
        let root = await refusal([["Nexus"]])
        XCTAssertEqual(root, .invalidExclusion, "the template's own chain")
        let twice = await refusal([Self.b, Self.b])
        XCTAssertEqual(twice, .invalidExclusion)

        // Excluding the whole subtree is allowed: no testnet block at all.
        let template = try await runtime.miningTemplate(MiningTemplateRequest(exclude: [Self.testnet, Self.a, Self.b]))
        XCTAssertNil(template.block.children.node?.entries["testnet"])
        XCTAssertEqual(template.chains?.map(\.chainPath), [["Nexus"]])
        await runtime.stop()
    }

    func testARequestWithoutExcludeEncodesAsBefore() throws {
        let encoded = try JSONEncoder().encode(MiningTemplateRequest(recipients: []))
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"{"recipients":[]}"#)
        let decoded = try JSONDecoder().decode(
            MiningTemplateRequest.self, from: Data(#"{"exclude":[["Nexus","testnet","b"]]}"#.utf8)
        )
        XCTAssertEqual(decoded.exclude, [Self.b])
    }
}
