import XCTest
import Foundation
import Tally
@testable import LatticeNode

private final class ProviderBox: @unchecked Sendable { var provider: ChildPeerProvider? }

/// A minimal stand-in for the node's serve side: a directory → [endpoint] table,
/// with the asker excluded. Mirrors `collectChildPeerEndpoints` without a live node.
private func serve(_ table: [String: [(peer: PeerID, endpoint: String)]], directory: String, asker: PeerID) -> [String] {
    (table[directory] ?? []).filter { $0.peer != asker }.map { $0.endpoint }
}

final class ChildPeerProviderTests: XCTestCase {
    func testRequestWireRoundTrip() {
        let payload = ChildPeerProvider.encodeRequest(requestId: 42, directory: "toy")
        let decoded = ChildPeerProvider.decodeRequest(payload)
        XCTAssertEqual(decoded?.requestId, 42)
        XCTAssertEqual(decoded?.directory, "toy")
    }

    func testGenesisWireRoundTrip() {
        // Regression: a bad `UInt32(Int.max)` bound in readLPData TRAPPED on every decode, crashing
        // the parent on the first genesis advertise it received. This exercises decode → readLPData.
        let entries: [(cid: String, data: Data)] = [
            ("bafyGenesisBlock", Data([0x01, 0x02, 0x03])),
            ("bafySpec", Data(repeating: 0xAB, count: 300)),   // > one LP chunk
            ("bafyTxBody", Data("hello genesis".utf8)),
        ]
        let decoded = ChildPeerProvider.decodeGenesis(ChildPeerProvider.encodeGenesis(directory: "toy", entries: entries))
        XCTAssertEqual(decoded?.directory, "toy")
        XCTAssertEqual(decoded?.entries.map(\.cid), entries.map(\.cid))
        XCTAssertEqual(decoded?.entries.map(\.data), entries.map(\.data))
    }

    func testGenesisRejectsOversizedPayload() {
        // Over the total-bytes cap → nil (fail closed), never a trap.
        let big: [(cid: String, data: Data)] = [("bafyBig", Data(repeating: 0, count: ChildPeerProvider.maxGenesisTotalBytes + 10))]
        XCTAssertNil(ChildPeerProvider.decodeGenesis(ChildPeerProvider.encodeGenesis(directory: "toy", entries: big)))
    }

    func testGenesisRejectsTruncatedAndEmpty() {
        XCTAssertNil(ChildPeerProvider.decodeGenesis(Data()))
        let full = ChildPeerProvider.encodeGenesis(directory: "toy", entries: [("bafyA", Data([1, 2, 3, 4]))])
        XCTAssertNil(ChildPeerProvider.decodeGenesis(full.prefix(full.count - 2)))  // truncated mid-entry → nil, no trap
    }

    func testRequestRejectsEmptyDirectory() {
        // An empty directory is undecodable (fail closed) — never serve "all".
        XCTAssertNil(ChildPeerProvider.decodeRequest(ChildPeerProvider.encodeRequest(requestId: 1, directory: "")))
    }

    func testResponseWireRoundTrip() {
        let eps = ["ed01aa@1.2.3.4:4001", "bb@127.0.0.1:5002"]
        let decoded = ChildPeerProvider.decodeResponse(ChildPeerProvider.encodeResponse(requestId: 9, endpoints: eps))
        XCTAssertEqual(decoded?.requestId, 9)
        XCTAssertEqual(decoded?.endpoints, eps)
        let empty = ChildPeerProvider.decodeResponse(ChildPeerProvider.encodeResponse(requestId: 3, endpoints: []))
        XCTAssertEqual(empty?.requestId, 3)
        XCTAssertEqual(empty?.endpoints, [])
    }

    func testResponseEndpointCapBound() {
        // More endpoints than the wire cap are truncated, and still decode cleanly.
        let many = (0..<200).map { "k\($0)@h:\(1000 + $0)" }
        let decoded = ChildPeerProvider.decodeResponse(ChildPeerProvider.encodeResponse(requestId: 1, endpoints: many))
        XCTAssertEqual(decoded?.endpoints.count, ChildPeerProvider.maxEndpoints)
    }

