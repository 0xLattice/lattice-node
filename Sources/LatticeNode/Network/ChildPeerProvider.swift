import Foundation
import Tally

/// Same-chain peer bootstrap. A *followed* child (one that discovered and
/// self-resolved its genesis from the parent's on-chain `GenesisState`, but was
/// handed no `--peer`) has no same-chain peer to headers-first sync from. The
/// parent chain is the natural rendezvous: every child subscribes to its parent
/// anyway. A child *advertises* `(directory, chain-gossip endpoint)` over the
/// parent-subscription link, and a follower asks the parent for the endpoints of
/// its connected children for a given directory. The directory is self-declared,
/// not proven — and that is safe by **verify-not-trust**: the follower's dial
/// authenticates the identity and consensus validates the chain, so a bogus
/// directory/endpoint costs only a wasted dial (rate-limited at the parent).
///
/// The chain-gossip endpoint must be carried explicitly because it is a
/// deliberately separate identity from the parent-subscription link — reusing one
/// identity across both flaps with duplicate-identity eviction.
///
/// This actor is the request/response correlator + wire format — the exact shape
/// of `ConsensusProvider`, so the protocol is unit-testable without a live
/// network. The serve side (which connected subscribers advertised a directory)
/// needs node + per-network context, so the node owns it and uses this type's
/// static codec; only the client path needs `send`.
public actor ChildPeerProvider {
    public typealias Send = @Sendable (_ peer: PeerID, _ topic: String, _ payload: Data) async -> Void

    /// child → parent, over the parent-subscription link: "my chain-gossip identity
    /// is (pubkey, port)". One-way; the parent stores it against the peer and pairs
    /// it with the observed host. Refreshed on each periodic tick.
    public static let advertiseTopic = "childpeers-advertise"
    /// follower → parent: "give me the chain endpoints of your connected `directory`
    /// children". Served from the live spawn-trusted subscriber set.
    public static let requestTopic = "childpeers-request"
    public static let responseTopic = "childpeers-response"

    private let send: Send
    private let requestTimeout: Duration

    private var nextId: UInt64 = 0
    // Each pending request is BOUND to the peer it was sent to: a response is
    // accepted only if it arrives from that exact peer — without this, any
    // connected peer could forge a response with the (predictable) requestId and
    // feed arbitrary dial targets to a follower. A bogus endpoint only costs a
    // wasted dial (the chain handshake authenticates, consensus validates), but
    // the responder gate keeps even that off the table for non-queried peers.
    private var pending: [UInt64: (peer: PeerID, cont: CheckedContinuation<[String], Never>)] = [:]

    public init(requestTimeout: Duration = .seconds(2), send: @escaping Send) {
        self.requestTimeout = requestTimeout
        self.send = send
    }

    // MARK: - Client (a followed child asks a parent for same-chain peers)

    /// Query `peer` for the chain endpoints of its connected `directory` children.
    /// Returns the advertised `pubkey@host:port` strings, or `[]` on timeout / none.
    /// `ttl` bounds the transitive forward: a follower asks with ttl=1 (the parent may
    /// forward ONCE to its own same-chain peers if it has no direct answer — this is
    /// what makes discovery work at depth, where the immediate parent is a fresh node
    /// that hasn't propagated its peers yet); a forwarded query carries ttl=0 so it is
    /// never re-forwarded (no loops, fan-out bounded to one hop).
    public func requestChildPeers(from peer: PeerID, directory: String, ttl: UInt8 = 1, timeout: Duration? = nil) async -> [String] {
        let id = nextId
        nextId &+= 1
        let payload = Self.encodeRequest(requestId: id, directory: directory, ttl: ttl)
        let waitFor = timeout ?? requestTimeout
        return await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            pending[id] = (peer, cont)
            Task {
                await send(peer, Self.requestTopic, payload)
                try? await Task.sleep(for: waitFor)
                self.timeout(id)
            }
        }
    }

    /// Forwarded sub-requests use a SHORT timeout so a parent that runs the one-hop
    /// transitive forward inside its request handler cannot be made to hold a scarce
    /// gossip-task slot for the full client timeout when its peers don't answer (H1).
    /// The source's parent answers from its direct subscriber set fast; legitimate
    /// answers arrive well within this.
    public static let forwardTimeout: Duration = .milliseconds(400)

    private func timeout(_ id: UInt64) {
        if let entry = pending.removeValue(forKey: id) { entry.cont.resume(returning: []) }
    }

    /// Correlate a response to a pending request — accepted only if `peer` is the
    /// peer the request was sent to (anti-forgery; see `pending`).
    public func handleResponse(_ payload: Data, from peer: PeerID) async {
        guard let resp = Self.decodeResponse(payload) else { return }
        guard let entry = pending[resp.requestId], entry.peer == peer else { return }
        pending.removeValue(forKey: resp.requestId)
        entry.cont.resume(returning: resp.endpoints)
    }

    public func pendingCountForTesting() -> Int { pending.count }

    // MARK: - Wire format (manual, bounded)

    /// A directory is a single trie key; cap it well above any real directory.
    static let maxDirectoryBytes = 256
    /// Bound the returned peer set on the wire — a follower needs only a few
    /// bootstrap endpoints, and the connected-subscriber set is already bounded.
    static let maxEndpoints = 64

    /// Max peers a parent forwards an unanswered query to — bounds amplification to a
    /// single hop times this fan-out, on top of the per-peer request rate limit.
    static let maxForwardFanout = 8

    static func encodeRequest(requestId: UInt64, directory: String, ttl: UInt8 = 1) -> Data {
        var out = Data()
        out.appendUInt64BE(requestId)
        out.appendLPString(String(directory.prefix(maxDirectoryBytes)))
        out.append(ttl)
        return out
    }

    static func decodeRequest(_ data: Data) -> (requestId: UInt64, directory: String, ttl: UInt8)? {
        var r = ByteCursor(data)
        guard let id = r.readUInt64BE(), let dir = r.readLPString(),
              !dir.isEmpty, dir.utf8.count <= maxDirectoryBytes else { return nil }
        let ttl = r.readUInt8() ?? 0  // tolerant: absent (old wire) → no forward
        return (id, dir, ttl)
    }

    static func encodeResponse(requestId: UInt64, endpoints: [String]) -> Data {
        var out = Data()
        out.appendUInt64BE(requestId)
        let capped = endpoints.prefix(maxEndpoints)
        out.appendUInt16BE(UInt16(capped.count))
        for ep in capped { out.appendLPString(ep) }
        return out
    }

    static func decodeResponse(_ data: Data) -> (requestId: UInt64, endpoints: [String])? {
        var r = ByteCursor(data)
        guard let id = r.readUInt64BE(), let count = r.readUInt16BE(), count <= maxEndpoints else { return nil }
        var endpoints: [String] = []
        for _ in 0..<count { guard let s = r.readLPString() else { return nil }; endpoints.append(s) }
        return (id, endpoints)
    }

    // MARK: - Advertise wire (child's directory + chain-gossip endpoint)

    /// A `pubkey@host:port` endpoint; cap well above any real value.
    static let maxEndpointBytes = 512

    /// An advertised rpcUrl is served verbatim to browsers, so accept only an absolute
    /// http(s) URL with a host — reject javascript:/data:/file:/scheme-less strings at BOTH
    /// ends of the wire. Defense in depth; the browser must still verify genesis. (The node
    /// itself never dials this URL — it only relays it.)
    static func isBrowsableHTTPURL(_ s: String) -> Bool {
        guard s.utf8.count <= maxEndpointBytes, let u = URL(string: s),
              let scheme = u.scheme?.lowercased(), u.host != nil else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func encodeAdvertise(directory: String, endpoint: String, rpcUrl: String? = nil) -> Data {
        var out = Data()
        out.appendLPString(String(directory.prefix(maxDirectoryBytes)))
        out.appendLPString(String(endpoint.prefix(maxEndpointBytes)))
        // Optional trailing field (backward-compatible on a live network): the child's
        // public HTTP RPC URL, so a browser can be pointed straight at it. Old decoders
        // read dir+endpoint and stop, ignoring these trailing bytes; new decoders read it.
        // Only appended when it's a valid browsable http(s) URL (garbage is dropped, so the
        // nil/invalid case stays byte-identical to the legacy 2-field wire).
        if let rpcUrl, isBrowsableHTTPURL(rpcUrl) { out.appendLPString(rpcUrl) }
        return out
    }

    static func decodeAdvertise(_ data: Data) -> (directory: String, endpoint: String, rpcUrl: String?)? {
        var r = ByteCursor(data)
        guard let dir = r.readLPString(), !dir.isEmpty, dir.utf8.count <= maxDirectoryBytes,
              let endpoint = r.readLPString(), !endpoint.isEmpty, endpoint.utf8.count <= maxEndpointBytes else { return nil }
        // Tolerant trailing read: absent (old wire) → nil; anything not a browsable http(s)
        // URL → nil (an untrusted peer can't smuggle javascript:/data:/file: to browsers).
        let rpcUrl = r.readLPString().flatMap { isBrowsableHTTPURL($0) ? $0 : nil }
        return (dir, endpoint, rpcUrl)
    }

    // MARK: - Genesis advertise (child → parent: "here is my genesis content; re-serve it")
    //
    // A node serving a child pushes its genesis CAS entries to its parent so the parent durably
    // re-serves them on the PARENT network. Without this, only the original deployer ever pins a
    // child's genesis on the parent; once it leaves, a follower resolving the genesis via the
    // parent network gets `notFound`. The parent MUST verify each entry hashes to its CID and that
    // the genesis block CID matches the ANNOUNCED child genesis before pinning — an untrusted child
    // can't inject a fake/oversized genesis (fails CID re-derivation or the anchor match; bounded).
    public static let genesisTopic = "childgenesis-advertise"
    static let maxGenesisEntries = 512
    static let maxGenesisTotalBytes = 512 * 1024  // genesis closure is small; hard-cap the push

    static func encodeGenesis(directory: String, entries: [(cid: String, data: Data)]) -> Data {
        var out = Data()
        out.appendLPString(String(directory.prefix(maxDirectoryBytes)))
        let capped = entries.prefix(maxGenesisEntries)
        out.appendUInt16BE(UInt16(capped.count))
        for (cid, data) in capped { out.appendLPString(cid); out.appendLPData(data) }
        return out
    }

    static func decodeGenesis(_ data: Data) -> (directory: String, entries: [(cid: String, data: Data)])? {
        guard data.count <= maxGenesisTotalBytes else { return nil }
        var r = ByteCursor(data)
        guard let dir = r.readLPString(), !dir.isEmpty, dir.utf8.count <= maxDirectoryBytes,
              let count = r.readUInt16BE(), count <= maxGenesisEntries else { return nil }
        var entries: [(cid: String, data: Data)] = []
        for _ in 0..<Int(count) {
            guard let cid = r.readLPString(), !cid.isEmpty, let d = r.readLPData() else { return nil }
            entries.append((cid, d))
        }
        return (dir, entries)
    }
}

