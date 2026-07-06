import Foundation
import XCTest

final class MiningRoleContractTests: XCTestCase {
    // These tests are doc-lint gates for the E15 role contract; behavioral RPC
    // enforcement belongs to the implementation issues that consume it.
    func testMiningRoleContractDocumentsLockedBoundaries() throws {
        let contract = try readRepoFile("docs/design/mining-role-boundaries.md")

        assertContains(contract, [
            "`LatticeNode`",
            "`MiningCoordinator`",
            "`LatticeMiner`",
            "chain state",
            "block template",
            "effective target",
            "solution validation",
            "block acceptance",
            "persistence",
            "gossip publication",
            "stale work",
            "nonce ranges",
            "proof-of-work nonce search"
        ])
    }

    func testWorkerProtocolSchemaIsExplicitAndNarrow() throws {
        let contract = try readRepoFile("docs/design/mining-role-boundaries.md")

        assertContains(contract, [
            "`workId`",
            "`blockHex`",
            "serialized nonce-0 `Block` node",
            "`target`",
            "`nonceRange`",
            "`batchSize`",
            "`staleToken`",
            "`nonce`",
            "`hash`",
            "`range`",
            "`status`",
            "`found`",
            "`exhausted`",
            "`cancelled`",
            "`stale`"
        ])

        assertContains(contract, [
            "does not construct blocks",
            "resolve block content roots",
            "know child-chain topology",
            "gossip blocks",
            "generate child proofs",
            "publish to Ivy",
            "hold or send coinbase private keys"
        ])
    }

    func testOwnershipMatrixCoversLoadBearingMiningResponsibilities() throws {
        let contract = try readRepoFile("docs/design/mining-role-boundaries.md")

        assertContains(contract, [
            "Template and candidate construction",
            "Effective target calculation",
            "Merged-mining child proof generation and verification",
            "Block sealing from accepted solution",
            "Block acceptance, persistence, and gossip publication",
            "Stale-work detection and cancellation",
            "Nonce-range allocation and de-duplication",
            "Worker retry/backoff and result race resolution"
        ])
    }

    func testContractCitesSotaMiningPatterns() throws {
        let contract = try readRepoFile("docs/design/mining-role-boundaries.md")

        assertContains(contract, [
            "Stratum V2 Mining Protocol",
            "Stratum V2 Job Declaration",
            "Template Distribution",
            "BIP22",
            "getblocktemplate",
            "submitblock",
            "AuxPoW",
            "merged mining"
        ])
    }

    func testPublicDocsPointAtMiningRoleContract() throws {
        let protocolSpec = try readRepoFile("docs/protocol.md")
        let rpcApi = try readRepoFile("docs/rpc-api.md")
        let readme = try readRepoFile("README.md")
        let architecture = try readRepoFile("docs/architecture.md")

        for document in [protocolSpec, rpcApi, readme, architecture] {
            XCTAssertTrue(
                document.contains("Mining role boundaries"),
                "public mining docs should link to the E15 role-boundary contract"
            )
            XCTAssertTrue(
                document.contains("MiningCoordinator"),
                "public mining docs should name the coordinator layer"
            )
        }
    }

    func testLegacyPrivateKeyTemplateFieldIsRemoved() throws {
        let rpcApi = try readRepoFile("docs/rpc-api.md")

        // (Mechanism A): the key fields are removed from the
        // template body and the coinbase recipient comes from --coinbase-address.
        XCTAssertTrue(rpcApi.contains("`--coinbase-address`"))
        XCTAssertTrue(rpcApi.contains("template fields are removed"))
        XCTAssertTrue(rpcApi.contains("must not send coinbase private keys or miner private"))
    }

