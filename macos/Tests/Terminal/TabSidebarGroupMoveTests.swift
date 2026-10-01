import AppKit
import Testing
@testable import Ghostty

@Suite
@MainActor
struct TabSidebarGroupMoveTests {
    private let a = UUID()
    private let b = UUID()

    /// Tabs `a1 a2 | loose | b1 b2 b3`, named by their title.
    private func windows() -> [NSWindow] {
        [("a1", a), ("a2", a), ("loose", nil), ("b1", b), ("b2", b), ("b3", b)].map { title, group in
            let window = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            window.title = title
            window.userTabGroupID = group
            return window
        }
    }

    private func titles(_ order: [NSWindow]?) -> [String]? {
        order?.map(\.title)
    }

    private func window(_ title: String, in windows: [NSWindow]) throws -> TerminalWindow {
        try #require(windows.first { $0.title == title } as? TerminalWindow)
    }

    @Test func aGroupMovesPastAnotherGroupWhole() {
        let windows = windows()
        #expect(titles(TabSidebarModel.order(windows, moving: .group(b), to: .group(a), after: false))
            == ["b1", "b2", "b3", "a1", "a2", "loose"])
        #expect(titles(TabSidebarModel.order(windows, moving: .group(a), to: .group(b), after: true))
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }

    @Test func aGroupDroppedOnATabGoesNextToItOrItsGroup() throws {
        let windows = windows()
        let loose = try window("loose", in: windows)
        #expect(titles(TabSidebarModel.order(windows, moving: .group(b), to: .tab(loose), after: false))
            == ["a1", "a2", "b1", "b2", "b3", "loose"])

        // Dropped below a tab in the middle of another group, it goes after all of it.
        let b2 = try window("b2", in: windows)
        #expect(titles(TabSidebarModel.order(windows, moving: .group(a), to: .tab(b2), after: true))
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }

    @Test func aGroupMovesToTheEnd() {
        let windows = windows()
        #expect(titles(TabSidebarModel.order(windows, moving: .group(a), to: .end, after: false))
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }

    @Test func aGroupDoesNotMoveOntoItself() throws {
        let windows = windows()
        let a2 = try window("a2", in: windows)
        #expect(TabSidebarModel.order(windows, moving: .group(a), to: .group(a), after: false) == nil)
        #expect(TabSidebarModel.order(windows, moving: .group(a), to: .tab(a2), after: false) == nil)
        #expect(TabSidebarModel.order(windows, moving: .group(UUID()), to: .end, after: false) == nil)
    }

    @Test func aFolderMovesWithItsGroupsPastAnotherFolder() throws {
        let windows = windows()
        let f1 = UUID()
        let f2 = UUID()
        for title in ["a1", "a2"] { try window(title, in: windows).userTabFolderID = f1 }
        for title in ["loose", "b1", "b2", "b3"] { try window(title, in: windows).userTabFolderID = f2 }
        let b2 = try window("b2", in: windows)
        #expect(titles(TabSidebarModel.order(windows, moving: .folder(f1), to: .tab(b2), after: true))
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
        #expect(titles(TabSidebarModel.order(windows, moving: .folder(f2), to: .folder(f1), after: false))
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }
}
