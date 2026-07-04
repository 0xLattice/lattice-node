// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LatticeNode",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // keep the floor-removed dependency, now with child-withdrawal
        // balance and parent-homestead builder fixes needed by recursive children.
        // Lattice 13.2.1 = 13.2.0 + TransactionBody.valueConservation.
        // Lattice 13.3.0 = 13.2.1 + Block.makeProofOfWorkPreimagePrefix, the
        // single-source nonce-independent PoW prefix the miner hashes into a
        // midstate (Module 1: PoW preimage ownership).
        // Lattice 13.6.0 = 13.5.0 + ChildBlockProof core + ParentAnchor
        // (Module 6: child-proof MEANING owned by consensus).
        // Lattice 14.0.0 = 13.6.0 + positional directory: ChainSpec.directory
        // removed, genesis anchor stores header/identity (CID) only, child
        // validates its own genesis (#98, #99).
        .package(url: "https://github.com/adalinxx/Lattice.git", exact: "15.0.0"),
        // cashew 3.2.0 = 3.1.0 + Overlay/Composite ContentSource composition
        // adapters (Module 2: generic adapters co-located with the protocol).
        // cashew 3.3.0 = 3.2.0 + Header.walkOwnedSubtree (Module 11: generic
        // owned-subtree edge enumeration; node keeps state-retention policy).
        // cashew 3.4.0 = 3.3.0 + MerkleDictionary.boundedKeysAndValues (fetcher-backed
        // bounded paginated page — used by listDeposits to avoid an O(all-deposits) walk).
        .package(url: "https://github.com/adalinxx/cashew.git", from: "3.4.0"),
        .package(url: "https://github.com/adalinxx/Tally.git", from: "2.0.0"),
        // Ivy 6.4.0: spawn-cert chain transport in the identify handshake
        // (setSpawnCertChain/spawnCertChain(for:)); ⊃ 6.3.0 spawn-cert
        // primitive + volume-fetch attribution + 6.1.0 didIdentifyPeer (#270 ban gate).
        // Ivy 6.6.0 = 6.5.0 + collapse the canonicalKeyHex twin onto
        // Tally.KeyDifficulty (follow-up: single key-work canonicalization).
        // Ivy 6.7.0 = 6.6.0 + eclipse/Sybil hardening: NetGroup (IPv4 /16 +
        // IPv6 /32) closing the IPv6 diversity bypass, netgroup-aware inbound
        // eviction keyed on the observed socket address, per-peer findNode token
        // bucket + PEX accept-cap/responder-score-floor, and an optional
        // Tally-score ranking on selectDiversePeers.
        // Ivy 6.9.0 = 6.8.0 + circuit relay for NAT traversal (Phase 1): relayed
        // connections that carry identify/want/sync transparently, served by
        // relay-enabled nodes, with a direct-then-relay connect fallback.
        // Ivy 6.10.0 = 6.9.0 + relay continuation correlation fix: pending relay
        // requests keyed by (relayPeer, nonce) so concurrent connects through one
        // relay no longer overwrite each other's continuation; relay continuations
        // also drained on teardown.
        // Ivy 6.11.0 = 6.10.0 + relay circuit RENEWAL: the hard 120s circuit lifetime +
        // 128KB total budget black-holed a NAT'd node's long-lived chain gossip (a
        // relay-only follower stalled the instant it crossed 120s/128KB). Now: sliding
        // idle-timeout renewed on activity + per-circuit AND node-wide aggregate byte-RATE
        // caps (DoS-bounded) + 3600s backstop; relayed-conn isLive tracks inbound activity.
        .package(url: "https://github.com/adalinxx/Ivy.git", exact: "6.11.0"),
        // VolumeBroker 3.10.0: retained-root merge for historical state
        // retention, plus retained-root scopes and serve-gate/eviction pins.
        .package(url: "https://github.com/adalinxx/VolumeBroker.git", from: "3.10.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/swift-libp2p/swift-cid.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/swift-libp2p/swift-multihash.git", .upToNextMinor(from: "0.2.1")),
        .package(url: "https://github.com/swiftwasm/WasmKit.git", .upToNextMinor(from: "0.2.0")),
    ],
    targets: [
        .target(
            name: "CSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "LatticeNodeAuth",
            dependencies: []),
        .target(
            name: "LatticeNodeWire",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
            ]),
        .target(
            name: "LatticeNodeRPCFuzzSupport",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
            ]),
        .target(
            name: "LatticeLightClient",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "cashew", package: "cashew"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
            ]),
        .executableTarget(
            name: "LatticeNode",
            dependencies: [
                "CSQLite",
                "LatticeLightClient",
                "LatticeNodeAuth",
                "LatticeNodeWire",
                "LatticeMinerCore",
                "LatticeNodeRPCFuzzSupport",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "Tally", package: "Tally"),
                .product(name: "Ivy", package: "Ivy"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "CID", package: "swift-cid"),
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
            ]),
        .executableTarget(
            name: "LatticeMiningCoordinatorTool",
            dependencies: [
                "LatticeMiningCoordinator",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "LatticeMiner",
            dependencies: [
                "LatticeMinerCore",
                .product(name: "Lattice", package: "lattice"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(
            name: "P2PWireFuzz",
            dependencies: [
                "LatticeNodeWire",
                .product(name: "Ivy", package: "Ivy"),
            ],
            path: "FuzzTargets/P2PWireFuzz"),
        .executableTarget(
            name: "RPCRequestFuzz",
            dependencies: ["LatticeNodeRPCFuzzSupport"],
            path: "FuzzTargets/RPCRequestFuzz"),
        .testTarget(
            name: "LatticeNodeTests",
            dependencies: [
                "LatticeNode",
                "LatticeLightClient",
                "LatticeNodeAuth",
                "LatticeNodeWire",
                "LatticeNodeRPCFuzzSupport",
                "LatticeMinerCore",
                "LatticeMiningCoordinator",
                "CSQLite",
                .product(name: "Ivy", package: "Ivy"),
                .product(name: "VolumeBroker", package: "VolumeBroker"),
                .product(name: "CID", package: "swift-cid"),
                .product(name: "Multihash", package: "swift-multihash"),
                .product(name: "WAT", package: "WasmKit"),
            ]),
    ]
)
