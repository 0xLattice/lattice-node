import ArgumentParser
import Foundation
import Logging

@main
struct LatticeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-node",
        abstract: "The Lattice blockchain node",
        version: "0.1.0",
        subcommands: [
            NodeCommand.self,
            SendCommand.self,
            TxCommand.self,
            ChainCommand.self,
            SwapCommand.self,
            DevnetCommand.self,
            ClusterCommand.self,
            KeysCommand.self,
            StatusCommand.self,
            QueryCommand.self,
            InitCommand.self,
            DiagCommand.self,
            IdentityCommand.self,
            FaucetCommand.self,
        ],
        defaultSubcommand: NodeCommand.self
    )

    // Custom async entry so we can bootstrap swift-log ONCE, before any command runs, at the
    // level selected by LOG_LEVEL. Without a `LoggingSystem.bootstrap`, `Logger(label:)` /
    // `NodeLogger` fall back to the library default (info), so every `.debug` diagnostic — dial
    // attempts, handshake rejects, peer selection, sync decisions — is silently dropped, which is
    // exactly what blinds operators debugging connectivity. This is the standard ArgumentParser
    // pattern for pre-run setup with an AsyncParsableCommand root.
    static func main() async {
        bootstrapLogging()
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    /// Wire swift-log so all node loggers emit at `LOG_LEVEL` (case-insensitive: trace/debug/info/
    /// notice/warning/error/critical), defaulting to `.info` when unset or unrecognized. Logs go to
    /// stderr, matching the existing container log capture.
    private static func bootstrapLogging() {
        let level: Logger.Level = ProcessInfo.processInfo.environment["LOG_LEVEL"]
            .flatMap { Logger.Level(rawValue: $0.lowercased()) } ?? .info
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = level
            return handler
        }
    }
}
