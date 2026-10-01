import Lattice
import UInt256

/// One piece of miner work: the candidate block (nonce 0) and the search
/// target a submitted nonce must clear. The shell's template job assembles it
/// (the transaction fit, the child candidates and the minimum-work search
/// target); the book only issues it and checks submissions against it.
public struct WorkTemplate: Sendable {
    public let workID: String
    public let block: Block
    public let searchTarget: UInt256
    /// Every threshold a nonce for this work can clear, easiest first.
    public let targets: [UInt256]
    /// The executed tip the block builds on.
    public let tipCID: String
    /// The pool version the job read its transactions from.
    public let poolVersion: UInt64
    /// Milliseconds since the epoch.
    public let expiresAt: Int64

    public init(
        workID: String,
        block: Block,
        searchTarget: UInt256,
        targets: [UInt256],
        tipCID: String,
        poolVersion: UInt64,
        expiresAt: Int64
    ) {
        self.workID = workID
        self.block = block
        self.searchTarget = searchTarget
        self.targets = targets
        self.tipCID = tipCID
        self.poolVersion = poolVersion
        self.expiresAt = expiresAt
    }
}

public enum TemplateError: Error, Sendable, Equatable {
    case unknownWork
    case expired
    case missesSearchTarget
    /// The template job could not build a block on the tip.
    case buildFailed
    /// Too many template requests are waiting.
    case busy
    /// Retriable: the executed tip moved more than `maxReissues` times while
    /// the request waited (the actor's `templateContextChanged`).
    case contextChanged
}

/// The bounded work cache for external miners, as a value. It never searches
/// a nonce. The same rules as the shell's `MiningTemplateBook` actor, with
/// time passed in: capacity is least-recently-issued first out, and a live
/// template keeps its work ID against a later one with the same ID.
public struct TemplateBook: Sendable {
    public let lifetime: Int64
    public let capacity: Int
    private var templates: [String: WorkTemplate] = [:]
    private var order: [String] = []

    public init(lifetime: Int64 = 30_000, capacity: Int = 16) {
        precondition(capacity > 0 && lifetime > 0)
        self.lifetime = lifetime
        self.capacity = capacity
    }

    public var count: Int { templates.count }

    public func template(_ workID: String) -> WorkTemplate? { templates[workID] }

    /// Issue `template`, or the live one already issued under its work ID,
    /// and mark it most recently issued.
    @discardableResult
    public mutating func issue(_ template: WorkTemplate, now: Int64) -> WorkTemplate {
        order.removeAll { $0 == template.workID }
        order.append(template.workID)
        if let existing = templates[template.workID], now < existing.expiresAt {
            return existing
        }
        templates[template.workID] = template
        while order.count > capacity {
            templates.removeValue(forKey: order.removeFirst())
        }
        return template
    }

    public mutating func discard(workID: String) {
        templates.removeValue(forKey: workID)
        order.removeAll { $0 == workID }
    }

    /// The block a miner's nonce makes of `workID`'s template, if the grind
    /// clears the template's search target. An expired template is dropped.
    public mutating func submission(workID: String, nonce: UInt64, now: Int64) throws -> Block {
        guard let template = templates[workID] else { throw TemplateError.unknownWork }
        guard now < template.expiresAt else {
            discard(workID: workID)
            throw TemplateError.expired
        }
        let candidate = template.block.replacingNonce(nonce)
        // Lattice's proof-of-work predicate, against the search target: a
        // zero target is met by no hash (`Block.validateProofOfWork`).
        guard template.searchTarget > .zero, candidate.proofOfWorkHash() <= template.searchTarget else {
            throw TemplateError.missesSearchTarget
        }
        return candidate
    }

    public mutating func invalidateAll() {
        templates.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }
}

extension Block {
    func replacingNonce(_ nonce: UInt64) -> Block {
        Block(
            version: version,
            parent: parent,
            transactions: transactions,
            target: target,
            nextTarget: nextTarget,
            spec: spec,
            parentState: parentState,
            prevState: prevState,
            postState: postState,
            children: children,
            height: height,
            timestamp: timestamp,
            rewardRecipient: rewardRecipient,
            nonce: nonce
        )
    }
}
