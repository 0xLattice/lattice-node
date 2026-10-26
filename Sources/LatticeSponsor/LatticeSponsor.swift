// lattice-sponsor: pays transaction fees, on any chain the node hosts, for
// clients who pay in proof of work. A client with no balance grinds shares of
// this sponsor's merged block template, then sends a draft; the sponsor adds
// a debit of the fee from its own account on the draft's chain and co-signs.
// The client signs the same body and submits it anywhere: it carries a real
// fee.
//
// The template pays the sponsor on Nexus and every hosted chain, so each
// share earns the sponsor on all of them at once. The client earns on the one
// chain it names: each share is credited when it is accepted, at its own
// template's price there (its chance of clearing that chain's block, times
// that block's reward), and a fee is paid from that chain's credit. Credit
// backed by one block height stops at its reward: only one block per height
// can win.
//
// A client can withhold the shares that are blocks, as against any pool;
// nothing here detects it. The float is the operator's bound on that loss.
// A signed fee is held against the float for a few of its chain's blocks,
// but a client may submit its body later than that; the sponsor never pays
// more than one fee per signature, so the cost is another client's
// sponsored transaction failing on an empty float. A chain's reward schedule
// is read once, so a chain re-hosted under the same path with a new genesis
// needs a restart.
//
// It runs beside a node and reaches it only over the loopback RPC, like the
// miner. Its key holds the fee float and nothing else: a co-signature lends
// the key's authority to the body, so the key must own nothing a draft could
// reach. Credit is held in memory; a restart forfeits unspent shares.
//
// Routes (JSON, 64-bit integers as decimal strings, targets and work as hex):
//   POST /work     {client?, chain?}       → a nonce range of the template
//   POST /shares   {assignment, nonce}     → the client's credit on its chain
//   POST /sponsor  {client, transaction}   → the co-signed transaction

import ArgumentParser
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import Lattice
import cashew
import LatticeMinerCore
import LatticeMiningCoordinator
import LatticeNode
import LatticeSponsorCore
import UInt256

