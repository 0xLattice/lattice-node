// lattice: operator front door for a host's chain-process tree.
//
// Verbs are orthogonal along the architecture's own separations: the tree
// (init/up/down/status/wipe), identity/custody (identity; reward signing
// stays in lattice-rewards), and roles (mine). Every verb reconciles the
// declarative topology in lattice.json; none holds resident state.

import Foundation
import ArgumentParser
import Crypto
import Ivy
import Lattice
import LatticeCtlCore
import LatticeNode

@main
struct LatticeCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice",
        abstract: "Bring up and operate a multi-chain Lattice host.",
        subcommands: [
            Init.self, Up.self, Down.self, Status.self,
            Identity.self, Wipe.self, Mine.self, Child.self, EmitSystemd.self,
        ]
    )
}

struct RootOption: ParsableArguments {
    @Option(name: .long, help: "Host data root (default: current directory).")
    var root: String?

    var layout: HostLayout { HostLayout(root: root) }
}

func loadOrCreateIdentity(at url: URL) throws -> String {
    let manager = FileManager.default
    if manager.fileExists(atPath: url.path) {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        if let permissions = attributes[.posixPermissions] as? NSNumber,
           permissions.intValue & 0o077 != 0 {
            throw CtlError("identity key \(url.path) is group/other-readable; chmod 600 it")
        }
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 64, Data(hex: value) != nil else {
            throw CtlError("malformed identity key at \(url.path)")
        }
        return value.lowercased()
    }
    try manager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let key = Curve25519.Signing.PrivateKey()
    let value = key.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    guard manager.createFile(
        atPath: url.path,
        contents: Data((value + "\n").utf8),
        attributes: [.posixPermissions: 0o600]
    ) else {
        throw CtlError("could not create identity key at \(url.path)")
    }
    return value
}

func publicKey(ofIdentity url: URL) throws -> String {
    let privateHex = try loadOrCreateIdentity(at: url)
    let key = try Curve25519.Signing.PrivateKey(
        rawRepresentation: Data(hex: privateHex)!
    )
    return try PeerKey(
        rawRepresentation: key.publicKey.rawRepresentation
    ).hex
}

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scaffold a host: directories, identities, and lattice.json."
    )

    @OptionGroup var rootOption: RootOption

    @Option(name: .long, help: "Overlay bootstrap peer as publicKey@host:port. Repeatable.")
    var peer: [String] = []

    func run() async throws {
        let layout = rootOption.layout
        guard !FileManager.default.fileExists(
            atPath: layout.root.appendingPathComponent(Topology.fileName).path
        ) else {
            throw CtlError("\(Topology.fileName) already exists; edit it directly")
        }
        let topology = try Topology(
            chains: ["Nexus": TopologyChain(
                listen: 4001, fact: 4002, rpc: 8080,
                peers: peer.isEmpty ? nil : peer
            )],
            mine: nil
        ).validated()
        try topology.save(root: layout.root)
        let pubkey = try publicKey(
            ofIdentity: layout.identityKey(for: "Nexus")
        )
        print("initialized \(layout.root.path)")
        print("Nexus identity: \(pubkey)")
        print("peer string:    \(pubkey)@<this-host>:4001")
    }
}

struct Identity: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show each chain process's public key and peer string."
    )

    @OptionGroup var rootOption: RootOption

    func run() async throws {
        let layout = rootOption.layout
        let topology = try Topology.load(root: layout.root).validated()
        for path in topology.orderedPaths() {
            let pubkey = try publicKey(
                ofIdentity: layout.identityKey(for: path)
            )
            let listen = topology.chains[path]!.listen
            print("\(path): \(pubkey)@<this-host>:\(listen)")
        }
    }
}
