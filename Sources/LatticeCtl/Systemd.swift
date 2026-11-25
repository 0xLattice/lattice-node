// Host integration: systemd units (or a launchd job) for the tree and, when
// the root holds miner settings (<root>/miner.json), lattice-miner beside it
// (a process of its own, from 0xLattice/lattice-miner). The CLI stays a
// reconciler — restart policy, cgroups, and log routing belong to the init
// system, so the units run the foreground modes. The node exits 0 when asked
// to stop, 75 when asked to restart and 78 when its configuration is
// invalid: systemd restarts it on failure but not on 78
// (`RestartPreventExitStatus`); launchd and Docker have no such setting and
// restart it on 78 too, throttled. The miner is only Wanted by the tree, not
// bound to it: a node restart (exit 75) does not take the miner down, and
// the miner, restarted always, waits out the node's absence itself.

import LatticeNodeAPI
import Foundation
import ArgumentParser
import LatticeNodeConfig

struct EmitSystemd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "emit-systemd",
        abstract: "Print systemd units running this host's tree, and lattice-miner when <root>/miner.json exists, in the foreground."
    )

    @OptionGroup var rootOption: RootOption

    @Option(name: .long, help: "Path of the lattice binary in the units.")
    var binary: String = "/usr/local/bin/lattice"

    @Option(name: .long, help: "Path of the lattice-miner binary in the miner's unit.")
    var minerBinary: String = "/usr/local/bin/lattice-miner"

    func run() async throws {
        let layout = rootOption.layout
        let topology = try Topology.load(root: layout.root).validated()
        let root = layout.root.path
        print("""
        # lattice-tree.service
        [Unit]
        Description=Lattice hosted chain tree (\(1 + (topology.hostedChains?.count ?? 0)) chains)
        After=network-online.target

        [Service]
        ExecStart=\(binary) up --root \(root)
        ExecReload=/bin/kill -HUP $MAINPID
        Restart=on-failure
        RestartPreventExitStatus=78
        TimeoutStopSec=90

        [Install]
        WantedBy=multi-user.target
        """)
        let minerConfig = layout.root.appendingPathComponent("miner.json")
        guard FileManager.default.fileExists(atPath: minerConfig.path) else { return }
        print("""

        # lattice-mine.service
        [Unit]
        Description=Lattice miner (lattice-miner)
        Wants=lattice-tree.service
        After=lattice-tree.service

        [Service]
        ExecStart=\(minerBinary) run --node http://127.0.0.1:\(topology.rpc) --cookie-file \(layout.rpcCookie.path) --config \(minerConfig.path)
        Restart=always
        RestartSec=5
        TimeoutStopSec=90

        [Install]
        WantedBy=multi-user.target
        """)
    }
}

struct EmitLaunchd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "emit-launchd",
        abstract: "Print a launchd job (macOS) running this host's tree in the foreground.",
        discussion: """
        Save it as ~/Library/LaunchAgents/<label>.plist and load it with \
        `launchctl bootstrap gui/$(id -u) <file>`. launchd starts the node again \
        whenever it exits other than 0 (`lattice restart` exits 75), a bad \
        configuration's 78 included, at most every 10 seconds; `lattice down` \
        leaves it stopped. Its log goes to <root>/log/lattice-node.log, which \
        launchd never rotates: truncate it, or rotate it with newsyslog.
        """
    )

    @OptionGroup var rootOption: RootOption

    @Option(name: .long, help: "Path of the lattice binary in the job.")
    var binary: String = "/usr/local/bin/lattice"

    @Option(name: .long, help: "The job's label.")
    var label: String = "build.lattice.node"

    func run() async throws {
        let layout = rootOption.layout
        _ = try Topology.load(root: layout.root).validated()
        let log = layout.logFile(for: "lattice-node").path
        print("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(xmlEscaped(label))</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscaped(binary))</string>
                <string>up</string>
                <string>--root</string>
                <string>\(xmlEscaped(layout.root.path))</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ExitTimeOut</key>
            <integer>90</integer>
            <key>StandardOutPath</key>
            <string>\(xmlEscaped(log))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscaped(log))</string>
        </dict>
        </plist>
        """)
    }

    private func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
