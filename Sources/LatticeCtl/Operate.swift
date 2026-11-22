// Operating a node, local or remote: its configuration, restart, pins,
// operator tokens and logs. Each verb asks the node's operator API (loopback
// and cookie under --root, or --node with --token-file); a configuration
// change on a stopped local node is made to its fragment file itself.

import ArgumentParser
import Foundation
import LatticeNodeConfig
import LatticeNodeAPI

struct Config: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read and change the node's configuration: lattice.json and the fragments of config.d, merged.",
        discussion: """
        `set` and `unset` change the `operator` fragment, which comes after every \
        other layer: its values win, and its hosted chains and peers join theirs. \
        A running node applies hosted chains and child peers at once and every \
        other key at its next start (`lattice restart`).
        """,
        subcommands: [Get.self, SetKeys.self, Unset.self]
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the merged configuration, or one key of it (a.b.c), or one fragment.")

        @OptionGroup var target: NodeTarget

        @Option(help: "A fragment as it is (lattice for lattice.json), instead of the merged configuration.")
        var fragment: String?

        @Argument(help: "A key path, e.g. hostedChains.")
        var key: String?

        func run() async throws {
            var value: Any
            if let fragment {
                if let rpc = try await target.running() {
                    value = try ConfigFragments.object(try await send(rpc: rpc, "GET", "config/fragments/\(fragment)"), named: fragment)
                } else {
                    value = try ConfigFragments.object(at: fragment == ConfigFragments.baseName
                        ? target.layout.root.appendingPathComponent(Topology.fileName)
                        : ConfigFragments.file(root: target.layout.root, name: fragment))
                }
            } else {
                let response = try await target.config()
                value = try response.spec.jsonObject()
                for chain in response.status.chains where chain.error != nil {
                    FileHandle.standardError.write(Data("\(chain.path) (\(chain.from.joined(separator: ", "))): \(chain.error!)\n".utf8))
                }
                if !response.status.pendingRestart.isEmpty {
                    FileHandle.standardError.write(Data(
                        "waiting for a restart: \(response.status.pendingRestart.joined(separator: ", "))\n".utf8
                    ))
                }
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
            abstract: "Change keys of the operator fragment: key=value (a.b.c=value; the value is JSON when it parses as JSON), or --patch with a JSON merge patch."
        )

        @OptionGroup var target: NodeTarget

        @Argument(help: "key=value assignments, e.g. minRelayFee=5 stateWindow=128.")
        var assignments: [String] = []

        @Option(help: "An RFC 7396 merge patch of the operator fragment, e.g. '{\"peers\":{\"Nexus/Alpha\":null}}'.")
        var patch: String?

        func run() async throws {
            guard assignments.isEmpty != (patch == nil) else {
                throw ValidationError("give key=value assignments or --patch")
            }
            try await apply(target, patch.map { Data($0.utf8) } ?? ConfigAssignment.patch(setting: assignments))
        }
    }

    struct Unset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove keys (a.b.c) from the operator fragment; another layer's value then holds."
        )

        @OptionGroup var target: NodeTarget

        @Argument(help: "Key paths, e.g. peers.Nexus/Alpha.")
        var keys: [String]

        func run() async throws {
            try await apply(target, ConfigAssignment.patch(unsetting: keys))
        }
    }

    static func apply(_ target: NodeTarget, _ patch: Data) async throws {
        let response = try await target.editFragment(operatorFragment) { object, _ in
            object = try Topology.applying(mergePatch: patch, to: object)
        }
        try report(response)
    }
}

struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replace one fragment of the node's configuration (config.d/<name>.json) with a file.",
        discussion: """
        The node checks the configuration the fragment makes with every other \
        layer and refuses it (changing nothing) when it does not check; then it \
        applies hosted chains and child peers at once and every other key at its \
        next start. Each writer owns one fragment: `deploy` for a deploy script, \
        `operator` for people (`lattice config set`), a tool its own.
        """
    )

    @OptionGroup var target: NodeTarget

    @Option(name: [.short, .customLong("file")], help: "The fragment: one JSON object, keys as in lattice.json.")
    var file: String

    @Option(help: "The fragment's name, e.g. deploy.")
    var fragment: String

    func run() async throws {
        let object = try ConfigFragments.object(at: URL(fileURLWithPath: file))
        let response = try await target.putFragment(fragment, object)
        for chain in response.status.chains where chain.error != nil {
            print("\(chain.path): \(chain.error!)")
        }
        try report(response)
    }
}

struct Restart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Restart the node, applying what waits for a restart: it stops cleanly and exits 75, and whatever runs it starts it again."
    )

    @OptionGroup var target: NodeTarget

    func run() async throws {
        try await restartNode(try await target.runningNode(), "restart")
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the running node's recent log lines (GET /logs), or the local mining loop's.",
        discussion: "The node logs to standard error and keeps its recent lines in memory; a stopped node's log is wherever its process manager put it (journalctl, the launchd log file, docker logs)."
    )

    @OptionGroup var target: NodeTarget

    @Flag(help: "The mining loop's log under --root (`lattice mine start`), instead of the node's.")
    var miner = false

    @Option(help: "How many lines.")
    var tail = 200

    func run() async throws {
        // The miner is a process of its own: its log is on this machine.
        if miner {
            let file = target.layout.logFile(for: "mine")
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            return print(lines.suffix(tail + 1).joined(separator: "\n"), terminator: "")
        }
        guard let rpc = try await target.running() else {
            throw CtlError("the node is not running; its log is wherever its process manager put it (journalctl -u lattice-tree for `lattice emit-systemd`'s unit or -u lattice-node for the checked-in one, the launchd log file, docker logs)")
        }
        FileHandle.standardOutput.write(try await send(rpc: rpc, "GET", "logs?tail=\(tail)"))
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
            let data = try await send(rpc: try await target.runningNode(), "GET", "pins")
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
            let rpc = try await target.runningNode()
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
            try await send(rpc: try await target.runningNode(), "DELETE", "pins/\(cid)")
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
            let data = try await send(rpc: try await target.runningNode(), "GET", "tokens")
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
        @Option(help: "A route it may use instead of a role, as METHOD /path, e.g. \"PUT /config/fragments/{name}\" (repeatable).")
        var route: [String] = []
        @Option(help: "Write the token to this file (mode 0600) instead of printing it.")
        var out: String?

        func run() async throws {
            guard (role == nil) == !route.isEmpty else { throw ValidationError("give --role or --route") }
            let data = try await send(
                rpc: try await target.runningNode(), "POST", "tokens",
                json: JSONEncoder().encode(CreateTokenRequest(name: name, role: role, routes: route.isEmpty ? nil : route))
            )
            let token = try JSONDecoder().decode(CreateTokenResponse.self, from: data).token
            guard let out else { return print(token) }
            try writePrivateFile(Data((token + "\n").utf8), to: out)
            print("token \(name) written to \(out)")
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke a token; it is refused from the next request.")
        @OptionGroup var target: NodeTarget
        @Argument var name: String

        func run() async throws {
            try await send(rpc: try await target.runningNode(), "DELETE", "tokens/\(name)")
            print("revoked \(name)")
        }
    }
}
