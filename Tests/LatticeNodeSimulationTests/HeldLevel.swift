@testable import LatticeNodeCore

extension ChainCore {
    /// A copy of the level to hold while its host steps on: its own tree.
    var held: ChainCore {
        var copy = self
        copy.tree = copy.tree.detached()
        return copy
    }
}
