// Host integration: a systemd unit for the tree. Restart policy, cgroups
// and log routing belong to the init system, so the unit runs the
// foreground mode; mining is the node's own child (mine.enabled).

import Foundation
import ArgumentParser
import LatticeCtlCore

struct EmitSystemd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "emit-systemd",
        abstract: "Print the systemd unit running this host's tree in the foreground (mining included, as lattice.json says)."
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
        Description=Lattice hosted chain tree (\(1 + (topology.hostedChains?.count ?? 0)) chains)
        After=network-online.target

        [Service]
        ExecStart=\(binary) up --foreground --root \(root)
        ExecStop=\(binary) down --root \(root)
        Restart=on-failure

        [Install]
        WantedBy=multi-user.target
        """)
    }
}
