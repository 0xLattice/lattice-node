// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatticeNode",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "LatticeNode", targets: ["LatticeNode"]),
        .library(name: "LatticeNodeAPI", targets: ["LatticeNodeAPI"]),
        .executable(name: "lattice-node", targets: ["LatticeNodeDaemon"]),
        .executable(
            name: "lattice",
            targets: ["LatticeCtl"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/0xLattice/Lattice.git",
            exact: "59.3.0"
        ),
        .package(
            url: "https://github.com/0xLattice/cashew.git",
            exact: "5.2.0"
        ),
        .package(
            url: "https://github.com/0xLattice/Ivy2.git",
            exact: "3.3.0"
        ),
        .package(
            url: "https://github.com/0xLattice/Tally.git",
            exact: "4.0.0"
        ),
        .package(
            url: "https://github.com/0xLattice/VolumeBroker.git",
            exact: "10.3.4"
        ),
        // Lattice's own UInt256, declared for the core's and simulator's direct imports.
        .package(url: "https://github.com/0xLattice/UInt256.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "LatticeNodeCore",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .target(
            name: "LatticeNodeSim",
            dependencies: [
                "LatticeNodeCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tools/LatticeNodeSim"),
        .target(
            name: "LatticeNodeAPI",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]
        ),
        .target(
            name: "LatticeNodeConfig",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNodeCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .target(
            name: "LatticeNodeSupport",
            dependencies: [
                .product(name: "cashew", package: "cashew"),
            ]),
        .target(
            name: "LatticeNodeStore",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNodeSupport",
                "LatticeNodeCore",
                "LatticeNodeConfig",
                "CSQLite",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .target(
            name: "LatticeNodeNet",
            dependencies: [
                "LatticeNodeSupport",
                "LatticeNodeCore",
                "LatticeNodeConfig",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "cashew", package: "cashew"),
            ]),
        .target(
            name: "LatticeNodeMining",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNodeConfig",
                "LatticeNodeCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .target(
            name: "LatticeNodeReads",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNodeCore",
                "LatticeNodeNet",
                "LatticeNodeStore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "cashew", package: "cashew"),
            ]),
        .target(
            name: "LatticeNode",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNodeMining",
                "LatticeNodeNet",
                "LatticeNodeReads",
                "LatticeNodeConfig",
                "LatticeNodeStore",
                "LatticeNodeSupport",
                "LatticeNodeCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "IvyWebSocket", package: "Ivy2"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "cashew", package: "cashew"),
            ]),
        .executableTarget(
            name: "LatticeNodeDaemon",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNode",
                "LatticeNodeCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
            ]),
        .target(
            name: "LatticeCtlCore",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNodeConfig",
                .product(name: "Lattice", package: "lattice"),
            ]),
        .executableTarget(
            name: "LatticeCtl",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNodeConfig",
                "LatticeNodeCore",
                "LatticeNodeStore",
                "LatticeCtlCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        // The sync benchmark counts SQLite writes, commits and syncs with it;
        // the crash tests stop every write at a point with it.
        .target(name: "BenchVFS", path: "Tests/BenchVFS", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(
            name: "LatticeNodeTests",
            dependencies: [
                "LatticeNodeNet",
                "BenchVFS",
                "LatticeNodeAPI",
                "LatticeNode",
                "LatticeCtlCore",
                "LatticeNodeDaemon",
                "LatticeNodeSim",
                "LatticeNodeCore",
                "CSQLite",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "LatticeBlockTree", package: "lattice"),
                .product(name: "LatticeProofs", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/LatticeNodeTests"),
        // The sync benchmark (Benchmarks/sync): opt-in, skipped unless CHILD_BENCH is set.
        .testTarget(
            name: "ChildSyncBench",
            dependencies: [
                "BenchVFS",
                "LatticeNode",
                "LatticeNodeAPI",
                "LatticeNodeCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "UInt256", package: "UInt256"),
            ],
            path: "Benchmarks/ChildSyncBench"),
        .testTarget(
            name: "LatticeNodeSimulationTests",
            dependencies: [
                "LatticeNodeCore",
                "LatticeNodeSim",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "LatticeBlockTree", package: "lattice"),
                .product(name: "LatticeProofs", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .testTarget(
            name: "LatticeNodeE2ETests",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNode",
                "LatticeNodeDaemon",
                "LatticeCtlCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ],
            path: "Tests/LatticeNodeE2ETests"),
    ]
)
