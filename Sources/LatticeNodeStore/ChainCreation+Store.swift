import Foundation
import LatticeNodeAPI
import LatticeNodeConfig

extension ChainCreation {
    /// `create`, asking this node's store whether it holds the chain.
    @discardableResult
    public static func create(_ chain: HostedChain, layout: HostLayout) throws -> Bool {
        try create(chain, layout: layout) { chainPath in
            try NodeStore.holdsBlocks(of: chainPath, storage: layout.chainDirectory(for: ChainAddress.nexus))
        }
    }
}
