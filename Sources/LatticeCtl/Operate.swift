// Operating a node, local or remote: its configuration, restart, pins,
// operator tokens and logs. Each verb asks the node's operator API (loopback
// and cookie under --root, or --node with --token-file); a configuration
// change on a stopped local node is made to lattice.json itself.

import ArgumentParser
import Foundation
import LatticeCtlCore
import LatticeNodeAPI

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read and change the node's configuration (lattice.json, which the running node owns).",
        subcommands: [Get.self, SetKeys.self, Unset.self]
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the configuration, or one key of it (a.b.c).")

        @OptionGroup var target: NodeTarget

        @Argument(help: "A key path, e.g. mine.recipients.")
        var key: String?

        func run() async throws {
            var value: Any
            if let rpc = try target.running() {
                let data = try await send(rpc: rpc, "GET", "config")
                let response = try JSONDecoder().decode(ConfigResponse.self, from: data)
                value = try response.config.jsonObject()
                if !response.restartRequired.isEmpty {
                    FileHandle.standardError.write(Data(
                        "waiting for a restart: \(response.restartRequired.joined(separator: ", "))\n".utf8
                    ))
                }
            } else {
                value = try Topology.load(root: target.layout.root).jsonObject()
            }
            for part in (key ?? "").split(separator: ".") {
                guard let inner = (value as? [String: Any])?[String(part)] else {
                    throw CtlError("\(key ?? "") is not set")
                }
                value = inner
            }
            let data = try JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
            )
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct SetKeys: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Change keys: key=value (a.b.c=value; the value is JSON when it parses as JSON), or --patch with a JSON merge patch.",
            discussion: "A running node applies hosted chains, child peers and mining at once and keeps every other key for its next start (`lattice restart`)."
        )

        @OptionGroup var target: NodeTarget

        @Argument(help: "key=value assignments, e.g. mine.recipients.Nexus=<address> stateWindow=128.")
        var assignments: [String] = []

        @Option(help: "An RFC 7396 merge patch of lattice.json, e.g. '{\"mine\":{\"recipients\":{\"Nexus/Alpha\":null}}}'.")
        var patch: String?

        func run() async throws {
            guard assignments.isEmpty != (patch == nil) else {
                throw ValidationError("give key=value assignments or --patch")
            }
            try await apply(target, patch.map { Data($0.utf8) } ?? ConfigAssignment.patch(setting: assignments))
        }
    }

    struct Unset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove keys (a.b.c).")

        @OptionGroup var target: NodeTarget

        @Argument(help: "Key paths, e.g. mine.recipients.Nexus.")
        var keys: [String]

        func run() async throws {
            try await apply(target, ConfigAssignment.patch(unsetting: keys))
        }
    }

    static func apply(_ target: NodeTarget, _ patch: Data) async throws {
        try await target.changeConfig(api: { rpc in
            try await sendChange(rpc: rpc, "PATCH", "config", json: patch, contentType: "application/merge-patch+json")
        }, stopped: { topology in
            topology = try topology.applying(mergePatch: patch)
            print("saved; the node reads it at its next start")
        })
    }
}

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restart the node in place (same process, same arguments), applying what waits for a restart."
    )

    @OptionGroup var target: NodeTarget

    func run() async throws {
        let rpc = try target.runningNode()
        try await send(rpc: rpc, "POST", "restart", json: Data("{}".utf8))
        print("restarting")
        try await waitForRestart(rpc)
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the node's recent log lines, or the mining loop's.")

    @OptionGroup var target: NodeTarget

    @Flag(help: "The mining loop's log instead of the node's.")
    var miner = false

    @Option(help: "How many lines.")
    var tail = 200

    func run() async throws {
        let name = miner ? "mine" : "node"
        if let rpc = try target.running() {
            let data = try await send(rpc: rpc, "GET", "logs?file=\(name)&tail=\(tail)")
            FileHandle.standardOutput.write(data)
        } else {
            let file = target.layout.logFile(for: miner ? "mine" : "lattice-node")
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            print(lines.suffix(tail + 1).joined(separator: "\n"), terminator: "")
        }
    }
}

struct Pins: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "The Volumes the node holds, serves and announces for its operator.",
        subcommands: [List.self, Add.self, Remove.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the pinned Volumes.")
        @OptionGroup var target: NodeTarget

        func run() async throws {
            let data = try await send(rpc: try target.runningNode(), "GET", "pins")
            for pin in try JSONDecoder().decode(PinList.self, from: data).pins { print(pin) }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pin a Volume by its root CID; with --fetch, read it from peers first when the node does not hold it."
        )
        @OptionGroup var target: NodeTarget
        @Argument var cid: String
        @Flag(help: "Read the Volume from peers (GET /fetch) and pin what was read.")
        var fetch = false

        func run() async throws {
            let rpc = try target.runningNode()
            let body = fetch
                ? try await send(rpc: rpc, "GET", "fetch/\(cid)")
                : try JSONSerialization.data(withJSONObject: ["cid": cid])
            try await send(rpc: rpc, "POST", "pins", json: body)
            print("pinned \(cid)")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Unpin a Volume.")
        @OptionGroup var target: NodeTarget
        @Argument var cid: String

        func run() async throws {
            try await send(rpc: try target.runningNode(), "DELETE", "pins/\(cid)")
            print("unpinned \(cid)")
        }
    }

    private struct PinList: Decodable { let pins: [String] }
}

struct Tokens: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Bearer tokens for the node's remote operator listener (operatorListen).",
        subcommands: [List.self, Create.self, Revoke.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List each token's name and what it may use.")
        @OptionGroup var target: NodeTarget

        func run() async throws {
            let data = try await send(rpc: try target.runningNode(), "GET", "tokens")
            for token in try JSONDecoder().decode(TokensResponse.self, from: data).tokens {
                print("\(token.name): \(token.role ?? (token.routes ?? []).joined(separator: ", "))")
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make a token; it is printed this once (the node keeps only its SHA-256)."
        )
        @OptionGroup var target: NodeTarget
        @Argument var name: String
        @Option(help: "admin (every route) or read (every GET).")
        var role: String?
        @Option(help: "A route it may use instead of a role, as METHOD /path, e.g. \"POST /hosted-chains\" (repeatable).")
        var route: [String] = []
        @Option(help: "Write the token to this file (mode 0600) instead of printing it.")
        var out: String?

        func run() async throws {
            guard (role == nil) == !route.isEmpty else { throw ValidationError("give --role or --route") }
            let data = try await send(
                rpc: try target.runningNode(), "POST", "tokens",
                json: JSONEncoder().encode(CreateTokenRequest(name: name, role: role, routes: route.isEmpty ? nil : route))
            )
            let token = try JSONDecoder().decode(CreateTokenResponse.self, from: data).token
            guard let out else { return print(token) }
            guard FileManager.default.createFile(
                atPath: out, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600]
            ) else { throw CtlError("could not write \(out)") }
            print("token \(name) written to \(out)")
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke a token; it is refused from the next request.")
        @OptionGroup var target: NodeTarget
        @Argument var name: String

        func run() async throws {
            try await send(rpc: try target.runningNode(), "DELETE", "tokens/\(name)")
            print("revoked \(name)")
        }
    }
}
