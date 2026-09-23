import AppKit
import Testing
@testable import Ghostty

@Suite
@MainActor
struct TerminalWindowTitleTests {
    private func window() -> TerminalWindow {
        let window = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.awakeFromNib()
        return window
    }

    @Test func ungroupedShowsTheSessionTitle() {
        let window = window()
        window.sessionTitle = "Fix the usage panel"
        #expect(window.title == "Fix the usage panel")
        #expect(window.tab.title == "Fix the usage panel")
    }

    @Test func groupedShowsTheGroupFirst() {
        let group = UserTabGroupStore.shared.create(name: "Ghostty")
        defer { UserTabGroupStore.shared.remove(group.id) }

        let window = window()
        window.sessionTitle = "Fix the usage panel"
        window.userTabGroupID = group.id
        #expect(window.title == "Ghostty › Fix the usage panel")
        #expect(window.tab.title == "Fix the usage panel")

        UserTabGroupStore.shared.update(group.id) { $0.name = "Pro" }
        #expect(window.title == "Pro › Fix the usage panel")

        window.userTabGroupID = nil
        #expect(window.title == "Fix the usage panel")
    }
}
