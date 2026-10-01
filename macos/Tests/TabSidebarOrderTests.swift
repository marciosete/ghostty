//
//  TabSidebarOrderTests.swift
//  GhosttyTests
//
//  Tests for the order the tab sidebar keeps folder groups, folders, groups and
//  sessions in.
//

import Foundation
import Testing
@testable import Ghostty

struct TabSidebarOrderTests {
    private struct Item: TabSidebarOrderItem, CustomStringConvertible {
        let name: String
        let nestingKeys: [UUID?]

        var description: String { name }
    }

    private typealias Block = TabSidebarOrder.Block

    /// The levels, outermost first.
    private static let folderGroup = 0
    private static let folder = 1
    private static let group = 2

    private let g1 = UUID()
    private let g2 = UUID()
    private let f1 = UUID()
    private let f2 = UUID()
    private let fg1 = UUID()
    private let fg2 = UUID()

    private func item(_ name: String, group: UUID? = nil, folder: UUID? = nil, folderGroup: UUID? = nil) -> Item {
        Item(name: name, nestingKeys: [folderGroup, folder, group])
    }

    private func names(_ items: [Item]?) -> [String] {
        items?.map(\.name) ?? []
    }

    private func moving(_ level: Int, _ id: UUID) -> Block { Block(level: level, id: id) }

    // MARK: Nesting