    func testAdvertiseWireRoundTrip() {
        let adv = ChildPeerProvider.decodeAdvertise(ChildPeerProvider.encodeAdvertise(directory: "toy", endpoint: "k@1.2.3.4:4001"))
        XCTAssertEqual(adv?.directory, "toy")
        XCTAssertEqual(adv?.endpoint, "k@1.2.3.4:4001")
        XCTAssertNil(adv?.rpcUrl) // no rpcUrl advertised → nil
        XCTAssertNil(ChildPeerProvider.decodeAdvertise(ChildPeerProvider.encodeAdvertise(directory: "", endpoint: "k@h:1")))

        // Optional rpcUrl round-trips.
        let withRpc = ChildPeerProvider.decodeAdvertise(
            ChildPeerProvider.encodeAdvertise(directory: "toy", endpoint: "k@1.2.3.4:4001", rpcUrl: "https://toy.example.com"))
        XCTAssertEqual(withRpc?.rpcUrl, "https://toy.example.com")

        // Backward-compat (live-network safe): the nil-rpcUrl encoding is byte-identical to
        // the legacy 2-field wire, and adding an rpcUrl only APPENDS trailing bytes — so old
        // decoders (which read dir+endpoint and ignore the rest) are unaffected.
        let legacy = ChildPeerProvider.encodeAdvertise(directory: "toy", endpoint: "k@1.2.3.4:4001")
        let extended = ChildPeerProvider.encodeAdvertise(directory: "toy", endpoint: "k@1.2.3.4:4001", rpcUrl: "https://toy.example.com")
        XCTAssertGreaterThan(extended.count, legacy.count)
        XCTAssertEqual(Array(extended.prefix(legacy.count)), Array(legacy)) // legacy prefix unchanged

        // Non-http(s) rpcUrls are rejected at both ends — never smuggled to a browser — and
        // the encoding falls back to the byte-identical legacy 2-field wire.
        for bad in ["javascript:alert(1)", "data:text/html,x", "file:///etc/passwd", "toy.example.com", "http:///nohost"] {
            let enc = ChildPeerProvider.encodeAdvertise(directory: "toy", endpoint: "k@1.2.3.4:4001", rpcUrl: bad)
            XCTAssertEqual(Array(enc), Array(legacy), "bad rpcUrl \(bad) should be dropped → legacy wire")
            XCTAssertNil(ChildPeerProvider.decodeAdvertise(enc)?.rpcUrl)
        }

        // Forward-compat: a legacy wire with UNRECOGNIZED trailing bytes still decodes to
        // (dir, endpoint, nil) — the tolerant-trailing property the rolling upgrade rests on.
        var garbage = legacy
        garbage.append(contentsOf: [0xFF, 0x00, 0x07]) // bogus length prefix + stray byte
        let dg = ChildPeerProvider.decodeAdvertise(garbage)
        XCTAssertEqual(dg?.directory, "toy")
        XCTAssertEqual(dg?.endpoint, "k@1.2.3.4:4001")
        XCTAssertNil(dg?.rpcUrl)
    }

    /// Full in-process loopback: the follower asks, the parent serves the matching
    /// directory's connected children, the follower's continuation resolves.
    func testClientServerRoundTripResolves() async {
        let serverBox = ProviderBox(), clientBox = ProviderBox()
        let follower = PeerID(publicKey: "follower"), parent = PeerID(publicKey: "parent")
        let sourceChild = PeerID(publicKey: "sourceChild")
        // The parent's connected toy children (the follower is also one — excluded).
        let table = ["toy": [
            (peer: sourceChild, endpoint: "src@10.0.0.1:4001"),
            (peer: follower, endpoint: "self@10.0.0.2:4001"),
        ]]

        let client = ChildPeerProvider(send: { _, _, payload in
            // Server serves on receipt (asker = the requesting follower, excluded)
            // and replies FROM the queried parent.
            guard let req = ChildPeerProvider.decodeRequest(payload) else { return }
            let eps = serve(table, directory: req.directory, asker: follower)
            let resp = ChildPeerProvider.encodeResponse(requestId: req.requestId, endpoints: eps)
            await clientBox.provider?.handleResponse(resp, from: parent)
        })
        clientBox.provider = client
        _ = serverBox

        let result = await client.requestChildPeers(from: parent, directory: "toy")
        XCTAssertEqual(result, ["src@10.0.0.1:4001"], "the follower's own endpoint is excluded; the source peer is returned")
        let pending = await client.pendingCountForTesting()
        XCTAssertEqual(pending, 0, "the resolved request is removed from pending")
    }

