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
            name: "lattice-rewards",
            targets: ["LatticeRewardsTool"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/adalinxx/Lattice.git",
            exact: "27.0.0"
        ),
        .package(
            url: "https://github.com/adalinxx/cashew.git",
            exact: "4.0.2"
        ),
        .package(
            url: "https://github.com/adalinxx/Ivy.git",
            exact: "13.0.0"
        ),
        .package(
            url: "https://github.com/adalinxx/Tally.git",
            exact: "3.0.1"
        ),
        .package(
            url: "https://github.com/adalinxx/VolumeBroker.git",
            exact: "7.0.1"
        ),
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
            name: "LatticeNode",
            dependencies: [
                "CSQLite",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "cashew", package: "cashew"),
            ],
            path: "Sources/LatticeNode/Architecture"),
        .executableTarget(
            name: "LatticeNodeDaemon",
            dependencies: [
                "LatticeNode",
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
            name: "LatticeMinerCore",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ]),
        .target(
            name: "LatticeMiningCoordinator",
            dependencies: [
                "LatticeMinerCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
            ]),
        .executableTarget(
            name: "LatticeMiningCoordinatorTool",
            dependencies: [
                "LatticeMiningCoordinator",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "LatticeRewardsTool",
            dependencies: [
                "LatticeNode",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
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
                "LatticeNodeDaemon",
                "LatticeMinerCore",
                "CSQLite",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Ivy", package: "Ivy"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/LatticeNodeTests/Architecture"),
        .testTarget(
            name: "LatticeNodeE2ETests",
            dependencies: [
                "LatticeNode",
                "LatticeNodeDaemon",
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
