import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeCodeLightTests {
    // MARK: Status

    @Test func statusColors() {
        #expect(ClaudeCodeLight(status: "busy", committed: false)?.tabColor == .blue)
        #expect(ClaudeCodeLight(status: "idle", committed: false)?.tabColor == .yellow)
        #expect(ClaudeCodeLight(status: "waiting", committed: false)?.tabColor == .red)
        #expect(ClaudeCodeLight(status: "idle", committed: true)?.tabColor == .green)
    }

    @Test func committedOnlyShowsOnceFinished() {
        #expect(ClaudeCodeLight(status: "busy", committed: true) == .working)
        #expect(ClaudeCodeLight(status: "waiting", committed: true) == .waiting)
    }

    @Test func unknownStatusShowsNothing() {
        #expect(ClaudeCodeLight(status: "parked", committed: false) == nil)
    }

    @Test func tabShowsTheSessionThatNeedsAttentionMost() {
        #expect(ClaudeCodeLight.mostUrgent([.committed, .waiting, .working]) == .waiting)
        #expect(ClaudeCodeLight.mostUrgent([.finished, .working]) == .working)
        #expect(ClaudeCodeLight.mostUrgent([.committed, .finished]) == .finished)
        #expect(ClaudeCodeLight.mostUrgent([]) == nil)
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

    // MARK: Commits

    private static func toolUse(_ id: String, _ name: String, command: String? = nil) -> Data {
        var input: [String: Any] = [:]
        input["command"] = command
        return line([
            "type": "assistant",
            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]],
        ])
    }

    private static func toolResult(_ id: String, isError: Bool = false) -> Data {
        line([
            "type": "user",
            "message": ["content": [["type": "tool_result", "tool_use_id": id, "is_error": isError]]],
        ])
    }

    private static func line(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test func commitThatSucceeded() {
        let tracker = ClaudeCodeCommitTracker()
        tracker.consume(line: Self.toolUse("a", "Edit"))
        tracker.consume(line: Self.toolUse("b", "Bash", command: "git commit -m 'fix: x'"))
        #expect(!tracker.committed)
        tracker.consume(line: Self.toolResult("b"))
        #expect(tracker.committed)
    }

    @Test func commitThatFailed() {
        let tracker = ClaudeCodeCommitTracker()
        tracker.consume(line: Self.toolUse("b", "Bash", command: "git commit -m x"))
        tracker.consume(line: Self.toolResult("b", isError: true))
        #expect(!tracker.committed)
    }

    @Test func editAfterCommit() {
        let tracker = ClaudeCodeCommitTracker()
        tracker.consume(line: Self.toolUse("b", "Bash", command: "git commit -m x"))
        tracker.consume(line: Self.toolResult("b"))
        tracker.consume(line: Self.toolUse("c", "Write"))
        #expect(!tracker.committed)
    }

    @Test func otherCommandsDontCount() {
        let tracker = ClaudeCodeCommitTracker()
        tracker.consume(line: Self.toolUse("b", "Bash", command: "git status"))
        tracker.consume(line: Self.toolResult("b"))
        #expect(!tracker.committed)
    }

    @Test func commitCommands() {
        #expect(ClaudeCodeCommitTracker.isCommit("git commit -m x"))
        #expect(ClaudeCodeCommitTracker.isCommit("git -C /repo commit -F - <<'MSG'"))
        #expect(ClaudeCodeCommitTracker.isCommit("git add a.swift && git commit -m x"))
        #expect(!ClaudeCodeCommitTracker.isCommit("git log --grep commit"))
        #expect(!ClaudeCodeCommitTracker.isCommit("git status; echo commit"))
    }

    @Test func readsOnlyWhatWasAdded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-code-light-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        var contents = Self.toolUse("b", "Bash", command: "git commit -m x") + Data("\n".utf8)
        try contents.write(to: url)
        let tracker = ClaudeCodeCommitTracker()
        tracker.update(from: url)
        #expect(!tracker.committed)

        // A line still being written is read once it is complete.
        let result = Self.toolResult("b")
        contents += result.prefix(10)
        try contents.write(to: url)
        tracker.update(from: url)
        #expect(!tracker.committed)

        contents += result.dropFirst(10) + Data("\n".utf8)
        try contents.write(to: url)
        tracker.update(from: url)
        #expect(tracker.committed)
    }
}
