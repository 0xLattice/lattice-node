// `adopt` joins an EXISTING child permissionlessly: every genesis under its
// directory is a root the child level weighs by its proofs, and fork choice
// picks among them. There is no deploy record on the parent.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ArgumentParser
import LatticeCtlCore

struct Child: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Adopt an existing child chain.",
        subcommands: [Adopt.self]
    )

    struct Adopt: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Join an existing child chain through the local parent."
        )

        @OptionGroup var rootOption: RootOption

        @Argument(help: "Absolute child path (e.g. Nexus/Payments).")
        var path: String

        func run() async throws {
            let layout = rootOption.layout
            // Load, add, save and restart under the spawn lock, so a
            // concurrent deploy or adopt cannot lose this entry.
            let restarted = try await withSpawnLock(layout) {
                var topology = try Topology.load(root: layout.root).validated()
                guard topology.chains[path] == nil else {
                    throw CtlError("\(path) is already in the tree")
                }
                let ports = nextFreePorts(topology)
                topology.chains[path] = TopologyChain(
                    listen: ports.0, rpc: ports.1, peers: nil
                )
                _ = try topology.validated()
                try topology.save(root: layout.root)
                return try await restartHostIfRunningLocked(layout)
            }
            guard restarted else {
                print("\(path): added; `lattice up` starts it")
                return
            }
            print("\(path): started; awaiting authenticated genesis from the parent")
        }
    }
}

/// Free means free on this HOST, not merely absent from the file: another
/// root's tree (or a lingering process) may hold a port the topology has
/// never heard of, and a child that cannot bind dies at launch while health
/// probes silently hit the squatter.
func nextFreePorts(_ topology: Topology) -> (UInt16, UInt16) {
    let used = topology.chains.values.flatMap { [$0.listen, $0.rpc] }
    var base: UInt16 = 4101
    while used.contains(base) || used.contains(base + 2)
        || !portIsBindable(base) || !portIsBindable(base + 2) {
        base += 100
    }
    return (base, base + 2)
}

func portIsBindable(_ port: UInt16) -> Bool {
    #if canImport(Darwin)
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Foundation.bind(
                descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)
            )
        }
    } == 0
}

func post<Body: Encodable, Response: Decodable>(
    rpc: UInt16, path: String, body: Body
) async throws -> Response {
    guard let url = URL(string: "http://127.0.0.1:\(rpc)/\(path)") else {
        throw CtlError("bad RPC URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode) else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let detail = String(decoding: data.prefix(512), as: UTF8.self)
        throw CtlError("\(path) failed: HTTP \(status) \(detail)")
    }
    return try JSONDecoder().decode(Response.self, from: data)
}
