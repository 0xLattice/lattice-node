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
        .library(name: "LatticeMinerCore", targets: ["LatticeMinerCore"]),
        .library(name: "LatticeMiningCoordinator", targets: ["LatticeMiningCoordinator"]),
        .executable(name: "lattice-node", targets: ["LatticeNodeDaemon"]),
        .executable(name: "lattice-miner", targets: ["LatticeMiner"]),
        .executable(
            name: "lattice-mining-coordinator",
            targets: ["LatticeMiningCoordinatorTool"]
        ),
        .executable(
            name: "lattice-proof-verifier",
            targets: ["LatticeProofVerifier"]
        ),
        .executable(
            name: "lattice",
            targets: ["LatticeCtl"]
        ),
        .executable(
            name: "lattice-sponsor",
            targets: ["LatticeSponsor"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/0xLattice/Lattice.git",
            exact: "54.2.1"
        ),
        .package(
            url: "https://github.com/0xLattice/cashew.git",
            exact: "5.0.3"
        ),
        .package(
            url: "https://github.com/0xLattice/Ivy2.git",
            exact: "2.4.1"
        ),
        .package(
            url: "https://github.com/0xLattice/Tally.git",
            exact: "3.1.1"
        ),
        .package(
            url: "https://github.com/0xLattice/VolumeBroker.git",
            exact: "9.2.3"
        ),
        // Lattice's own UInt256, declared for the core's and simulator's direct imports.
        .package(url: "https://github.com/0xLattice/UInt256.git", from: "1.1.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "LatticeLightClient",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
            ]),
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
            ]),
        .target(
            name: "LatticeNodeAPI",
            dependencies: [
                "LatticeLightClient",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]
        ),
        .target(
            name: "LatticeNode",
            dependencies: [
                "LatticeNodeAPI",
                "CSQLite",
                "LatticeLightClient",
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
                "LatticeCtlCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
            ]),
        .executableTarget(
            name: "LatticeProofVerifier",
            dependencies: [
                "LatticeLightClient",
            ]),
        .target(
            name: "LatticeProcessWait"),
        .target(
            name: "LatticeMinerCore",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]),
        .target(
            name: "LatticeMiningCoordinator",
            dependencies: [
                "LatticeMinerCore",
                "LatticeProcessWait",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
            ]),
        .executableTarget(
            name: "LatticeMiningCoordinatorTool",
            dependencies: [
                "LatticeMinerCore",
                "LatticeMiningCoordinator",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .target(
            name: "LatticeCtlCore",
            dependencies: [
                "LatticeNode",
                "LatticeProcessWait",
                .product(name: "Lattice", package: "lattice"),
            ]),
        .executableTarget(
            name: "LatticeCtl",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNode",
                "LatticeCtlCore",
                "LatticeProcessWait",
                "LatticeMinerCore",
                "LatticeMiningCoordinator",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .target(
            name: "LatticeSponsorCore",
            dependencies: [
                "LatticeMinerCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .executableTarget(
            name: "LatticeSponsor",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeMinerCore",
                "LatticeMiningCoordinator",
                "LatticeSponsorCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "LatticeMiner",
            dependencies: [
                "LatticeMinerCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .testTarget(
            name: "LatticeNodeTests",
            dependencies: [
                "LatticeNodeAPI",
                "LatticeNode",
                "LatticeCtlCore",
                "LatticeProcessWait",
                "LatticeNodeDaemon",
                "LatticeMinerCore",
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
        .testTarget(
            name: "LatticeNodeSimulationTests",
            dependencies: [
                "LatticeNodeCore",
                "LatticeNodeSim",
                .product(name: "Lattice", package: "lattice"),
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
                "LatticeMinerCore",
                "LatticeMiningCoordinatorTool",
                "LatticeMiner",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy2"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "cashew", package: "cashew"),
            ],
            path: "Tests/LatticeNodeE2ETests"),
        .testTarget(
            name: "LatticeMinerCoreTests",
            dependencies: [
                "LatticeMinerCore",
                .product(name: "Lattice", package: "lattice"),
            ]),
        .testTarget(
            name: "LatticeSponsorCoreTests",
            dependencies: [
                "LatticeSponsorCore",
                "LatticeMinerCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "UInt256", package: "UInt256"),
            ]),
        .testTarget(
            name: "LatticeMiningCoordinatorTests",
            dependencies: [
                "LatticeMiningCoordinator",
                "LatticeMinerCore",
            ]),
    ]
)
