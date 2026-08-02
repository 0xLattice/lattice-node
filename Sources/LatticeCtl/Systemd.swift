// Host integration: systemd units for the tree and the miner. The CLI
// stays a reconciler — restart policy, cgroups, and log routing belong to
// the init system, so the units run the foreground modes.

import Foundation
import ArgumentParser
import LatticeCtlCore

struct EmitSystemd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "emit-systemd",
        abstract: "Print systemd units running this host's tree and miner in the foreground."
    )

    @OptionGroup var rootOption: RootOption

    @Option(name: .long, help: "Path of the lattice binary in the units.")
    var binary: String = "/usr/local/bin/lattice"

    func run() async throws {
        let layout = rootOption.layout
        let topology = try Topology.load(root: layout.root).validated()
        let root = layout.root.path
        print("""
        # lattice-tree.service
        [Unit]
        Description=Lattice chain-process tree (\(topology.chains.count) chains)
        After=network-online.target

        [Service]
        ExecStart=\(binary) up --foreground --root \(root)
        ExecStop=\(binary) down --root \(root)
        Restart=on-failure

        [Install]
        WantedBy=multi-user.target
        """)
        guard topology.mine != nil else { return }
        print("""

        # lattice-mine.service
        [Unit]
        Description=Lattice mining loop
        After=lattice-tree.service
        BindsTo=lattice-tree.service

        [Service]
        ExecStart=\(binary) mine run --root \(root)
        Restart=on-failure
        TimeoutStopSec=90

        [Install]
        WantedBy=multi-user.target
        """)
    }
}
