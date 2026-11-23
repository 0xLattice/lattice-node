import Foundation
import Lattice
import LatticeNodeConfig
import LatticeNodeCore

/// What the storage reads of the node's settings: where it lives, the tree
/// it holds, and what the operator keeps of blocks and state. The runtime
/// builds it from its `NodeConfiguration` (`NodeStorage.open(configuration:)`).
public struct StoreConfiguration: Sendable {
    public let address: ChainAddress
    public let storagePath: URL
    /// The child chains hosted under the root, parent before child.
    public let hostedChildren: [[String]]
    /// The operator's specs for hosted children, by chain path.
    public let childSpecs: [[String]: ChainSpec]
    /// The operator's WASM policy modules, stored at start.
    public let policyModules: [Data]
    public let blockBodies: BlockBodies
    public let state: StateRetention
    /// With `state: recent`, each chain's state window.
    public let stateWindows: FinalityWindows
    public let resourcePolicy: NodeResourcePolicy

    public init(
        address: ChainAddress,
        storagePath: URL,
        hostedChildren: [[String]],
        childSpecs: [[String]: ChainSpec],
        policyModules: [Data],
        blockBodies: BlockBodies,
        state: StateRetention,
        stateWindows: FinalityWindows,
        resourcePolicy: NodeResourcePolicy
    ) {
        self.address = address
        self.storagePath = storagePath
        self.hostedChildren = hostedChildren
        self.childSpecs = childSpecs
        self.policyModules = policyModules
        self.blockBodies = blockBodies
        self.state = state
        self.stateWindows = stateWindows
        self.resourcePolicy = resourcePolicy
    }

    public var chainPath: [String] { address.components }
    public var nexusGenesisCID: String { NexusGenesis.expectedBlockHash }

    /// The state window of a chain without one of its own.
    public static let defaultStateWindow: UInt64 = 64

    /// The blocks of the chain at `path` whose executions' state is kept,
    /// counting its tip: nil when every state is.
    public func stateWindow(for path: [String]) -> UInt64? {
        Self.stateWindow(for: path, state: state, windows: stateWindows)
    }

    package static func stateWindow(for path: [String], state: StateRetention, windows: FinalityWindows) -> UInt64? {
        switch state {
        case .all: nil
        case .recent: max(1, windows.window(for: path) ?? defaultStateWindow)
        case .none: 1
        }
    }

    public var runtimeContext: ChainRuntimeContext {
        get throws { try Self.runtimeContext(of: address) }
    }

    package static func runtimeContext(of address: ChainAddress) throws -> ChainRuntimeContext {
        // Only the root chain pins its genesis (Lattice §5.1).
        try ChainRuntimeContext(
            path: address.components, genesisCID: address.isNexus ? NexusGenesis.expectedBlockHash : nil
        )
    }
}
