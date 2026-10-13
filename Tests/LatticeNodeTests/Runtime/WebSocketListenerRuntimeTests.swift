import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Ivy
import XCTest
@testable import LatticeNode

#if canImport(Darwin)
import Darwin
private let datagram = SOCK_DGRAM
#else
import Glibc
private let datagram = Int32(SOCK_DGRAM.rawValue)
#endif

/// A started node listens for browsers: WebSocket and STUN on one port.
final class WebSocketListenerRuntimeTests: XCTestCase {
    private func runtime(_ webSocket: WebSocketListener) async throws -> NodeRuntime {
        let directory = temporaryDirectory()
        let port = NetworkTransportTestPorts.allocate()
        let configuration = try NodeConfiguration(
            chainPath: ["Nexus"],
            storagePath: directory,
            privateKeyHex: String(repeating: "5c", count: 32),
            listenPort: port,
            rpcPort: NetworkTransportTestPorts.allocate(),
            webSocket: webSocket
        )
        let runtime = try await NodeRuntime.start(
            storage: try await NodeStorage.open(configuration: configuration),
            configuration: configuration,
            overlay: IvyConfig(
                signingKey: configuration.signingKey, listenPort: port, bootstrapPeers: [],
                requestTimeout: .seconds(5), stunServers: [], healthConfig: PeerHealthConfig(enabled: false),
                mode: .overlay
            )
        )
        addTeardownBlock { await runtime.stop() }
        return runtime
    }

    /// Sends a STUN Binding request to the loopback `port` and returns the
    /// port the answer says it came from, with the port it did come from.
    private func stunMappedPort(at port: UInt16) throws -> (mapped: UInt16, own: UInt16)? {
        let fd = socket(AF_INET, datagram, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var node = sockaddr_in()
        node.sin_family = sa_family_t(AF_INET)
        node.sin_port = port.bigEndian
        node.sin_addr.s_addr = inet_addr("127.0.0.1")
        let transaction: [UInt8] = Array(1...12)
        let request: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xa4, 0x42] + transaction
        let sent = withUnsafePointer(to: &node) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(sent, request.count)

        var reply = [UInt8](repeating: 0, count: 128)
        let received = recv(fd, &reply, reply.count, 0)
        guard received == 32 else { return nil }
        // A success response to this transaction, with XOR-MAPPED-ADDRESS.
        XCTAssertEqual(Array(reply[0..<4]), [0x01, 0x01, 0x00, 0x0c])
        XCTAssertEqual(Array(reply[8..<20]), transaction)
        XCTAssertEqual(Array(reply[20..<26]), [0x00, 0x20, 0x00, 0x08, 0x00, 0x01])
        XCTAssertEqual(
            zip(reply[28..<32], [0x21, 0x12, 0xa4, 0x42] as [UInt8]).map { $0 ^ $1 }, [127, 0, 0, 1])

        var own = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &own) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return ((UInt16(reply[26]) << 8 | UInt16(reply[27])) ^ 0x2112, UInt16(bigEndian: own.sin_port))
    }

    func testAStartedNodeAnswersWebSocketAndSTUNOnItsBrowserPort() async throws {
        let port = NetworkTransportTestPorts.allocate()
        let node = try await runtime(.required(port))

        let answer = try XCTUnwrap(try stunMappedPort(at: port), "STUN is answered")
        XCTAssertEqual(answer.mapped, answer.own)

        // A plain request for the path is told to upgrade to a WebSocket.
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/ivy")))
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 426)

        await node.stop()
        XCTAssertNil(try stunMappedPort(at: port), "and stops with the node")
    }

    func testAPortThatIsTakenStopsOnlyTheNodeThatRequiredIt() async throws {
        let port = NetworkTransportTestPorts.allocate()
        _ = try await runtime(.required(port))

        // The default: a second node on the machine starts without it.
        _ = try await runtime(.ifAvailable(port))
        do {
            _ = try await runtime(.required(port))
            XCTFail("a node that required a taken port started")
        } catch {}
    }
}
