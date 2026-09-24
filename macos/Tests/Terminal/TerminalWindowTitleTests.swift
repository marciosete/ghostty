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

    @Test func renamingLeavesOutClaudeCodeStatus() {
        #expect(BaseTerminalController.withoutClaudeCodeStatus("◑ Process Review") == "Process Review")
        #expect(BaseTerminalController.withoutClaudeCodeStatus("◐ Process Review") == "Process Review")
        #expect(BaseTerminalController.withoutClaudeCodeStatus("✳ Claude Code") == "Claude Code")
        #expect(BaseTerminalController.withoutClaudeCodeStatus("Process Review") == "Process Review")
        #expect(BaseTerminalController.withoutClaudeCodeStatus("◑Process") == "◑Process")
    }

    @Test func aRenamedSessionShowsClaudeCodeStatus() {
        #expect(BaseTerminalController.claudeCodeStatus(of: "◐ Claude Code") == "◐")
        #expect(BaseTerminalController.claudeCodeStatus(of: "~/projects") == nil)
        #expect(BaseTerminalController.named("Hardening", claudeCodeStatus: "◐") == "◐ Hardening")
        #expect(BaseTerminalController.named("Hardening", claudeCodeStatus: nil) == "Hardening")

        // A name saved while Claude Code worked shows the current status, not the saved one.
        #expect(BaseTerminalController.named("◑ Hardening", claudeCodeStatus: "✳") == "✳ Hardening")
        #expect(BaseTerminalController.named("◑ Hardening", claudeCodeStatus: nil) == "Hardening")
    }
}
