import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeCodeLightTests {
    // MARK: Status

    @Test func statusColors() {
        #expect(ClaudeCodeLight(status: "busy", pending: false)?.tabColor == .blue)
        #expect(ClaudeCodeLight(status: "idle", pending: true)?.tabColor == .yellow)
        #expect(ClaudeCodeLight(status: "waiting", pending: false)?.tabColor == .red)
        #expect(ClaudeCodeLight(status: "idle", pending: false)?.tabColor == .green)
    }

    @Test func pendingOnlyShowsOnceStopped() {
        #expect(ClaudeCodeLight(status: "busy", pending: true) == .working)
        #expect(ClaudeCodeLight(status: "waiting", pending: true) == .waiting)
    }

    @Test func unknownStatusShowsNothing() {
        #expect(ClaudeCodeLight(status: "parked", pending: false) == nil)
    }

    @Test func tabShowsTheSessionThatNeedsAttentionMost() {
        #expect(ClaudeCodeLight.mostUrgent([.clean, .waiting, .working]) == .waiting)
        #expect(ClaudeCodeLight.mostUrgent([.pending, .working]) == .working)
        #expect(ClaudeCodeLight.mostUrgent([.clean, .pending]) == .pending)
        #expect(ClaudeCodeLight.mostUrgent([]) == nil)
    }

    // MARK: Tab state

    @Test func badgeCountsPendingFilesWhileYellow() {
        let state = ClaudeCodeTabState(light: .pending, pendingFiles: 3, editedFiles: 7)
        #expect(state.badge == 3)
        #expect(state.badgeHelp == "3 of 7 edited files not committed")
        #expect(ClaudeCodeTabState(light: .clean, pendingFiles: 0, editedFiles: 7).badge == nil)
        #expect(ClaudeCodeTabState(light: .working).badge == nil)
    }

    @Test func splitTabAddsUpItsSessions() {
        let combined = ClaudeCodeTabState.combined([
            ClaudeCodeTabState(light: .pending, pendingFiles: 2, editedFiles: 4),
            ClaudeCodeTabState(light: .clean, pendingFiles: 0, editedFiles: 3),
            ClaudeCodeTabState(light: .pending, pendingFiles: 1, editedFiles: 1),
        ])
        #expect(combined == ClaudeCodeTabState(light: .pending, pendingFiles: 3, editedFiles: 8))

        // A session that needs attention hides the count.
        let waiting = ClaudeCodeTabState.combined([
            ClaudeCodeTabState(light: .pending, pendingFiles: 2, editedFiles: 4),
            ClaudeCodeTabState(light: .waiting),
        ])
        #expect(waiting?.light == .waiting)
        #expect(waiting?.badge == nil)
        #expect(ClaudeCodeTabState.combined([]) == nil)
    }

    @Test func renamesCountOnce() {
        let output = "R  new.swift\0old.swift\0 M a.swift\0?? b.swift\0"
        #expect(Git.changedPaths(porcelain: output) == ["new.swift", "a.swift", "b.swift"])
    }

    // MARK: Colors

    @Test func trafficLightColorsCantBePickedByHand() {
        for light in ClaudeCodeLight.allCases {
            #expect(!TerminalTabColor.tabChoices.contains(light.tabColor))
            #expect(!TerminalTabColor.groupChoices.contains(light.tabColor))
            #expect(light.tabColor.isTrafficLight)
        }
        #expect(TerminalTabColor.tabChoices.first == .auto)
        #expect(!TerminalTabColor.groupChoices.contains(.auto))
        #expect(!TerminalTabColor.purple.isTrafficLight)
    }

    @Test func savedColorsKeepTheirValues() {
        #expect(TerminalTabColor.none.rawValue == 0)
        #expect(TerminalTabColor.graphite.rawValue == 9)
        #expect(TerminalTabColor.auto.rawValue == 10)
    }

    // MARK: Edited files

    private static func toolUse(_ name: String, _ input: [String: Any], sidechain: Bool = false) -> Data {
        line([
            "type": "assistant",
            "isSidechain": sidechain,
            "message": ["content": [["type": "tool_use", "id": UUID().uuidString, "name": name, "input": input]]],
        ])
    }

    private static func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test func collectsEditedFiles() {
        let tracker = ClaudeCodeEditTracker()
        tracker.consume(line: Self.toolUse("Edit", ["file_path": "/repo/a.swift"]))
        tracker.consume(line: Self.toolUse("Write", ["file_path": "/repo/b.swift"]))
        tracker.consume(line: Self.toolUse("MultiEdit", ["file_path": "/repo/a.swift"]))
        tracker.consume(line: Self.toolUse("NotebookEdit", ["notebook_path": "/repo/c.ipynb"]))
        #expect(tracker.files == ["/repo/a.swift", "/repo/b.swift", "/repo/c.ipynb"])
    }

    @Test func ignoresReadsCommandsAndSubagents() {
        let tracker = ClaudeCodeEditTracker()
        tracker.consume(line: Self.toolUse("Read", ["file_path": "/repo/a.swift"]))
        tracker.consume(line: Self.toolUse("Bash", ["command": "touch /repo/b.swift"]))
        tracker.consume(line: Self.toolUse("Edit", ["file_path": "/repo/c.swift"], sidechain: true))
        #expect(tracker.files.isEmpty)
    }

    @Test func readsOnlyWhatWasAdded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-code-light-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        var contents = Self.toolUse("Edit", ["file_path": "/repo/a.swift"]) + Data("\n".utf8)
        try contents.write(to: url)
        let tracker = ClaudeCodeEditTracker()
        tracker.update(from: url)
        #expect(tracker.files == ["/repo/a.swift"])

        // A line still being written is read once it is complete.
        let next = Self.toolUse("Write", ["file_path": "/repo/b.swift"])
        contents += next.prefix(10)
        try contents.write(to: url)
        tracker.update(from: url)
        #expect(tracker.files == ["/repo/a.swift"])

        contents += next.dropFirst(10) + Data("\n".utf8)
        try contents.write(to: url)
        tracker.update(from: url)
        #expect(tracker.files == ["/repo/a.swift", "/repo/b.swift"])
    }

    // MARK: Git

    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = Git.executableURL
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.com"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func uncommittedChangesOfTheGivenFilesOnly() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("claude-code-light-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: made) }

        try Self.git(["init", "-q"], in: made)
        let repository = try #require(Git.repository(containing: made))
        let root = repository.root
        let mine = root.appendingPathComponent("mine [1].swift").path
        let other = root.appendingPathComponent("other.swift").path

        // A new file is pending until it is committed.
        try Data("a".utf8).write(to: URL(fileURLWithPath: mine))
        #expect(Git.uncommittedFileCount([mine], in: repository) == 1)
        try Self.git(["add", "."], in: root)
        #expect(Git.uncommittedFileCount([mine], in: repository) == 1)
        try Self.git(["commit", "-q", "-m", "first"], in: root)
        #expect(Git.uncommittedFileCount([mine], in: repository) == 0)

        // Another session's changes don't count.
        try Data("b".utf8).write(to: URL(fileURLWithPath: other))
        #expect(Git.uncommittedFileCount([mine], in: repository) == 0)

        // Neither does a file outside the repository, or no file at all.
        #expect(Git.uncommittedFileCount(["/elsewhere/x.swift"], in: repository) == 0)
        #expect(Git.uncommittedFileCount([], in: repository) == 0)

        try Data("c".utf8).write(to: URL(fileURLWithPath: mine))
        #expect(Git.uncommittedFileCount([mine], in: repository) == 1)

        // Each pending file counts once.
        try Data("d".utf8).write(to: URL(fileURLWithPath: other))
        #expect(Git.uncommittedFileCount([mine, other, mine], in: repository) == 2)
    }
}
