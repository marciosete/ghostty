import Foundation

/// Something the sidebar orders: a tab, with what it is nested in.
protocol TabSidebarOrderItem: Equatable {
    /// What the tab is in, outermost first: its folder group, its folder, and its group.
    /// Nil where it is in none. Every item has the same number of levels.
    var nestingKeys: [UUID?] { get }
}

/// The order the sidebar keeps the native tabs in, on items that stand for the tabs so
/// it can be checked without windows. At every level, the members of a block (a folder
/// group, a folder, a group) are next to each other, where its first member is, and the
/// blocks inside it are too. A block is in at most one outer block: the caller keeps the
/// keys consistent, giving a group the folder of its first member.
enum TabSidebarOrder {
    /// The sidebar's nesting levels, outermost first.
    enum Level {
        static let folderGroup = 0
        static let folder = 1
        static let group = 2
    }

    /// A folder group, a folder or a group: the level it nests at and its id.
    struct Block: Hashable {
        let level: Int
        let id: UUID

        static func group(_ id: UUID) -> Block { Block(level: Level.group, id: id) }
        static func folder(_ id: UUID) -> Block { Block(level: Level.folder, id: id) }
        static func folderGroup(_ id: UUID) -> Block { Block(level: Level.folderGroup, id: id) }
    }

    /// Where a block is dropped.
    enum Destination<Item> {
        /// Next to a tab, or next to whatever it is in at the moved block's level or
        /// outside it.
        case item(Item)

        /// Next to another block, or whatever it is in at the moved block's level or
        /// outside it. Next to a block with no tabs, such as an empty folder, is the end.
        case block(Block)

        /// After every tab.
        case end
    }

    /// `items` with the members of every block next to each other, each block where its
    /// first member is.
    static func nested<Item: TabSidebarOrderItem>(_ items: [Item]) -> [Item] {
        nested(items, from: 0)
    }

    private static func nested<Item: TabSidebarOrderItem>(_ items: [Item], from level: Int) -> [Item] {
        let depth = items.first?.nestingKeys.count ?? 0
        guard level < depth else { return items }

        var result: [Item] = []
        var seen = Set<Block>()
        for item in items {
            // The outermost block the item is in, from this level on. An item in none is
            // on its own.
            guard let block = block(of: item, from: level) else {
                result.append(item)
                continue
            }
            guard seen.insert(block).inserted else { continue }

            // Items in the same block, but in a block of this level when this one isn't,
            // are elsewhere.
            let members = items.filter { member in
                member.nestingKeys[block.level] == block.id &&
                    (level..<block.level).allSatisfy { member.nestingKeys[$0] == nil }
            }
            result.append(contentsOf: nested(members, from: block.level + 1))
        }
        return result
    }

    /// The outermost block `item` is in at `level` or deeper.
    private static func block<Item: TabSidebarOrderItem>(of item: Item, from level: Int) -> Block? {
        for level in level..<item.nestingKeys.count {
            if let id = item.nestingKeys[level] { return Block(level: level, id: id) }
        }
        return nil
    }

    /// `items` with the members of `block` moved to `destination`, keeping their order,
    /// or nil when the move makes no sense, such as next to one of its own members. The
    /// block moves past whatever the target is in at the block's own level, or outside
    /// it, since a folder doesn't go into a folder. The members keep their keys; the
    /// caller changes those for a block that joined or left an outer one.
    static func order<Item: TabSidebarOrderItem>(
        _ items: [Item],
        moving block: Block,
        to destination: Destination<Item>,
        after: Bool
    ) -> [Item]? {
        let members = items.filter { $0.nestingKeys[block.level] == block.id }
        guard !members.isEmpty else { return nil }
        let others = items.filter { $0.nestingKeys[block.level] != block.id }

        let anchors: [Item]
        switch destination {
        case .item(let target):
            guard target.nestingKeys[block.level] != block.id else { return nil }
            anchors = expand(target, among: others, from: block.level)

        case .block(let target):
            guard target != block else { return nil }
            if let first = others.first(where: { $0.nestingKeys[target.level] == target.id }) {
                anchors = expand(first, among: others, from: block.level)
            } else {
                anchors = []
            }

        case .end:
            anchors = []
        }

        let index: Int
        if anchors.isEmpty {
            index = others.count
        } else if after {
            guard let last = anchors.last, let position = others.firstIndex(of: last) else { return nil }
            index = position + 1
        } else {
            guard let first = anchors.first, let position = others.firstIndex(of: first) else { return nil }
            index = position
        }

        var order = others
        order.insert(contentsOf: members, at: index)
        return order
    }

    /// Everything a block at `level` moves past when dropped next to `target`: the
    /// outermost block `target` is in at that level or deeper, or `target` alone.
    private static func expand<Item: TabSidebarOrderItem>(_ target: Item, among others: [Item], from level: Int) -> [Item] {
        guard let block = block(of: target, from: level) else { return [target] }
        return others.filter { $0.nestingKeys[block.level] == block.id }
    }
}