// MARK: - Minimal big-endian byte helpers (local to the provider wire)

private extension Data {
    mutating func appendUInt64BE(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { append(UInt8((v >> UInt64(shift)) & 0xff)) }
    }
    mutating func appendUInt16BE(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xff)) }
    mutating func appendUInt32BE(_ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { append(UInt8((v >> UInt32(shift)) & 0xff)) }
    }
    mutating func appendLPString(_ s: String) {
        let bytes = Data(s.utf8)
        let n = Swift.min(bytes.count, 0xffff)
        appendUInt16BE(UInt16(n))
        append(bytes.prefix(n))
    }
    mutating func appendLPData(_ d: Data) {
        let n = Swift.min(d.count, Int(UInt32.max))
        appendUInt32BE(UInt32(n))
        append(d.prefix(n))
    }
}

private struct ByteCursor {
    private let data: Data
    private var i: Int
    init(_ data: Data) { self.data = data; self.i = data.startIndex }
    mutating func readUInt8() -> UInt8? {
        guard i < data.endIndex else { return nil }
        defer { i += 1 }
        return data[i]
    }
    mutating func readUInt16BE() -> UInt16? {
        guard let a = readUInt8(), let b = readUInt8() else { return nil }
        return (UInt16(a) << 8) | UInt16(b)
    }
    mutating func readUInt64BE() -> UInt64? {
        var v: UInt64 = 0
        for _ in 0..<8 { guard let b = readUInt8() else { return nil }; v = (v << 8) | UInt64(b) }
        return v
    }
    mutating func readUInt32BE() -> UInt32? {
        var v: UInt32 = 0
        for _ in 0..<4 { guard let b = readUInt8() else { return nil }; v = (v << 8) | UInt32(b) }
        return v
    }
    mutating func readLPData() -> Data? {
        guard let len = readUInt32BE() else { return nil }
        // A UInt32 always fits in Int on a 64-bit platform, so widen to Int and bounds-check.
        // (Do NOT write `len <= UInt32(Int.max)` — Int.max overflows UInt32 and TRAPS at runtime.)
        let n = Int(len)
        guard i + n <= data.endIndex else { return nil }
        let slice = Data(data[i..<i + n])
        i += n
        return slice
    }
    mutating func readLPString() -> String? {
        guard let len = readUInt16BE() else { return nil }
        guard i + Int(len) <= data.endIndex else { return nil }
        let slice = data[i..<i + Int(len)]
        i += Int(len)
        return String(data: slice, encoding: .utf8)
    }
}
