import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeCodeSpeakerTests {
    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func assistant(id: String?, _ blocks: [[String: Any]], sidechain: Bool = false, model: String = "claude-opus-5-5") -> Data {
        var message: [String: Any] = ["role": "assistant", "model": model, "content": blocks]
        if let id { message["id"] = id }
        return line(["type": "assistant", "isSidechain": sidechain, "message": message])
    }

    private func text(_ text: String) -> [String: Any] { ["type": "text", "text": text] }
    private let toolUse: [String: Any] = ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]

    private func user(_ text: String) -> Data {
        line(["type": "user", "message": ["role": "user", "content": text]])
    }

    // MARK: Last response

    @Test func lastResponseIsTheLastMessageWithText() {
        let lines = [
            user("hi"),
            assistant(id: "a", [text("Let me look.")]),
            assistant(id: "a", [toolUse]),
            user("tool result"),
            assistant(id: "b", [text("Here it is.")]),
            assistant(id: "b", [text("And more.")]),
        ]
        #expect(ClaudeCodeResponse.last(inLines: lines) == "Here it is.\n\nAnd more.")
    }

    @Test func toolCallsAfterTheResponseAreSkipped() {
        let lines = [
            assistant(id: "a", [text("Done.")]),
            assistant(id: "b", [toolUse]),
        ]
        #expect(ClaudeCodeResponse.last(inLines: lines) == "Done.")
    }

    @Test func subagentsAndSyntheticMessagesAreSkipped() {
        let lines = [
            assistant(id: "a", [text("Mine.")]),
            assistant(id: "b", [text("Subagent.")], sidechain: true),
            assistant(id: "c", [text("No response requested.")], model: "<synthetic>"),
            line(["not": "a transcript line"]),
            Data("not json".utf8),
        ]
        #expect(ClaudeCodeResponse.last(inLines: lines) == "Mine.")
    }

    @Test func noResponse() {
        #expect(ClaudeCodeResponse.last(inLines: [user("hi")]) == nil)
        #expect(ClaudeCodeResponse.last(inLines: []) == nil)
    }

    @Test func readsTheEndOfATranscriptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines = [user("hi"), assistant(id: "a", [text("Hello there.")])]
        var data = Data()
        for line in lines { data.append(line); data.append(UInt8(ascii: "\n")) }
        try data.write(to: url)
        #expect(ClaudeCodeResponse.last(inTranscript: url) == "Hello there.")
    }

    // MARK: Spoken text

    @Test func codeBlocksAreNotRead() {
        let markdown = """
        Run this:

        ```bash
        zig build
        ```

        Then test.
        """
        #expect(ClaudeCodeResponse.spoken(fromMarkdown: markdown) == "Run this:\n\nThen test.")
    }

    @Test func formattingIsNotRead() {
        let markdown = """
        ## Summary
        - **Bold** and `code_name` in [the docs](https://example.com).
        > Quoted, see https://example.com/page
        """
        #expect(ClaudeCodeResponse.spoken(fromMarkdown: markdown)
            == "Summary\nBold and code_name in the docs.\nQuoted, see link")
    }

    @Test func tablesReadAsRows() {
        let markdown = """
        | Name | Count |
        |------|------:|
        | a    | 1     |
        """
        #expect(ClaudeCodeResponse.spoken(fromMarkdown: markdown) == "Name, Count\na, 1")
    }
}
