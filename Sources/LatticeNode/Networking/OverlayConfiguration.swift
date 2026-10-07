import Ivy

/// The node runtime's one Ivy overlay, from the node configuration.
struct OverlayConfiguration {
    let overlay: IvyConfig

    init(_ configuration: NodeConfiguration) throws {
        try self.init(
            overlay: IvyConfig(
                signingKey: configuration.signingKey,
                listenPort: configuration.listenPort,
                bootstrapPeers: configuration.bootstrapPeers,
                maxConnections: configuration.overlayMaxConnections,
                // Always keep headroom for outbound dials so an inbound burst from
                // a single source cannot exhaust total capacity and starve the
                // dials a node needs to bootstrap/cold-sync. Matters most when the
                // per-netgroup cap is relaxed (proxy-fronted nodes, below).
                reservedOutboundConnectionSlots: min(
                    NodeConfiguration.overlayReservedOutboundSlots,
                    configuration.overlayMaxConnections - 1
                ),
                // Default: permissive (= the total connection cap). This is a
                // PUBLIC plane, and a per-netgroup connection cap is weak defense here: bad
                // data is rejected on CID/PoW verification, the reserved
                // outbound sync slots are protected by a separate inbound
                // ceiling, and behind an L4 proxy every peer shares one address
                // so a low cap just strangles the mesh. Operator-tunable; the
                // real per-source cost for a public direct-IP node is
                // minPeerKeyBits, not this bucket.
                maxConnectionsPerNetgroup: configuration.overlayMaxConnectionsPerNetgroup,
                maxConcurrentContentRequests: configuration.contentServing.maxConcurrent,
                maxConcurrentContentRequestsPerPeer: configuration.contentServing.maxConcurrentPerPeer,
                maxQueuedContentRequestsPerPeer: configuration.contentServing.maxQueuedPerPeer,
                minPeerKeyBits: configuration.minPeerKeyBits,
                maxInFlightVolumeBytes: configuration.contentServing.maxInFlightVolumeBytes,
                // Self-described reachable address: provider announcements and
                // rendezvous records advertise this instead of the observed
                // (NAT/proxy-mangled) one.
                externalAddress: configuration.externalAddress.map {
                    (host: $0, port: configuration.listenPort)
                },
                mode: .overlay
            )
        )
    }

    init(overlay: IvyConfig) throws {
        guard overlay.mode == .overlay,
              overlay.inboundAdmissionBypassPeerKeys.isEmpty
        else {
            throw IvyModeError.invalidConfiguration(
                "network runtime requires an overlay plane"
            )
        }
        try overlay.validate()
        self.overlay = overlay
    }
}
