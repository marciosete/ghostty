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

    private func window(_ title: String, in windows: [NSWindow]) -> TerminalWindow {
        windows.first { $0.title == title } as! TerminalWindow
    }

    @Test func aGroupMovesPastAnotherGroupWhole() {
        let windows = windows()
        #expect(titles(TabSidebarModel.order(windows, movingGroup: b, to: .group(a), after: false))
            == ["b1", "b2", "b3", "a1", "a2", "loose"])
        #expect(titles(TabSidebarModel.order(windows, movingGroup: a, to: .group(b), after: true))
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }

    @Test func aGroupDroppedOnATabGoesNextToItOrItsGroup() {
        let windows = windows()
        #expect(titles(TabSidebarModel.order(windows, movingGroup: b, to: .tab(window("loose", in: windows)), after: false))
            == ["a1", "a2", "b1", "b2", "b3", "loose"])

        // Dropped below a tab in the middle of another group, it goes after all of it.
        #expect(titles(TabSidebarModel.order(windows, movingGroup: a, to: .tab(window("b2", in: windows)), after: true))
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }

    @Test func aGroupMovesToTheEnd() {
        let windows = windows()
        #expect(titles(TabSidebarModel.order(windows, movingGroup: a, to: .end, after: false))
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }

    @Test func aGroupDoesNotMoveOntoItself() {
        let windows = windows()
        #expect(TabSidebarModel.order(windows, movingGroup: a, to: .group(a), after: false) == nil)
        #expect(TabSidebarModel.order(windows, movingGroup: a, to: .tab(window("a2", in: windows)), after: false) == nil)
        #expect(TabSidebarModel.order(windows, movingGroup: UUID(), to: .end, after: false) == nil)
    }
}
