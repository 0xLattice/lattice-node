import LatticeNodeAPI
import LatticeNodeCore

// The node's own templates, as the API reports them. The response types live
// in LatticeNodeAPI, which clients depend on without the node.

extension MiningTemplateResponse {
    package init(
        template: MiningTemplate,
        templateDigest: String
    ) {
        self.init(
            workID: template.workID,
            block: template.block,
            searchTarget: template.searchTarget,
            targets: template.targets,
            chainPath: template.chainPath,
            templateDigest: templateDigest,
            chains: []
        )
    }
}

extension TemplateChainBlock {
    package init(_ chain: TemplateChain) {
        self.init(
            chainPath: chain.chainPath, target: chain.target, height: chain.height,
            rewardRecipient: chain.rewardRecipient
        )
    }
}
