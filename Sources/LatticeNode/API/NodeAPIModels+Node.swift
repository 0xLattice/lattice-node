import LatticeNodeAPI
import LatticeNodeCore

// The node's own templates, as the API reports them. The response types live
// in LatticeNodeAPI, which clients depend on without the node.

extension MiningTemplateResponse {
    init(
        template: MiningTemplate,
        maximumLifetimeMilliseconds: UInt64,
        templateDigest: String
    ) {
        self.init(
            workID: template.workID,
            block: template.block,
            searchTarget: template.searchTarget,
            targets: template.targets,
            chainPath: template.chainPath,
            expiresInMilliseconds: min(
                maximumLifetimeMilliseconds,
                template.remainingLifetimeMilliseconds
            ),
            templateDigest: templateDigest,
            chains: []
        )
    }
}

extension TemplateChainBlock {
    init(_ chain: TemplateChain) {
        self.init(
            chainPath: chain.chainPath, target: chain.target, height: chain.height,
            rewardRecipient: chain.rewardRecipient
        )
    }
}
