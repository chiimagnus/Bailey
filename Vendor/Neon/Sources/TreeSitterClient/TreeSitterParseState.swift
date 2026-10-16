import Foundation
import SwiftTreeSitter

struct TreeSitterParseState {
    var tree: MutableTree?

    init(tree: MutableTree? = nil) {
        self.tree = tree
    }

    func applyEdit(_ edit: InputEdit) {
        tree?.edit(edit)
    }

    func changedByteRanges(for otherState: TreeSitterParseState) -> [Range<UInt32>] {
        let otherTree = otherState.tree

        switch (tree, otherTree) {
        case (let t1?, let t2?):
            return t1.changedRanges(from: t2).map({ $0.bytes })
        case (nil, let t2?):
            let range = t2.rootNode?.byteRange

            return range.flatMap({ [$0] }) ?? []
        case (_, nil):
            return []
        }
    }

    func copy() -> TreeSitterParseState {
        return TreeSitterParseState(tree: tree?.mutableCopy())
    }
}