    /// Anti-forgery: a response from a peer OTHER than the one queried is ignored —
    /// otherwise any connected peer could feed a follower arbitrary dial targets.
    func testForgedResponseFromWrongPeerIsIgnored() async {
        let clientBox = ProviderBox()
        let parent = PeerID(publicKey: "parent"), attacker = PeerID(publicKey: "attacker")

        let client = ChildPeerProvider(requestTimeout: .milliseconds(300), send: { _, _, payload in
            guard let req = ChildPeerProvider.decodeRequest(payload) else { return }
            // Race a forged response from the attacker before the real parent answers.
            let forged = ChildPeerProvider.encodeResponse(requestId: req.requestId, endpoints: ["evil@6.6.6.6:6666"])
            await clientBox.provider?.handleResponse(forged, from: attacker)
            let real = ChildPeerProvider.encodeResponse(requestId: req.requestId, endpoints: ["good@1.1.1.1:4001"])
            await clientBox.provider?.handleResponse(real, from: parent)
        })
        clientBox.provider = client

        let result = await client.requestChildPeers(from: parent, directory: "toy")
        XCTAssertEqual(result, ["good@1.1.1.1:4001"], "the forged attacker response is ignored; the real one resolves")
    }

    func testClientTimesOutToEmpty() async {
        let client = ChildPeerProvider(requestTimeout: .milliseconds(100), send: { _, _, _ in })  // never responds
        let result = await client.requestChildPeers(from: PeerID(publicKey: "x"), directory: "toy")
        XCTAssertEqual(result, [], "no response within the timeout ⇒ empty")
        let pending = await client.pendingCountForTesting()
        XCTAssertEqual(pending, 0, "timed-out request is cleared")
    }

    /// The serve filter returns only the requested directory's peers and never the asker.
    func testServeFiltersByDirectoryAndExcludesAsker() {
        let a = PeerID(publicKey: "a"), b = PeerID(publicKey: "b"), asker = PeerID(publicKey: "asker")
        let table = [
            "toy": [(peer: a, endpoint: "a@h:1"), (peer: asker, endpoint: "self@h:2")],
            "other": [(peer: b, endpoint: "b@h:3")],
        ]
        XCTAssertEqual(serve(table, directory: "toy", asker: asker), ["a@h:1"])
        XCTAssertEqual(serve(table, directory: "other", asker: asker), ["b@h:3"])
        XCTAssertEqual(serve(table, directory: "missing", asker: asker), [])
    }

    /// `parseChainEndpoint` accepts raw and ed01-prefixed keys, rejects malformed.
    func testParseChainEndpoint() {
        let raw = LatticeNode.parseChainEndpoint("aabb@1.2.3.4:4001")
        XCTAssertEqual(raw?.publicKey, "aabb")
        XCTAssertEqual(raw?.host, "1.2.3.4")
        XCTAssertEqual(raw?.port, 4001)
        // 64-hex (68 with ed01) is stripped to the raw key.
        let prefixed = "ed01" + String(repeating: "a", count: 64)
        XCTAssertEqual(LatticeNode.parseChainEndpoint("\(prefixed)@h:5")?.publicKey, String(repeating: "a", count: 64))
        XCTAssertNil(LatticeNode.parseChainEndpoint("no-at-sign"))
        XCTAssertNil(LatticeNode.parseChainEndpoint("k@hostonly"))
        XCTAssertNil(LatticeNode.parseChainEndpoint("k@h:notaport"))
    }
}