    @Test func nestedKeepsPlainTabsInPlace() {
        let items = [item("a"), item("b"), item("c")]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "b", "c"])
    }

    @Test func nestedPullsAGroupTogetherWhereItsFirstMemberIs() {
        let items = [item("a", group: g1), item("b"), item("c", group: g1)]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "c", "b"])
    }

    @Test func nestedPullsAFolderTogetherWhereItsFirstMemberIs() {
        let items = [item("a", folder: f1), item("b"), item("c", folder: f1), item("d")]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "c", "b", "d"])
    }

    @Test func nestedKeepsGroupsTogetherInsideAFolder() {
        let items = [
            item("a", group: g1, folder: f1),
            item("b", folder: f1),
            item("c", group: g1, folder: f1),
            item("d"),
        ]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "c", "b", "d"])
    }

    @Test func nestedKeepsFoldersTogetherInsideAFolderGroup() {
        let items = [
            item("a", folder: f1, folderGroup: fg1),
            item("b", folder: f2, folderGroup: fg1),
            item("c"),
            item("d", folder: f1, folderGroup: fg1),
            item("e", folder: f2, folderGroup: fg1),
        ]
        // f1 pulls d in, and the folder group pulls e in behind the rest of its folder.
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "d", "b", "e", "c"])
    }

    @Test func nestedLeavesAGroupOutsideAFolderAlone() {
        let items = [item("a", group: g1), item("b", folder: f1), item("c", group: g1), item("d", folder: f1)]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "c", "b", "d"])
    }

    // MARK: Moving a group

    @Test func groupMovesPastAWholeTargetGroup() {
        let items = [item("a", group: g1), item("b", group: g2), item("c", group: g2), item("d")]
        let order = TabSidebarOrder.order(items, moving: moving(Self.group, g1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "c", "a", "d"])
    }

    @Test func groupMovesBeforeATab() {
        let items = [item("a"), item("b", group: g1), item("c", group: g1), item("d")]
        let order = TabSidebarOrder.order(items, moving: moving(Self.group, g1), to: .item(items[0]), after: false)
        #expect(names(order) == ["b", "c", "a", "d"])
    }

    @Test func groupMovesToTheEnd() {
        let items = [item("a", group: g1), item("b", group: g1), item("c")]
        let order = TabSidebarOrder.order(items, moving: moving(Self.group, g1), to: .end, after: false)
        #expect(names(order) == ["c", "a", "b"])
    }

    @Test func groupCannotMoveNextToItself() {
        let items = [item("a", group: g1), item("b", group: g1), item("c")]
        #expect(TabSidebarOrder.order(items, moving: moving(Self.group, g1), to: .item(items[1]), after: true) == nil)
        #expect(TabSidebarOrder.order(items, moving: moving(Self.group, g1), to: .block(moving(Self.group, g1)), after: true) == nil)
        #expect(TabSidebarOrder.order(items, moving: moving(Self.group, g2), to: .end, after: true) == nil)
    }

    @Test func groupMovesNextToAnotherGroup() {
        let items = [item("a", group: g1), item("b"), item("c", group: g2), item("d", group: g2)]
        let order = TabSidebarOrder.order(items, moving: moving(Self.group, g1), to: .block(moving(Self.group, g2)), after: true)
        #expect(names(order) == ["b", "c", "d", "a"])
    }

    @Test func groupMovedNextToATabInAFolderGoesJustThere() {
        let items = [item("a", group: g1), item("b", folder: f1), item("c", folder: f1)]
        let order = TabSidebarOrder.order(items, moving: moving(Self.group, g1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "a", "c"])
    }

    @Test func groupDroppedOnAFolderGoesBeforeItsFirstTab() {
        let items = [item("a", group: g1), item("b"), item("c", group: g2, folder: f1), item("d", group: g2, folder: f1)]
        let order = TabSidebarOrder.order(items, moving: moving(Self.group, g1), to: .block(moving(Self.folder, f1)), after: false)
        #expect(names(order) == ["b", "a", "c", "d"])
    }

    @Test func groupDroppedOnAnEmptyFolderGoesToTheEnd() {
        let items = [item("a", group: g1), item("b")]
        let order = TabSidebarOrder.order(items, moving: moving(Self.group, g1), to: .block(moving(Self.folder, f1)), after: false)
        #expect(names(order) == ["b", "a"])
    }

    // MARK: Moving a folder

    @Test func folderMovesPastAWholeTargetFolder() {
        let items = [
            item("a", folder: f1),
            item("b", folder: f2),
            item("c", group: g1, folder: f2),
            item("d", group: g1, folder: f2),
            item("e"),
        ]
        let order = TabSidebarOrder.order(items, moving: moving(Self.folder, f1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "c", "d", "a", "e"])
    }

    @Test func folderMovesPastAWholeGroupOutsideAFolder() {
        let items = [item("a", folder: f1), item("b", group: g1), item("c", group: g1), item("d")]
        let order = TabSidebarOrder.order(items, moving: moving(Self.folder, f1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "c", "a", "d"])
    }

    @Test func folderMovesNextToAGroupInsideAnotherFolder() {
        let items = [
            item("a", folder: f1),
            item("b", folder: f2),
            item("c", group: g1, folder: f2),
        ]
        // Dropping before the group means before its whole folder.
        let before = TabSidebarOrder.order(items, moving: moving(Self.folder, f1), to: .block(moving(Self.group, g1)), after: false)
        #expect(names(before) == ["a", "b", "c"])
        let after = TabSidebarOrder.order(items, moving: moving(Self.folder, f1), to: .block(moving(Self.group, g1)), after: true)
        #expect(names(after) == ["b", "c", "a"])
    }

    @Test func folderMovesNextToAnotherFolder() {
        let items = [item("a", folder: f1), item("b"), item("c", folder: f2), item("d", folder: f2)]
        let order = TabSidebarOrder.order(items, moving: moving(Self.folder, f1), to: .block(moving(Self.folder, f2)), after: true)
        #expect(names(order) == ["b", "c", "d", "a"])
    }

    @Test func folderMovedNextToAnEmptyFolderGoesToTheEnd() {
        let items = [item("a", folder: f1), item("b")]
        let order = TabSidebarOrder.order(items, moving: moving(Self.folder, f1), to: .block(moving(Self.folder, f2)), after: false)
        #expect(names(order) == ["b", "a"])
    }

    @Test func folderMovedNextToAFolderInAGroupStaysInsideThatGroup() {
        // The folder joins the group (the caller sets its key), so it moves past the
        // target folder alone, not past the whole folder group.
        let items = [
            item("a", folder: f1),
            item("b", folder: f2, folderGroup: fg1),
            item("c", folder: UUID(), folderGroup: fg1),
        ]
        let order = TabSidebarOrder.order(items, moving: moving(Self.folder, f1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "a", "c"])
    }

    @Test func folderCannotMoveNextToItself() {
        let items = [item("a", folder: f1), item("b", folder: f1), item("c")]
        #expect(TabSidebarOrder.order(items, moving: moving(Self.folder, f1), to: .item(items[0]), after: true) == nil)
        #expect(TabSidebarOrder.order(items, moving: moving(Self.folder, f1), to: .block(moving(Self.folder, f1)), after: true) == nil)
    }

    // MARK: Moving a folder group

    @Test func folderGroupMovesPastAWholeTargetFolderGroup() {
        let items = [
            item("a", folder: f1, folderGroup: fg1),
            item("b", folder: f2, folderGroup: fg2),
            item("c", folder: UUID(), folderGroup: fg2),
            item("d"),
        ]
        let order = TabSidebarOrder.order(items, moving: moving(Self.folderGroup, fg1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "c", "a", "d"])
    }

    @Test func folderGroupMovesPastAWholeLooseFolder() {
        let items = [
            item("a", folder: f1, folderGroup: fg1),
            item("b", folder: f2),
            item("c", group: g1, folder: f2),
            item("d"),
        ]
        let order = TabSidebarOrder.order(items, moving: moving(Self.folderGroup, fg1), to: .block(moving(Self.group, g1)), after: true)
        #expect(names(order) == ["b", "c", "a", "d"])
    }

    @Test func folderGroupMovesToTheEnd() {
        let items = [item("a", folder: f1, folderGroup: fg1), item("b")]
        let order = TabSidebarOrder.order(items, moving: moving(Self.folderGroup, fg1), to: .end, after: false)
        #expect(names(order) == ["b", "a"])
    }
}
