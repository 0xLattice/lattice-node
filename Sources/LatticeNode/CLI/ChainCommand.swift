import ArgumentParser
import Foundation
import Lattice
import cashew
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Subcommand group for child-chain lifecycle management.
struct ChainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chain",
        abstract: "Child-chain lifecycle management (deploy, attach, detach, genesis, children, follow)",
        subcommands: [
            ChainDeployCommand.self,
            ChainAttachCommand.self,
            ChainDetachCommand.self,
            ChainGenesisCommand.self,
            ChainChildrenCommand.self,
            ChainFollowCommand.self,
        ]
    )
}

// MARK: - chain deploy

struct ChainDeployCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deploy",
        abstract: "Create a child-chain genesis, submit the genesisAction tx, and print the node start command"
    )

    @Option(help: "Parent node base URL (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Path to parent node cookie file for admin auth")
    var cookieFile: String?

    @Option(help: "Path to signer key JSON file {publicKey, privateKey}")
    var key: String

    @Option(help: "New chain directory name (letters, numbers, underscores, hyphens)")
    var directory: String

    @Option(help: "Parent chain directory (default: inferred from node)")
    var parentDirectory: String?

    @Option(help: "Full chain path for the genesisAction tx (default: auto-detected from node)")
    var chainPath: String?

    @Option(help: "Target block time in milliseconds")
    var targetBlockTime: UInt64 = 30_000

    @Option(help: "Initial block reward")
    var initialReward: UInt64 = 1_000_000

    @Option(help: "Halving interval in blocks")
    var halvingInterval: UInt64 = 1_000_000

    @Option(help: "Premine amount (requires --premine-recipient)")
    var premine: UInt64 = 0

    @Option(help: "Premine recipient address (required if --premine > 0)")
    var premineRecipient: String?

    @Option(help: "Maximum transactions per block")
    var maxTransactionsPerBlock: UInt64 = 5_000

    @Option(help: "Maximum state growth in bytes")
    var maxStateGrowth: Int = 3_000_000

    @Option(help: "Maximum block size in bytes")
    var maxBlockSize: Int = 1_000_000

    @Option(help: "Retarget window in blocks")
    var retargetWindow: UInt64 = 120

    @Flag(help: "Poll until the genesisAction tx is mined (up to 120 polls at 5s each)")
    var wait: Bool = false

    func run() async throws {
        // Load key
        let keyData = try Data(contentsOf: URL(fileURLWithPath: key))
        guard let keyJSON = try JSONSerialization.jsonObject(with: keyData) as? [String: Any],
              let publicKey = keyJSON["publicKey"] as? String,
              let privateKey = keyJSON["privateKey"] as? String else {
            printError("Invalid key file. Expected JSON with string publicKey + privateKey")
            throw ExitCode.failure
        }
        let signer = CryptoUtils.createAddress(from: publicKey)

        // Load auth token
        let authToken = loadAuthToken(cookieFile: cookieFile)

        // Auto-detect parent chain path from chain/info if not given
        let parentChainPathStr: String
        if let cp = chainPath {
            parentChainPathStr = cp
        } else {
            let chainInfo = try await fetchJSON("\(rpc)/api/chain/info")
            guard let chains = chainInfo["chains"] as? [[String: Any]],
                  let firstChain = chains.first else {
                printError("Could not auto-detect chain path from \(rpc)/api/chain/info")
                throw ExitCode.failure
            }
            // Prefer the full chainPath array (present on per-process nodes with --chain-path)
            // over the bare directory leaf, so grandchild deploy under a child node works.
            if let cp = (firstChain["chainPath"] as? [String])?.joined(separator: "/"), !cp.isEmpty {
                parentChainPathStr = cp
            } else if let dir = firstChain["directory"] as? String {
                parentChainPathStr = dir
            } else {
                printError("Could not auto-detect chain path from \(rpc)/api/chain/info")
                throw ExitCode.failure
            }
        }
        let parentChainPath = parentChainPathStr.split(separator: "/").map(String.init)

        // Determine parentDirectory
        let parentDir: String
        if let pd = parentDirectory {
            parentDir = pd
        } else {
            parentDir = parentChainPath.last ?? parentChainPathStr
        }

        printHeader("Deploying child chain '\(directory)'")
        printKeyValue("Parent RPC", rpc)
        printKeyValue("Signer", signer)
        printKeyValue("Directory", directory)
        printKeyValue("Parent directory", parentDir)
        printKeyValue("Chain path (parent)", parentChainPathStr)

        // Preflight: read nonce/balance before the destructive deploy call so a zero-balance
        // signer or query failure is caught before the parent stages the child genesis/metadata.
        var chainPathAllowed = CharacterSet.urlQueryAllowed
        chainPathAllowed.remove(charactersIn: "&=+")
        let chainQuery = parentChainPathStr.addingPercentEncoding(withAllowedCharacters: chainPathAllowed) ?? parentChainPathStr
        guard let preflightNonce = try await fetchJSON("\(rpc)/api/nonce/\(signer)?chainPath=\(chainQuery)")["nonce"] as? UInt64 else {
            printError("Could not read nonce for \(signer) on chain '\(parentChainPathStr)'")
            throw ExitCode.failure
        }
        guard let preflightBalance = try await fetchJSON("\(rpc)/api/balance/\(signer)?chainPath=\(chainQuery)")["balance"] as? UInt64 else {
            printError("Could not read balance for \(signer) on chain '\(parentChainPathStr)'")
            throw ExitCode.failure
        }
        guard preflightBalance > 0 else {
            printError("Signer has zero balance on chain '\(parentChainPathStr)' — cannot pay fee")
            throw ExitCode.failure
        }

        // POST /api/chain/deploy
        let childChainPathEarly = parentChainPath + [directory]
        let childChainPathEarlyStr = childChainPathEarly.joined(separator: "/")
        var deployPayload: [String: Any] = [
            "directory": directory,
            "parentDirectory": parentDir,
            "chainPath": childChainPathEarly,
            "targetBlockTime": targetBlockTime,
            "initialReward": initialReward,
            "halvingInterval": halvingInterval,
            "premine": premine,
            "maxTransactionsPerBlock": maxTransactionsPerBlock,
            "maxStateGrowth": maxStateGrowth,
            "maxBlockSize": maxBlockSize,
            "retargetWindow": retargetWindow,
        ]
        if let recipient = premineRecipient {
            deployPayload["premineRecipient"] = recipient
        }
        let deployBody = try JSONSerialization.data(withJSONObject: deployPayload)
        let deployResp = try await postJSON("\(rpc)/api/chain/deploy", body: deployBody, authToken: authToken)
        if let errMsg = deployResp["error"] as? String {
            printError("Deploy failed: \(errMsg)")
            throw ExitCode.failure
        }
        guard let genesisHash = deployResp["genesisHash"] as? String,
              let genesisHex = deployResp["genesisHex"] as? String else {
            printError("Deploy response missing genesisHash or genesisHex")
            throw ExitCode.failure
        }
        let chainP2PAddress = deployResp["chainP2PAddress"] as? String ?? ""
        printKeyValue("Genesis hash", genesisHash)

        // Build genesisAction tx and compute fee (nonce/balance already fetched above)
        let nonce = preflightNonce
        let balance = preflightBalance
        func buildBody(fee: UInt64) -> TransactionBody {
            TransactionBody(
                accountActions: [AccountAction(owner: signer, delta: -Int64(fee))],
                actions: [],
                depositActions: [],
                genesisActions: [GenesisAction(directory: directory, blockCID: genesisHash)],
                receiptActions: [],
                withdrawalActions: [],
                signers: [signer],
                fee: fee,
                nonce: nonce,
                chainPath: parentChainPath
            )
        }
        let probeSize = UInt64(buildBody(fee: 1).toData()?.count ?? 512)
        let finalFee = probeSize + 16
        guard balance >= finalFee else {
            printError("Insufficient balance: have \(balance), need \(finalFee) for fee")
            throw ExitCode.failure
        }
        let body = buildBody(fee: finalFee)
        printKeyValue("Fee", "\(finalFee)")

        let bodyHeader = try HeaderImpl<TransactionBody>(node: body)
        guard let signature = TransactionSigning.sign(body: body, bodyCID: bodyHeader.rawCID, privateKeyHex: privateKey) else {
            printError("Signing failed")
            throw ExitCode.failure
        }
        guard let bodyData = body.toData() else {
            printError("Serialization failed")
            throw ExitCode.failure
        }

        let txPayload: [String: Any] = [
            "signatures": [publicKey: signature],
            "bodyCID": bodyHeader.rawCID,
            "bodyData": bodyData.map { String(format: "%02x", $0) }.joined(),
            "chainPath": parentChainPath
        ]
        let txJSON = try JSONSerialization.data(withJSONObject: txPayload)
        let txResp = try await postJSON("\(rpc)/api/transaction", body: txJSON)
        if txResp["accepted"] as? Bool == true {
            let txCID = txResp["txCID"] as? String ?? ""
            printSuccess("GenesisAction tx submitted: \(String(txCID.prefix(32)))...")
        } else {
            let errMsg = txResp["error"] as? String ?? "Unknown error"
            printError("GenesisAction tx rejected: \(errMsg)")
            printWarning("The child genesis was staged on the parent but the anchor tx did not land.")
            printWarning("The genesis already exists — to start the node directly without retrying the tx:")
            print("    lattice-node node \\")
            print("      --genesis-hex \(genesisHex) \\")
            print("      --chain-directory \(directory) \\")
            print("      --chain-path \(childChainPathEarlyStr) \\")
            if !chainP2PAddress.isEmpty {
                print("      --subscribe-p2p \(chainP2PAddress) \\")
            }
            printWarning("Or rerun `chain deploy` with the same arguments to retry the genesisAction tx.")
            throw ExitCode.failure
        }

        // Optionally wait for the tx to mine
        if wait {
            print("  Waiting for genesisAction tx to mine...")
            var mined = false
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if let newNonce = try? await fetchJSON("\(rpc)/api/nonce/\(signer)?chainPath=\(chainQuery)")["nonce"] as? UInt64,
                   newNonce > nonce {
                    mined = true
                    break
                }
            }
            if mined {
                printSuccess("GenesisAction tx mined")
            } else {
                printWarning("Timed out waiting for genesisAction tx to mine — it may still be pending")
            }
        }

        // Compute the full child chain path for the start command
        let childChainPath = parentChainPath + [directory]
        let childChainPathStr = childChainPath.joined(separator: "/")

        print("")
        printSuccess("Child chain '\(directory)' deployed successfully")
        printKeyValue("Genesis hash", genesisHash)
        print("")
        print("  Node start command:")
        print("    lattice-node node \\")
        print("      --genesis-hex \(genesisHex) \\")
        print("      --chain-directory \(directory) \\")
        print("      --chain-path \(childChainPathStr) \\")
        if !chainP2PAddress.isEmpty {
            print("      --subscribe-p2p \(chainP2PAddress) \\")
        }
        print("      --port <p2p-port> \\")
        print("      --rpc-port <rpc-port> \\")
        print("      --data-dir <data-dir>")
        print("")
        print("  Next: register with parent using:")
        print("    lattice-node chain attach \\")
        print("      --rpc \(rpc) \\")
        print("      --chain-path \(childChainPathStr) \\")
        print("      --child-rpc http://127.0.0.1:<rpc-port>")
    }

    private func loadAuthToken(cookieFile: String?) -> String? {
        guard let path = cookieFile else { return nil }
        return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func httpGet(_ urlString: String, authToken: String? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { return Data() }
        var req = URLRequest(url: url)
        if let token = authToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: req) { data, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
        #endif
    }

    private func fetchJSON(_ urlString: String, authToken: String? = nil) async throws -> [String: Any] {
        let data = try await httpGet(urlString, authToken: authToken)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func postJSON(_ urlString: String, body: Data, authToken: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { return [:] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let responseData: Data
        #if canImport(FoundationNetworking)
        responseData = try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: request)
        responseData = data
        #endif
        return (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
    }
}

// MARK: - chain attach

struct ChainAttachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Register an existing deployed child chain's RPC endpoint with its parent node"
    )

    @Option(help: "Parent node base URL (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Path to parent node cookie file for admin auth")
    var cookieFile: String?

    @Option(help: "Full chain path, e.g. Nexus/toy/toytoy")
    var chainPath: String

    @Option(help: "Child node base URL, e.g. http://127.0.0.1:8089")
    var childRpc: String

    @Option(help: "Path to child node cookie file (reads auth token from it)")
    var childCookieFile: String?

    @Option(help: "Child node auth token (alternative to --child-cookie-file)")
    var childAuthToken: String?

    func run() async throws {
        let parentAuth = loadToken(cookieFile: cookieFile)

        // Load child auth token from cookie file or direct flag
        let childToken: String?
        if let path = childCookieFile {
            childToken = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            childToken = childAuthToken
        }

        let path = chainPath.split(separator: "/").map(String.init)
        // Store API-base URL (with /api): the block forwarder appends "/chain/..." and
        // the generic proxy strips the incoming /api prefix before concatenating.
        let endpoint = childRpc.hasSuffix("/api") ? childRpc : childRpc + "/api"

        printHeader("Attaching chain '\(chainPath)'")
        printKeyValue("Parent RPC", rpc)
        printKeyValue("Child endpoint", endpoint)

        var payload: [String: Any] = [
            "chainPath": path,
            "endpoint": endpoint,
        ]
        if let token = childToken { payload["authToken"] = token }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = try await postJSON("\(rpc)/api/chain/register-rpc", body: body, authToken: parentAuth)
        if let errMsg = resp["error"] as? String {
            printError("Attach failed: \(errMsg)")
            throw ExitCode.failure
        }
        printSuccess("Chain '\(chainPath)' attached to parent at \(rpc)")
    }

    private func loadToken(cookieFile: String?) -> String? {
        guard let path = cookieFile else { return nil }
        return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func postJSON(_ urlString: String, body: Data, authToken: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { return [:] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let responseData: Data
        #if canImport(FoundationNetworking)
        responseData = try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: request)
        responseData = data
        #endif
        return (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
    }
}

// MARK: - chain detach

struct ChainDetachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detach",
        abstract: "Unregister a child chain's RPC endpoint from its parent node"
    )

    @Option(help: "Parent node base URL (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Path to parent node cookie file for admin auth")
    var cookieFile: String?

    @Option(help: "Full chain path, e.g. Nexus/toy/toytoy")
    var chainPath: String

    func run() async throws {
        let authToken = loadToken(cookieFile: cookieFile)
        let path = chainPath.split(separator: "/").map(String.init)

        printHeader("Detaching chain '\(chainPath)'")
        printKeyValue("Parent RPC", rpc)

        let payload: [String: Any] = ["chainPath": path]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let resp = try await postJSON("\(rpc)/api/chain/unregister-rpc", body: body, authToken: authToken)
        if let errMsg = resp["error"] as? String {
            printError("Detach failed: \(errMsg)")
            throw ExitCode.failure
        }
        printSuccess("Chain '\(chainPath)' detached from parent at \(rpc)")
        if let w = resp["warning"] as? String { printWarning(w) }
    }

    private func loadToken(cookieFile: String?) -> String? {
        guard let path = cookieFile else { return nil }
        return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func postJSON(_ urlString: String, body: Data, authToken: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { return [:] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let responseData: Data
        #if canImport(FoundationNetworking)
        responseData = try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: request)
        responseData = data
        #endif
        return (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
    }
}

// MARK: - chain genesis

struct ChainGenesisCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genesis",
        abstract: "Show genesis hex and node start command for an existing deployed chain"
    )

    @Option(help: "Parent node base URL (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Path to parent node cookie file for admin auth")
    var cookieFile: String?

    @Option(help: "Full chain path, e.g. Nexus/toy")
    var chainPath: String

    func run() async throws {
        let authToken = loadToken(cookieFile: cookieFile)
        var chainPathAllowed = CharacterSet.urlQueryAllowed
        chainPathAllowed.remove(charactersIn: "&=+")
        let chainQuery = chainPath.addingPercentEncoding(withAllowedCharacters: chainPathAllowed) ?? chainPath
        let resp = try await fetchJSON("\(rpc)/api/chain/genesis?chainPath=\(chainQuery)", authToken: authToken)
        if let errMsg = resp["error"] as? String {
            printError("Failed to fetch genesis: \(errMsg)")
            throw ExitCode.failure
        }
        guard let genesisHash = resp["genesisHash"] as? String,
              let genesisHex = resp["genesisHex"] as? String else {
            printError("Response missing genesisHash or genesisHex")
            throw ExitCode.failure
        }
        let chainP2PAddress = resp["chainP2PAddress"] as? String ?? ""
        let directory = resp["directory"] as? String ?? (chainPath.split(separator: "/").last.map(String.init) ?? chainPath)

        printHeader("Genesis info for '\(chainPath)'")
        printKeyValue("Genesis hash", genesisHash)
        print("")
        print("  Node start command:")
        print("    lattice-node node \\")
        print("      --genesis-hex \(genesisHex) \\")
        print("      --chain-directory \(directory) \\")
        print("      --chain-path \(chainPath) \\")
        if !chainP2PAddress.isEmpty {
            print("      --subscribe-p2p \(chainP2PAddress) \\")
        }
        print("      --port <p2p-port> \\")
        print("      --rpc-port <rpc-port> \\")
        print("      --data-dir <data-dir>")
    }

    private func loadToken(cookieFile: String?) -> String? {
        guard let path = cookieFile else { return nil }
        return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func httpGet(_ urlString: String, authToken: String? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { return Data() }
        var req = URLRequest(url: url)
        if let token = authToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: req) { data, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
        #endif
    }

    private func fetchJSON(_ urlString: String, authToken: String? = nil) async throws -> [String: Any] {
        let data = try await httpGet(urlString, authToken: authToken)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - chain children

struct ChainChildrenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "children",
        abstract: "Discover the child chains announced by a chain (from its on-chain GenesisState)"
    )

    @Option(help: "Node base URL (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Chain whose children to list, e.g. Nexus or Nexus/toy (default: the node's root)")
    var chainPath: String?

    @Option(help: "Maximum children to return (default 100)")
    var limit: Int = 100

    @Option(help: "Pagination cursor: return children whose directory sorts after this")
    var after: String?

    func run() async throws {
        var url = "\(rpc)/api/chain/children?limit=\(limit)"
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        if let chainPath {
            url += "&chainPath=\(chainPath.addingPercentEncoding(withAllowedCharacters: allowed) ?? chainPath)"
        }
        if let after {
            url += "&after=\(after.addingPercentEncoding(withAllowedCharacters: allowed) ?? after)"
        }
        let resp = try await fetchJSON(url)
        if let errMsg = resp["error"] as? String {
            printError("Failed to list child chains: \(errMsg)")
            throw ExitCode.failure
        }
        let chainName = resp["chain"] as? String ?? (chainPath ?? "Nexus")
        let children = resp["children"] as? [[String: Any]] ?? []
        printHeader("Child chains of '\(chainName)' (\(children.count))")
        if children.isEmpty {
            print("  (none announced yet)")
            return
        }
        for c in children {
            let dir = c["directory"] as? String ?? "?"
            let hash = c["genesisHash"] as? String ?? "?"
            let path = (c["chainPath"] as? [String])?.joined(separator: "/") ?? dir
            printKeyValue(path, hash.count > 24 ? String(hash.prefix(24)) + "…" : hash)
        }
        print("")
        print("  Follow one with: \(Style.dim)lattice-node chain follow <chainPath>\(Style.reset)")
    }

    private func httpGet(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { return Data() }
        let req = URLRequest(url: url)
        #if canImport(FoundationNetworking)
        return try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: req) { data, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
        #endif
    }

    private func fetchJSON(_ urlString: String) async throws -> [String: Any] {
        let data = try await httpGet(urlString)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

// MARK: - chain follow

struct ChainFollowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "follow",
        abstract: "Subscribe to an existing announced child chain (genesis resolved from chain state; no genesis-hex/peer needed)"
    )

    @Option(help: "Node base URL (without /api suffix)")
    var rpc: String = "http://127.0.0.1:8080"

    @Option(help: "Path to node cookie file for admin auth")
    var cookieFile: String?

    @Argument(help: "Full chain path to follow, e.g. Nexus/toy")
    var chainPath: String

    func run() async throws {
        let authToken = loadToken(cookieFile: cookieFile)
        let path = chainPath.split(separator: "/").map(String.init)
        printHeader("Following chain '\(chainPath)'")
        printKeyValue("Node RPC", rpc)
        let body = try JSONSerialization.data(withJSONObject: ["chainPath": path])
        let resp = try await postJSON("\(rpc)/api/chain/follow", body: body, authToken: authToken)
        if let errMsg = resp["error"] as? String {
            printError("Follow failed: \(errMsg)")
            throw ExitCode.failure
        }
        printSuccess("Now following '\(chainPath)'. The node resolves its genesis from the parent's on-chain state and syncs it as a supervised child; check progress with the node logs or 'lattice-node chain children'.")
    }

    private func loadToken(cookieFile: String?) -> String? {
        guard let path = cookieFile else { return nil }
        return try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func postJSON(_ urlString: String, body: Data, authToken: String? = nil) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { return [:] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = authToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let responseData: Data
        #if canImport(FoundationNetworking)
        responseData = try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }.resume()
        }
        #else
        let (data, _) = try await URLSession.shared.data(for: request)
        responseData = data
        #endif
        return (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]) ?? [:]
    }
}
