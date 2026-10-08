// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatticeNode",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "LatticeNode", targets: ["LatticeNode"]),
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
    ],
    dependencies: [
        .package(
            url: "https://github.com/adalinxx/Lattice.git",
            exact: "45.2.0"
        ),
        .package(
            url: "https://github.com/adalinxx/cashew.git",
            exact: "5.0.0"
        ),
        .package(
            url: "https://github.com/adalinxx/Ivy.git",
            exact: "15.0.0"
        ),
        .package(
            url: "https://github.com/adalinxx/Tally.git",
            exact: "3.1.0"
        ),
        .package(
            url: "https://github.com/adalinxx/VolumeBroker.git",
            exact: "8.0.1"
        ),
        // Lattice's own UInt256, declared for the core's and simulator's direct imports.
        .package(url: "https://github.com/adalinxx/UInt256.git", from: "1.1.0"),
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
            name: "LatticeNode",
            dependencies: [
                "CSQLite",
                "LatticeLightClient",
                "LatticeNodeCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "cashew", package: "cashew"),
            ]),
        .executableTarget(
            name: "LatticeNodeDaemon",
            dependencies: [
                "LatticeNode",
                "LatticeNodeCore",
                "LatticeCtlCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Crypto", package: "swift-crypto"),
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
                "LatticeNode",
                "LatticeCtlCore",
                "LatticeProcessWait",
                "LatticeMinerCore",
                "LatticeMiningCoordinator",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "cashew", package: "cashew"),
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
                .product(name: "Ivy", package: "Ivy"),
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
                "LatticeNode",
                "LatticeNodeDaemon",
                "LatticeCtlCore",
                "LatticeMinerCore",
                "LatticeMiningCoordinatorTool",
                "LatticeMiner",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy"),
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
            name: "LatticeMiningCoordinatorTests",
            dependencies: [
                "LatticeMiningCoordinator",
                "LatticeMinerCore",
            ]),
    ]
)
