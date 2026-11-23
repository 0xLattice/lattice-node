import LatticeNodeStore

extension NodeConfiguration {
    /// What the storage reads of this configuration.
    var storeConfiguration: StoreConfiguration {
        StoreConfiguration(
            address: address,
            storagePath: storagePath,
            hostedChildren: hostedChildren,
            childSpecs: childSpecs,
            policyModules: policyModules,
            blockBodies: blockBodies,
            state: state,
            stateWindows: stateWindows,
            resourcePolicy: resourcePolicy
        )
    }
}

extension NodeStorage {
    /// Opens the storage this configuration names (`open(_:)`).
    public static func open(configuration: NodeConfiguration) async throws -> NodeStorage {
        try await open(configuration.storeConfiguration)
    }
}
