import AppKit
import Testing
@testable import Ghostty

@Suite
@MainActor
struct TabSidebarSearchTests {
    @Test func everyWordMustMatchSomewhere() {
        let fields: [String?] = ["Email working check", nil, "kinetic", "main"]
        #expect(TabSidebarSearch.matches("", fields))
        #expect(TabSidebarSearch.matches("email", fields))
        #expect(TabSidebarSearch.matches("KINETIC check", fields))
        #expect(TabSidebarSearch.matches("émail", fields))
        #expect(!TabSidebarSearch.matches("email ghostty", fields))
    }

    @Test func filtersRowsAndOpensGroupsWithMatches() {
        var windows: [TerminalWindow] = []
        func tab(_ title: String) -> TabSidebarModel.Tab {
            let window = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            windows.append(window)
            return TabSidebarModel.Tab(
                id: ObjectIdentifier(window), window: nil, index: windows.count, title: title,
                color: .none, assignedColor: .none, claudeCodeState: nil, claudeCodeActivity: ClaudeCodeActivity(),
                canSpeak: false, isSpeaking: false, speechVoiceID: nil,
                keyEquivalent: nil, isSelected: false, isZoomed: false, groupID: nil, folderID: nil, folderGroupID: nil)
        }

        let voice = tab("Voice")
        let retry = tab("Retry")
        let email = tab("Email working check")
        let plain = tab("plain shell")
        let kinetic = UserTabGroup(name: "Kinetic", isCollapsed: true)
        let brisbane = UserTabGroup(name: "Brisbane North", isCollapsed: true)
        let rows: [TabSidebarModel.Row] = [
            .group(.init(group: kinetic, tabs: [voice, retry])),
            .group(.init(group: brisbane, tabs: [email])),
            .tab(plain),
        ]
        let infos = [ObjectIdentifier(windows[3]): TabSidebarSessionInfo(
            directory: "/Users/me/Downloads",
            checkout: nil)]

        #expect(TabSidebarSearch.filter(rows, query: "  ", infos: infos) == rows)

        // A match inside a collapsed group opens it, showing only the match.
        let retryOnly = TabSidebarSearch.filter(rows, query: "ret", infos: infos)
        #expect(TabSidebarSearch.tabs(in: retryOnly).map(\.title) == ["Retry"])

        // A group whose name matches keeps all its sessions.
        let kineticOnly = TabSidebarSearch.filter(rows, query: "kinetic", infos: infos)
        #expect(TabSidebarSearch.tabs(in: kineticOnly).map(\.title) == ["Voice", "Retry"])

        // A session is found by its directory.
        let downloads = TabSidebarSearch.filter(rows, query: "downloads", infos: infos)
        #expect(TabSidebarSearch.tabs(in: downloads).map(\.title) == ["plain shell"])

        #expect(TabSidebarSearch.filter(rows, query: "nothing", infos: infos).isEmpty)

        // Sessions are found by their folder's name and path, and by their folder group's
        // name; a match opens the collapsed folder and folder group around it.
        let ghostty = UserTabFolder(path: "/Users/me/projects/ghostty", isCollapsed: true)
        let empty = UserTabFolder(path: "/Users/me/projects/empty", isCollapsed: true)
        let work = UserTabFolderGroup(name: "Work", isCollapsed: true)
        var openKinetic = kinetic
        openKinetic.isCollapsed = false
        let nested: [TabSidebarModel.Row] = [
            .folderGroup(.init(group: work, folders: [
                .init(folder: ghostty, rows: [.group(.init(group: openKinetic, tabs: [voice, retry])), .tab(email)]),
                .init(folder: empty, rows: []),
            ])),
            .tab(plain),
        ]
        #expect(TabSidebarSearch.tabs(in: TabSidebarSearch.filter(nested, query: "ghostty", infos: infos)).map(\.title)
            == ["Voice", "Retry", "Email working check"])
        #expect(TabSidebarSearch.tabs(in: TabSidebarSearch.filter(nested, query: "projects email", infos: infos)).map(\.title)
            == ["Email working check"])
        #expect(TabSidebarSearch.tabs(in: TabSidebarSearch.filter(nested, query: "work voice", infos: infos)).map(\.title)
            == ["Voice"])
        #expect(TabSidebarSearch.filter(nested, query: "empty", infos: infos).isEmpty)
    }
}