    // (Mechanism A) — CI-enforced source-grep gate, defense in
    // depth behind the unconditional behavioral test in
    // CoinbaseAddressTemplateTests (which drives the REAL /api/chain/template,
    // /api/chain/submit-work and /api/balance entry points and asserts the sealed
    // coinbase pays the configured --coinbase-address, ignoring request keys).
    //
    // This gate scans EVERY RPC source file (Sources/LatticeNode/RPC/*.swift), not
    // just the template route, so a regression that re-adds a miner key field to
    // submit-work, a new mining endpoint, or any other RPC file turns the suite
    // red on every runner. It strips line comments first so the design comments
    // that deliberately NAME the removed fields don't falsely trip the gate; only
    // the code a JSON decoder actually honors is checked.
    func testMiningRequestBodiesDoNotDecodeMinerKeyFields() throws {
        let rpcDir = try repoRoot().appendingPathComponent("Sources/LatticeNode/RPC")
        let files = try FileManager.default
            .contentsOfDirectory(at: rpcDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "expected to find RPC source files to scan")

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Strip line comments so the deliberate mention of the removed fields
            // in design comments does not falsely trip the gate; we only want the
            // property declarations the JSON decoder actually honors.
            let codeOnly = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> String in
                    guard let range = line.range(of: "//") else { return String(line) }
                    return String(line[line.startIndex..<range.lowerBound])
                }
                .joined(separator: "\n")