@main
struct LatticeSponsorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-sponsor",
        abstract: "Pay transaction fees for clients who pay in proof of work."
    )

    @Option(name: .long, help: "The node's loopback RPC base URL (e.g. http://127.0.0.1:8545).")
    var node: String

    @Option(name: .long, help: "The node's RPC cookie file.")
    var cookieFile: String

    @Option(name: .long, help: "Key file (from `lattice key generate`) holding the fee float on every chain, and nothing else.")
    var key: String

    @Option(name: .long, help: "Work per share, as 2^N or a decimal integer.")
    var shareWork: String = "2^24"

    @Option(name: .long, help: "The smallest fee to pay; the node's relay floor when higher.")
    var fee: UInt64 = 0

    @Option(name: .long, help: "Listen address.")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Listen port.")
    var port: Int = 8650

    func run() async throws {
        guard let work = parseWork(shareWork), work > .zero, work <= maximumRepresentableWork else {
            throw ValidationError("--share-work takes 2^N (N < 256) or a positive decimal integer")
        }
        guard let base = URL(string: node) else { throw ValidationError("--node is not a URL") }
        let signer = try SponsorKey(file: key)
        let rpc = SponsorRPC(base: base, cookieFile: URL(fileURLWithPath: cookieFile))
        let sponsor = Sponsor(
            ledger: SponsorLedger(shareTarget: minimumWorkTarget(work)),
            rpc: rpc,
            key: signer,
            minimumFee: fee,
            tokenKey: SymmetricKey(size: .bits256)
        )
        let templates = HTTPMiningCoordinatorNodeClient(
            apiBaseURL: base, cookieFile: URL(fileURLWithPath: cookieFile)
        )
        let refresh = Task {
            while !Task.isCancelled {
                do {
                    // Hosted chains come and go without a restart.
                    let chains = [ChainAddress.nexus] + (try await rpc.hostedChains())
                    let request = try MiningTemplateRequestBody.make(
                        recipients: chains.map { "\($0)=\(signer.address)" }, minimumWork: []
                    )
                    let fetchedAt = now()
                    if let template = try await rpc.template(request) {
                        await sponsor.install(template, fetchedAt: fetchedAt)
                    }
                } catch {
                    print("template fetch failed: \(error)")
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        defer { refresh.cancel() }

        let router = Router()
        // Wallets call this from web pages. No cookie or credential rides on
        // these requests: a client's token is in its body.
        router.add(middleware: CORSMiddleware(allowOrigin: .all, allowMethods: [.post, .options]))
        router.post("work") { request, context in
            let input = try await request.decode(as: WorkRequest.self, context: context)
            return try await refusing {
                try await sponsor.work(client: input.client, chainPath: input.chainPath)
            }
        }
        router.post("shares") { request, context in
            let input = try await request.decode(as: ShareRequest.self, context: context)
            let (response, block) = await sponsor.share(assignment: input.assignment, nonce: input.nonce)
            if let block {
                do {
                    let submitted = try await templates.submit(workId: block, nonce: input.nonce)
                    print("block \(block) nonce \(input.nonce): \(submitted.disposition)")
                } catch {
                    print("block submit failed: \(error)")
                }
            }
            return try await refusing { try response.get() }
        }
        router.post("sponsor") { request, context in
            let input = try await request.decode(as: SponsorRequest.self, context: context)
            return try await refusing {
                try await sponsor.sponsor(client: input.client, draft: input.transaction.body)
            }
        }
        print("sponsor \(signer.address) listening on \(host):\(port)")
        let app = Application(
            responder: router.buildResponder(),
            configuration: .init(address: .hostname(host, port: port))
        )
        try await app.runService()
    }
}

struct WorkRequest: Decodable {
    let client: String?
    /// The chain the shares are credited on and the fee is quoted on
    /// (default Nexus).
    let chain: String?

    var chainPath: [String] {
        (chain ?? ChainAddress.nexus).components(separatedBy: "/")
    }
}

struct WorkResponse: ResponseEncodable {
    let client: String
    let assignment: String
    let prefixHex: String
    let shareTarget: String
    @DecimalString var startNonce: UInt64
    @DecimalString var count: UInt64
    /// The quoted chain's fee.
    @DecimalString var fee: UInt64
    /// Shares that buy `fee` at the current price, saturating.
    @DecimalString var sharesForFee: UInt64
    @DecimalString var expiresInMilliseconds: UInt64
}

struct ShareRequest: Decodable {
    let assignment: String
    @DecimalString var nonce: UInt64
}

struct ShareResponse: ResponseEncodable {
    /// The client's credit on the assignment's chain, in whole units.
    @DecimalString var credit: UInt64
}

struct SponsorRequest: Decodable {
    let client: String
    /// The draft: one signer (the client), no signatures needed.
    let transaction: ContentBoundTransaction
}

struct SponsorResponse: ResponseEncodable {
    /// The sponsored body with the sponsor's signature; the client adds its
    /// own over the same body and submits.
    let transaction: ContentBoundTransaction
    @DecimalString var fee: UInt64
}

actor Sponsor {
    private var ledger: SponsorLedger
    private let rpc: SponsorRPC
    private let key: SponsorKey
    private let minimumFee: UInt64
    /// Signs the client tokens this sponsor issues, so a client cannot name
    /// (and so spend) a token it was not given.
    private let tokenKey: SymmetricKey
    /// Each chain's reward schedule, read once.
    private var specs: [[String]: ChainSpec] = [:]
    /// Each chain's fee and the sponsor's balance there, read at every
    /// refresh so a request reads nothing from the node.
    private var fees: [[String]: UInt64] = [:]
    private var balances: [[String]: UInt64] = [:]

    init(ledger: SponsorLedger, rpc: SponsorRPC, key: SponsorKey, minimumFee: UInt64, tokenKey: SymmetricKey) {
        self.ledger = ledger
        self.rpc = rpc
        self.key = key
        self.minimumFee = minimumFee
        self.tokenKey = tokenKey
    }

    /// Take `template` as the newest work, priced on every chain whose block
    /// it carries pays this sponsor. A chain whose spec or fee cannot be read
    /// is left unpriced.
    func install(_ template: MiningTemplateResponse, fetchedAt: Int64) async {
        var prices: [[String]: ChainPrice] = [:]
        for chain in template.chains ?? [] where chain.rewardRecipient == key.address {
            if specs[chain.chainPath] == nil {
                specs[chain.chainPath] = try? await rpc.spec(chain.chainPath)
            }
            guard let spec = specs[chain.chainPath],
                  let floor = try? await rpc.relayFloor(on: chain.chainPath),
                  let balance = try? await rpc.balance(of: key.address, on: chain.chainPath) else { continue }
            fees[chain.chainPath] = max(minimumFee, floor)
            balances[chain.chainPath] = balance
            prices[chain.chainPath] = ChainPrice(
                // The node takes no hash above the search target.
                target: min(chain.target, template.searchTarget),
                height: chain.height,
                reward: spec.rewardAtBlock(chain.height)
            )
        }
        if template.chains == nil { print("the node reports no template chains; upgrade it") }
        ledger.install(SponsorTemplate(
            workID: template.workID,
            prefixHex: ProofOfWork.proofOfWorkHashPrefixBytes(template.block)
                .map { String(format: "%02x", $0) }.joined(),
            prices: prices,
            submitTarget: template.searchTarget,
            // From the fetch, not after the reads above: a slow read must
            // not outlive the node's own expiry.
            expiresAt: fetchedAt + Int64(clamping: template.expiresInMilliseconds)
        ), now: now())
    }

    func work(client: String?, chainPath: [String]) throws -> WorkResponse {
        let fee = try currentFee(chainPath)
        let client = try client.map { token in
            guard isIssued(token) else { throw SponsorRefusal.draft("unknown client token") }
            return token
        } ?? issueToken()
        let assignment = try ledger.assign(client: client, on: chainPath, now: now())
        let shares = ledger.sharesFor(fee: fee, on: chainPath) ?? .max
        return WorkResponse(
            client: client,
            assignment: assignment.id,
            prefixHex: assignment.prefixHex,
            shareTarget: assignment.shareTarget.toHexString(),
            startNonce: assignment.startNonce,
            count: assignment.count,
            fee: fee,
            sharesForFee: shares > UInt256(UInt64.max) ? .max : UInt64(shares.words[0]),
            expiresInMilliseconds: UInt64(max(0, assignment.expiresAt - now()))
        )
    }

    /// Credit a share, and name the template it is a block of, if any,
    /// whether or not it was credited.
    func share(assignment: String, nonce: UInt64) -> (Result<ShareResponse, any Error>, String?) {
        guard let held = ledger.assignment(assignment), let prefix = Data(hex: held.prefixHex) else {
            return (.failure(SponsorRefusal.unknownAssignment), nil)
        }
        let hash = ProofOfWork.hash(
            midstate: ProofOfWork.midstate(prefixBytes: ContiguousArray(prefix)), nonce: nonce
        )
        let credited = Result { () throws -> ShareResponse in
            let units = try ledger.credit(assignment: assignment, nonce: nonce, hash: hash, now: now())
                / SponsorLedger.unit
            return ShareResponse(credit: units > UInt256(UInt64.max) ? .max : UInt64(units.words[0]))
        }
        return (credited, ledger.block(assignment: assignment, nonce: nonce, hash: hash))
    }

    func sponsor(client: String, draft: TransactionBody) throws -> SponsorResponse {
        let chainPath = draft.chainPath
        let fee = try currentFee(chainPath)
        let body = try sponsoredBody(
            draft: draft, sponsor: key.address, fee: fee, chainPath: chainPath
        )
        let balance = balances[chainPath] ?? 0
        // A signed fee shows in the balance only once mined; hold it for a
        // few of the chain's blocks.
        let blockTime = Int64(clamping: specs[chainPath]?.targetBlockTime ?? 0)
        let hold = max(600_000, blockTime.multipliedReportingOverflow(by: 3).partialValue)
        try ledger.commit(
            client: client, fee: fee, on: chainPath, balance: balance, holdUntil: now() + hold, now: now()
        )
        let header = try HeaderImpl(node: body)
        guard let signature = TransactionSigning.sign(bodyHeader: header, privateKeyHex: key.privateKey) else {
            throw HTTPError(.internalServerError, message: "signing failed")
        }
        return SponsorResponse(
            transaction: ContentBoundTransaction(signatures: [key.publicKey: signature], body: body),
            fee: fee
        )
    }

    private func currentFee(_ chainPath: [String]) throws -> UInt64 {
        // An expired template means refresh has stopped, and the balance
        // read with it may no longer show fees already mined.
        guard let latest = ledger.latest, now() < latest.expiresAt,
              latest.prices[chainPath] != nil, let fee = fees[chainPath] else {
            throw SponsorRefusal.unpriceable
        }
        guard fee > 0 else {
            throw HTTPError(.conflict, message: "the node admits zero-fee transactions; no sponsor needed")
        }
        return fee
    }


    /// A random identifier and its MAC under `tokenKey`, in hex.
    private func issueToken() -> String {
        let identifier = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        return Self.hex(identifier) + Self.hex(Array(mac(identifier)))
    }

    private func isIssued(_ token: String) -> Bool {
        guard token.count == 64, let bytes = Data(hex: token) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            Array(bytes.suffix(32)), authenticating: Array(bytes.prefix(16)), using: tokenKey
        )
    }

    private func mac(_ identifier: [UInt8]) -> HashedAuthenticationCode<SHA256> {
        HMAC<SHA256>.authenticationCode(for: identifier, using: tokenKey)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Milliseconds since the epoch.
private func now() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

/// A refusal as the client's 4xx; anything else propagates.
func refusing<Value: Sendable>(_ body: () async throws -> Value) async throws -> Value {
    do {
        return try await body()
    } catch let refusal as SponsorRefusal {
        let status: HTTPResponse.Status = switch refusal {
        case .busy, .unpriceable, .insufficientFloat, .soldOut: .serviceUnavailable
        case .insufficientCredit: .init(code: 402, reasonPhrase: "Payment Required")
        default: .badRequest
        }
        throw HTTPError(status, message: "\(refusal)")
    }
}

struct SponsorKey: Sendable {
    let address: String
    let publicKey: String
    let privateKey: String

    init(file path: String) throws {
        struct KeyFile: Decodable {
            let privateKey: String
            let publicKey: String
        }
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0 {
            throw ValidationError("key file \(url.path) is group/other-readable; chmod 600 it")
        }
        let file = try JSONDecoder().decode(KeyFile.self, from: Data(contentsOf: url))
        address = CryptoUtils.createAddress(from: file.publicKey)
        publicKey = file.publicKey
        privateKey = file.privateKey
    }
}

/// The node reads the sponsor needs, over the loopback RPC.
struct SponsorRPC: Sendable {
    let base: URL
    let cookieFile: URL

    /// The child chains the node hosts, as absolute paths.
    func hostedChains() async throws -> [String] {
        struct Hosted: Decodable { let chains: [String] }
        let hosted: Hosted = try await get("hosted-chains", on: [ChainAddress.nexus])
        return hosted.chains
    }

    /// A merged template, or nil while the node has none to give.
    func template(_ body: Data) async throws -> MiningTemplateResponse? {
        var request = authorized(base.appendingPathComponent("mining/templates"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 409 || status == 503 { return nil }
        guard status == 200 else { throw RPCFailure.status(status) }
        return try JSONDecoder().decode(MiningTemplateResponse.self, from: data)
    }

    func spec(_ chainPath: [String]) async throws -> ChainSpec {
        let spec: ExplorerChainSpec = try await get("api/chain/spec", on: chainPath)
        // Only the reward schedule is read from it (`rewardAtBlock`); the
        // explorer view omits the state-growth bound and policies.
        return ChainSpec(
            maxNumberOfTransactionsPerBlock: spec.maxNumberOfTransactionsPerBlock,
            maxStateGrowth: 0,
            maxBlockSize: spec.maxBlockSize,
            premine: spec.premine,
            targetBlockTime: spec.targetBlockTime,
            initialReward: spec.initialReward,
            halvingInterval: spec.halvingInterval,
            halfLife: spec.halfLife
        )
    }

    func relayFloor(on chainPath: [String]) async throws -> UInt64 {
        let fees: ExplorerFees = try await get("api/fees", on: chainPath)
        return fees.minRelayFee
    }

    func balance(of address: String, on chainPath: [String]) async throws -> UInt64 {
        do {
            let account: ExplorerAccount = try await get("api/state/account/\(address)", on: chainPath)
            return account.balance
        } catch RPCFailure.notFound {
            return 0
        }
    }

    enum RPCFailure: Error {
        case notFound
        case status(Int)
    }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let authorization = rpcCookieAuthorization(file: cookieFile) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func get<Value: Decodable>(_ path: String, on chainPath: [String]) async throws -> Value {
        var url = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if chainPath != [ChainAddress.nexus] {
            url?.queryItems = [URLQueryItem(name: "chainPath", value: chainPath.joined(separator: "/"))]
        }
        guard let resolved = url?.url else { throw RPCFailure.status(0) }
        let request = authorized(resolved)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw RPCFailure.notFound }
        guard status == 200 else { throw RPCFailure.status(status) }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

/// `2^N` or a positive decimal integer.
func parseWork(_ text: String) -> UInt256? {
    if text.hasPrefix("2^") {
        guard let exponent = Int(text.dropFirst(2)), (0..<256).contains(exponent) else { return nil }
        return UInt256(1) << exponent
    }
    return UInt64(text).map { UInt256($0) }
}
