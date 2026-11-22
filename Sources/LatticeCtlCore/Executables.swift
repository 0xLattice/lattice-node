import Foundation
import LatticeNodeConfig

/// This process's own executable, symlinks resolved: the real path, not
/// argv[0], which is a bare name when `lattice` runs through PATH.
public var currentExecutable: URL {
    (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .resolvingSymlinksInPath()
}

/// The executable `name` beside `executable` (symlinks resolved), or in
/// /usr/local/bin: lattice-node, or the miner's lattice-mining-coordinator
/// and lattice-miner, which a miner-only host has without lattice-node.
public func siblingBinary(_ name: String, beside executable: URL = currentExecutable) throws -> URL {
    let own = executable.resolvingSymlinksInPath().deletingLastPathComponent()
    for candidate in [
        own.appendingPathComponent(name),
        URL(fileURLWithPath: "/usr/local/bin/\(name)"),
    ] where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    throw CtlError("\(name) not found beside lattice or in /usr/local/bin")
}
