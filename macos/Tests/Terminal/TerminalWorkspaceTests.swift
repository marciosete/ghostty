import AppKit
import Testing
@testable import Ghostty

@Suite
@MainActor
struct TerminalWorkspaceTests {
    /// A saved workspace with two tabs, as the app writes it, read without starting any
    /// terminal: nothing is open in the tests, so every tab counts as missing.
    @Test func countsTheTabsOfASavedWorkspaceWithoutOpeningThem() throws {
        let json = """
        {"stateVersion": 7, "windows": [{"frame": [[0, 0], [800, 600]], "selectedTab": 0, "tabs": [
          {"surfaceTree": {"version": 1, "root": {"view": {"uuid": "E247389F-09D1-432F-B055-DA04F726E609",
             "pwd": "/tmp", "isUserSetTitle": false,
             "claudeCodeSession": {"id": "977B4F2C-1EAC-498A-9D68-C338D75C4B34", "cwd": "/tmp"}}}}},
          {"surfaceTree": {"version": 1, "root": {"split": {"direction": "horizontal", "ratio": 0.5,
             "left": {"view": {"uuid": "11111111-1111-1111-1111-111111111111", "pwd": "/tmp", "isUserSetTitle": false}},
             "right": {"view": {"uuid": "22222222-2222-2222-2222-222222222222", "pwd": "/tmp", "isUserSetTitle": false}}}}}}
        ]}]}
        """
        let counts = try #require(TerminalWorkspace.count(Data(json.utf8)))
        #expect(counts.open == 0)
        #expect(counts.missing == 2)

        #expect(TerminalWorkspace.count(Data("not json".utf8)) == nil)
    }

    /// Lost tabs are kept in the saved workspace next to what is open. Nothing is open in
    /// the tests, so every lost tab is missing and is added to the first window.
    @Test func mergesLostTabsIntoTheSavedWorkspace() throws {
        func tab(_ uuid: String) -> String {
            """
            {"surfaceTree": {"version": 1, "root": {"view": {"uuid": "\(uuid)", "pwd": "/tmp", "isUserSetTitle": false}}}}
            """
        }
        let open = Data("""
        {"stateVersion": 7, "windows": [{"frame": [[0, 0], [800, 600]], "selectedTab": 0, "tabs": [\(tab("AAAAAAAA-0000-0000-0000-000000000000"))]}]}
        """.utf8)
        let lost = Data("""
        {"stateVersion": 7, "windows": [
          {"frame": [[0, 0], [800, 600]], "selectedTab": 0, "tabs": [\(tab("BBBBBBBB-0000-0000-0000-000000000000"))]},
          {"frame": [[0, 0], [800, 600]], "selectedTab": 0, "tabs": [\(tab("CCCCCCCC-0000-0000-0000-000000000000"))]}
        ]}
        """.utf8)

        let merged = try #require(TerminalWorkspace.merging(open, lost: lost))
        let json = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let windows = try #require(json["windows"] as? [[String: Any]])
        #expect(windows.count == 1, "lost tabs join the first open window")
        let uuids = (windows[0]["tabs"] as? [[String: Any]] ?? []).compactMap { tab -> String? in
            let root = (tab["surfaceTree"] as? [String: Any])?["root"] as? [String: Any]
            return (root?["view"] as? [String: Any])?["uuid"] as? String
        }
        #expect(uuids == ["AAAAAAAA-0000-0000-0000-000000000000", "BBBBBBBB-0000-0000-0000-000000000000", "CCCCCCCC-0000-0000-0000-000000000000"])

        // With no open window left, the lost workspace is kept whole.
        let none = Data(#"{"stateVersion": 7, "windows": []}"#.utf8)
        let kept = try #require(TerminalWorkspace.merging(none, lost: lost))
        let keptJSON = try #require(JSONSerialization.jsonObject(with: kept) as? [String: Any])
        #expect((keptJSON["windows"] as? [[String: Any]])?.count == 2)

        #expect(TerminalWorkspace.merging(Data("x".utf8), lost: lost) == nil)
    }

    @Test func historyEntriesAreNamedByTheirTimeAndLoss() {
        // The directory may hold anything on the machine running the tests, so only the
        // naming is checked, through the entries it yields.
        for entry in TerminalWorkspace.history() {
            #expect(entry.url.pathExtension == "json")
            #expect(entry.lost.map { $0 > 0 } ?? true)
        }
    }
}