            for field in ["minerPrivateKey", "minerPublicKey"] {
                XCTAssertFalse(
                    codeOnly.contains(field),
                    "RPC source \(file.lastPathComponent) must NOT reference "
                        + "\(field); the node builds the coinbase from --coinbase-address "
                        + "and the miner only searches the nonce. Reintroducing this field "
                        + "into any mining request Body is a security regression."
                )
            }
        }
    }

    func testLatticeMinerTargetIsNonceSearchOnly() throws {
        let minerSource = try readRepoFile("Sources/LatticeMiner/Miner.swift")
        let package = try readRepoFile("Package.swift")

        assertContains(minerSource, [
            "Search one immutable proof-of-work nonce range",
            "workId",
            "blockHex",
            "Block(data: blockData)",
            "ProofOfWork.midstate(for: block)",
            "ProofOfWork.midstate(prefixBytes:",
            "ProofOfWork.hash(midstate: midstate, nonce: nonce)",
            "target",
            "startNonce",
            "ProofOfWork.searchBatch"
        ])

        assertNotContains(minerSource, [
            "--node",
            "--peer",
            "childNode",
            "childBlock",
            "submit-work",
            "HTTPMiningCoordinatorNodeClient",
            "Ivy",
            "cashew",
            "minerPrivateKey",
            "identityFile",
            "gossip"
        ])

        guard let minerTarget = package.range(of: #"name: "LatticeMiner""#) else {
            return XCTFail("Package.swift must define LatticeMiner target")
        }
        let remainder = package[minerTarget.lowerBound...]
        let targetBody = remainder.prefix(while: { $0 != "]" })
        for forbidden in ["LatticeMiningCoordinator", "Ivy", "cashew", "ArrayTrie", "_CryptoExtras"] {
            XCTAssertFalse(
                targetBody.contains(forbidden),
                "LatticeMiner target must not depend on \(forbidden)"
            )
        }
    }

    func testTemplateRoutesUseOnlyNodeOwnedRewardIdentity() throws {
        let templateSource = try readRepoFile("Sources/LatticeNode/RPC/RPCServer+TemplateRoutes.swift")
        let coordinatorSource = try readRepoFile("Sources/LatticeMiningCoordinator/MiningCoordinator.swift")
        let codecSource = try readRepoFile("Sources/LatticeNodeRPCFuzzSupport/RPC/RPCRequestBodyCodecs.swift")

        assertContains(templateSource, [
            "let nodeConfig = await node.config",
            "let coinbaseAuthority = node.coinbaseAuthority",
            "nodeConfig.coinbaseAddress.map",
            "identity: coinbaseAuthority",
            "recipientAddress: rewardMaterial.recipientAddress"
        ])

        assertNotContains(templateSource, [
            "MinerIdentity(publicKeyHex: body.minerPublicKey",
            "privateKeyHex: body.minerPrivateKey",
            "publicKeyHex: minerPublicKey",
            "privateKeyHex: minerPrivateKey"
        ])
        assertNotContains(coordinatorSource, [
            #""rewardPublicKeyHex""#,
            #""rewardPrivateKeyHex""#,
            "payload[\"rewardPublicKeyHex\"]",
            "payload[\"rewardPrivateKeyHex\"]"
        ])
        assertNotContains(codecSource, [
            "rewardPublicKeyHex",
            "rewardPrivateKeyHex"
        ])
    }

    func testTemplateRoutesPassParentCarrierForLatticeHomesteadAnchoring() throws {
        let packageSource = try readRepoFile("Package.swift")
        let templateSource = try readRepoFile("Sources/LatticeNode/RPC/RPCServer+TemplateRoutes.swift")
        let blockSource = try readRepoFile("Sources/LatticeNode/Chain/LatticeNode+Blocks.swift")
        let producerSource = try readRepoFile("Sources/LatticeNode/Mining/BlockProducer.swift")

        assertContains(packageSource, [
            #"exact: "16.0.0""#
        ])
        assertContains(templateSource, [
            #""parentBlockHex": parentCarrierHex"#,
            "materializeParentHomesteadForCandidate(",
            "parentChainBlock: parentChainBlock"
        ])
        // prevState is a cashew Reference now: materialize pre-warms it via
        // resolve rather than baking it into the block with set(properties:).
        assertContains(blockSource, [
            "func materializeParentHomesteadForCandidate",
            "parentBlock.prevState.resolve"
        ])
        // In-process child-block building was removed from BlockProducer: child
        // candidates are built by each chain's own node process via the template
        // RPC routes (parent-homestead anchoring asserted on templateSource /
        // blockSource above). The producer must not regrow that machinery:
        assertNotContains(templateSource, [
            "parentBlockHex is the parent chain's tip block",
            #"tipBlock.set(properties: ["prevState": tipBlock.postState])"#,
            #""parentBlockHex": thisTipHex"#
        ])
        assertNotContains(blockSource, [
            "materializeParentPostStateForCandidate",
            "parentBlock.postState.resolve"
        ])
        assertNotContains(producerSource, [
            "nexusBlock.set(properties:",
            #""prevState": nexusBlock.postState"#,
            #"nexusBlock.set(properties: ["homestead": nexusBlock.postState])"#,
            "parentBlock: childTip"
        ])
    }

    func testCoordinatorToolOwnsNodeFacingMiningResponsibilities() throws {
        let coordinatorSource = try readRepoFile("Sources/LatticeMiningCoordinatorTool/main.swift")

        assertContains(coordinatorSource, [
            "--node",
            "childNode",
            "rpcCookieFile",
            "HTTPMiningCoordinatorNodeClient",
            "MiningCoordinator(",
            "runBatch()"
        ])
        assertNotContains(coordinatorSource, [
            "Ivy",
            "cashew",
            "publishBlock",
            "ChildBlockProof"
        ])
    }
}

private func assertContains(
    _ haystack: String,
    _ needles: [String],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for needle in needles {
        XCTAssertTrue(
            haystack.localizedCaseInsensitiveContains(needle),
            "Expected document to contain '\(needle)'",
            file: file,
            line: line
        )
    }
}

private func assertNotContains(
    _ haystack: String,
    _ needles: [String],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for needle in needles {
        XCTAssertFalse(
            haystack.localizedCaseInsensitiveContains(needle),
            "Expected document not to contain '\(needle)'",
            file: file,
            line: line
        )
    }
}

private func readRepoFile(_ relativePath: String) throws -> String {
    let root = try repoRoot()
    let url = root.appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func repoRoot() throws -> URL {
    var current = URL(fileURLWithPath: #filePath)
    while current.path != "/" {
        let packageFile = current.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: packageFile.path) {
            return current
        }
        current.deleteLastPathComponent()
    }

    throw NSError(
        domain: "MiningRoleContractTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not locate Package.swift from \(#filePath)"]
    )
}
